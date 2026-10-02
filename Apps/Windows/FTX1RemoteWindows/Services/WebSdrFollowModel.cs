using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows.Services;

/// What the WebSDR window needs to know about the rig: Main's frequency
/// and mode (0 / null while not connected), PTT, and Memory mode (the rig
/// rejects a VFO frequency set there).
public readonly record struct RigSnapshot(long FrequencyHz, RigMode? Mode, bool Ptt, bool InMemoryMode);

/// The WebSDR window's way back into MainWindow — the parts of the Mac's
/// HubService that WebSDRFollowModel uses.
public sealed class WebSdrRigLink
{
    /// The rig as of the last poll (the Mac's hub.rigState).
    public required Func<RigSnapshot> Current { get; init; }
    /// Click-to-tune: Main's frequency (null = unchanged) and mode (null =
    /// unchanged) — the Mac's hub.send(.setFrequency/.setMode).
    public required Action<long?, RigMode?> Tune { get; init; }
    /// The Mac's HubService.setWebSDRAudioActive: mutes the rig's Main
    /// playback while the WebSDR is audible, and undoes only a mute it made.
    public required Action<bool> SetAudioActive { get; init; }
}

/// Drives the WebSDR window — a port of the Mac's WebSDRFollowModel, same
/// logic and decisions (see there and root CLAUDE.md's "WebSDR follow"
/// section): follows the rig's Main VFO frequency/mode and publishes the
/// page WebSdrWindow should show — a KiwiSDR, or a classic WebSDR
/// (SdrPlatform). A Kiwi is retuned by loading a new `?f=` URL; a WebSDR is
/// loaded once per connection and then retuned in place through its own
/// `setfreqtune()` (RetuneInPlace), with no reload or reconnect.
///
/// MainWindow pushes the rig state after every poll (OnRigState), the same
/// values the poll just read rather than a second poll; consecutive
/// duplicates are dropped and the rest debounced by 400 ms, which absorbs
/// VFO-knob spinning, like the Mac's removeDuplicates + debounce on
/// hub.$rigState.
///
/// The other direction, click-to-tune (page → rig, "Tune rig"): while
/// connected, the page's own tuning globals are read ~4×/s
/// (SdrPageBridge.ReadTuningAsync); a change the user makes in the page —
/// clicking the waterfall, typing a frequency, a mode button — is sent to
/// the rig once it has held still for one poll. The rig's echo of that
/// change must not reload the Kiwi: Evaluate skips the reload while the
/// page is already where the rig is, and holds off while the rig hasn't
/// caught up yet (_pendingRigTune), since a poll can still report the old
/// frequency after the set went out.
///
/// UI thread only: every await resumes on the window's dispatcher.
public sealed class WebSdrFollowModel
{
    private readonly record struct FollowTarget(long FrequencyHz, RigMode? Mode);

    /// One page load for the window's web view. `Id` distinguishes a
    /// deliberate reload of the same URL (Return in the host field, e.g. to
    /// retry after an error) from a repeat that should be ignored.
    public sealed record PageRequest(string Url, SdrPlatform Platform, int Id);

    private readonly record struct PageTuning(long FrequencyHz, string Mode);

    /// Frequencies closer than this count as the same: `?f=` carries 10 Hz
    /// resolution, so a round trip through the rig can land that far off.
    private const long SameFrequencyToleranceHz = 10;
    private static readonly TimeSpan TuningPollInterval = TimeSpan.FromMilliseconds(250);
    /// How long a rig tune sent from the page may take to show up in the
    /// rig state before the rig's (still old) value is followed again.
    private static readonly TimeSpan RigTuneGrace = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan FollowDebounce = TimeSpan.FromMilliseconds(400);

    private readonly WebSdrRigLink _rig;

    public SdrPageBridge Bridge { get; } = new();

    /// Anything the window shows changed.
    public event Action? Changed;

    public WebSdrFollowModel(WebSdrRigLink rig)
    {
        _rig = rig;
        _hostPort = AppSettings.WebSdrHostPort;
        _followRig = AppSettings.WebSdrFollowRig;
        _tuneRig = AppSettings.WebSdrTuneRig;
        _isMuted = AppSettings.WebSdrMuted;
        _muteOnTransmit = AppSettings.WebSdrMuteOnTransmit;
        _favorites = [.. AppSettings.WebSdrFavorites];
        _pickedStation = AppSettings.WebSdrPickedStation;
        Bridge.UnexpectedSave += KiwiEndedRecording;
        Evaluate();
    }

    private void Notify() => Changed?.Invoke();

    /// Fire-and-forget for the Mac's `Task { }` blocks, logging instead of
    /// losing an exception.
    private static async void Run(Func<Task> work)
    {
        try
        {
            await work();
        }
        catch (Exception ex)
        {
            AppLog.Write($"websdr: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private static string Now() => DateTime.Now.ToString("T");

    // State

    private string _hostPort;
    /// Committed host (the text field commits on Return/Connect, not per
    /// keystroke, so a half-typed host never triggers a load). Setting it
    /// doesn't load anything by itself — Connect does.
    public string HostPort
    {
        get => _hostPort;
        set
        {
            _hostPort = value;
            AppSettings.WebSdrHostPort = value;
            Notify();
        }
    }

    private WebSdrFavorite? _pickedStation;
    /// The station last picked from the directory or Favorites. Its ranges
    /// drive the retune range check while its host is the current one (else
    /// KiwiSDR's 0–30 MHz), and its name/location/ranges are what a star
    /// press saves for that host.
    private WebSdrFavorite? PickedStation
    {
        get => _pickedStation;
        set
        {
            _pickedStation = value;
            AppSettings.WebSdrPickedStation = value;
        }
    }

    /// PickedStation, while its host is still the current one.
    private WebSdrFavorite? CurrentStation =>
        _pickedStation is { } picked && picked.Id == WebSdrFavorite.Key(_hostPort) ? picked : null;

    /// The current host's platform. A host with no known platform (typed by
    /// hand, not yet loaded) is treated as a Kiwi; PageDidLoad records what
    /// the page turns out to be.
    public SdrPlatform CurrentPlatform => CurrentStation?.Platform ?? SdrPlatform.KiwiSdr;

    /// The range check for retunes: the station's own ranges when known,
    /// else KiwiSDR's 0–30 MHz for a Kiwi and no check for a WebSDR (its
    /// ranges are read from its page on the first connect).
    private IReadOnlyList<FrequencyRange>? ActiveBands =>
        CurrentStation?.BandRanges ?? (CurrentPlatform == SdrPlatform.KiwiSdr ? KiwiSdrUrlBuilder.DefaultBands : null);

    private List<WebSdrFavorite> _favorites;
    /// Saved stations, in the user's order.
    public IReadOnlyList<WebSdrFavorite> Favorites => _favorites;

    private void SaveFavorites(List<WebSdrFavorite> favorites)
    {
        _favorites = favorites;
        AppSettings.WebSdrFavorites = [.. favorites];
        Notify();
    }

    /// The rig frequency the window is following (after the debounce), for
    /// the directory's "covers rig frequency" filter. null before the first
    /// rig value, or 0 while the rig isn't connected.
    public long? RigFrequencyHz { get; private set; }

    /// Whether the window should hold a live receiver session. Starts false
    /// on every open (public Kiwis have few listener slots, so a session is
    /// only opened on an explicit Connect / Return), and Disconnect is also
    /// called when the window closes.
    public bool IsConnected { get; private set; }

    private bool _followRig;
    public bool FollowRig
    {
        get => _followRig;
        set
        {
            _followRig = value;
            AppSettings.WebSdrFollowRig = value;
            Evaluate();
            Notify();
        }
    }

    private bool _tuneRig;
    /// Click-to-tune: tuning in the page tunes the rig's Main VFO (and its
    /// mode, where the two map — see SdrPlatformExtensions.RigModeForPageMode).
    /// Independent of FollowRig.
    public bool TuneRig
    {
        get => _tuneRig;
        set
        {
            _tuneRig = value;
            AppSettings.WebSdrTuneRig = value;
            Notify();
        }
    }

    /// What the web view should be showing. Only changes when a genuinely
    /// different page is wanted — every change is a full page reload (Kiwi
    /// reconnect), so rig-driven repeats are filtered out here.
    public PageRequest? Page { get; private set; }

    public string Status { get; private set; } = "";

    // Mute

    private bool _isMuted;
    /// The WebSDR window's Mute. While the page is audible — connected and
    /// not muted here — the rig's Main playback is muted so the two don't
    /// play over each other; muting here (or disconnecting) unmutes Main
    /// again (WebSdrRigLink.SetAudioActive, which only ever undoes a mute it
    /// made itself). Applied to the page live via SdrPageBridge.
    /// SetPageMutedAsync — and on every Kiwi load as the Kiwi's own `mute=1`
    /// URL parameter, so it survives the reload each retune causes; a
    /// WebSDR has no such parameter, so PageDidLoad asserts it instead.
    public bool IsMuted => _isMuted;
    private CancellationTokenSource? _muteCts;

    private bool _muteOnTransmit;
    /// Mutes the page while the rig transmits, so the operator doesn't hear
    /// their own signal come back from the receiver, delayed. Only the page
    /// is muted: IsMuted (the user's Mute) and the rig's Main audio are left
    /// as they are, and the page comes back on its own after TX.
    /// Recordings are unaffected (taken before the page's mute, same as
    /// Mute).
    public bool MuteOnTransmit
    {
        get => _muteOnTransmit;
        set
        {
            _muteOnTransmit = value;
            AppSettings.WebSdrMuteOnTransmit = value;
            ApplyPageMute();
            Notify();
        }
    }

    private bool _isTransmitting;
    private bool? _lastPtt;

    /// What the page's own mute should be: the user's Mute, or TX while
    /// Mute on TX is on.
    private bool PageShouldBeMuted => _isMuted || (_muteOnTransmit && _isTransmitting);

    public void ToggleMuted()
    {
        _isMuted = !_isMuted;
        AppSettings.WebSdrMuted = _isMuted;
        UpdateMainAudio();
        ApplyPageMute();
        Notify();
    }

    private void ApplyPageMute()
    {
        if (Page is null)
        {
            return;
        }
        _muteCts?.Cancel();
        var cts = _muteCts = new CancellationTokenSource();
        var muted = PageShouldBeMuted;
        Run(() => Bridge.SetPageMutedAsync(muted, cts.Token));
    }

    private void UpdateMainAudio() => _rig.SetAudioActive(IsConnected && !_isMuted);

    // Recording (the page's own recorder — see SdrPageBridge)

    /// The user's Record/Stop intent. Stays true across retunes: each
    /// retune saves the current file and starts a new one for the new
    /// frequency once the reloaded (Kiwi) or retuned (WebSDR) page's audio
    /// is running (user decision: one file per frequency).
    public bool IsRecording { get; private set; }
    /// When the current file's recording actually began; null while between
    /// files (saving, reloading, waiting for the page's audio).
    public DateTime? SegmentStartedAt { get; private set; }
    /// Last save/failure note, shown at the right of the status line.
    public string? RecordingNote { get; private set; }

    /// What the page on screen is tuned to — the saved file's label. null
    /// for the bare host page (no `?f=`).
    private FollowTarget? _tunedTarget;
    private CancellationTokenSource? _startCts;
    /// A reload waiting for the current recording to finish saving; only
    /// the newest survives if the rig moves again meanwhile.
    private (PageRequest Request, FollowTarget? Tuned)? _pendingReload;
    private bool _reloading;

    private FollowTarget? _latest;
    private string? _lastIssuedUrl;
    private string? _lastTunedDescription;
    private DateTime _lastTunedAt = DateTime.Now;

    // Rig state in

    private FollowTarget? _lastUpstream;
    private CancellationTokenSource? _debounceCts;

    /// MainWindow, after each poll (and on disconnect, with frequency 0).
    public void OnRigState(RigSnapshot rig)
    {
        var target = new FollowTarget(rig.FrequencyHz, rig.Mode);
        if (target != _lastUpstream)
        {
            _lastUpstream = target;
            _debounceCts?.Cancel();
            var cts = _debounceCts = new CancellationTokenSource();
            Run(async () =>
            {
                try
                {
                    await Task.Delay(FollowDebounce, cts.Token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                _latest = target;
                RigFrequencyHz = target.FrequencyHz;
                // First value (~400 ms after open): load *something* even if
                // there's nothing to tune to. Not done at Connect itself when
                // no rig value has arrived yet — loading the bare host there
                // and then the tuned URL 400 ms later would open two Kiwi
                // sessions back to back, and some Kiwis reject a second
                // connection from the same IP.
                Evaluate(forceHostPage: IsConnected && Page is null);
                Notify();
            });
        }
        // Not debounced: the page should go quiet as soon as the rig is
        // seen transmitting.
        if (rig.Ptt != _lastPtt)
        {
            _lastPtt = rig.Ptt;
            var wasMuted = PageShouldBeMuted;
            _isTransmitting = rig.Ptt;
            if (PageShouldBeMuted != wasMuted)
            {
                ApplyPageMute();
            }
        }
    }

    /// Opens (or, if already connected, reloads) the receiver session.
    /// Before the first rig value has arrived (<400 ms after open), the load
    /// is left to OnRigState's debounce so it goes straight to the tuned URL.
    public void Connect()
    {
        IsConnected = true;
        UpdateMainAudio();
        _lastIssuedUrl = null;
        Evaluate(forceHostPage: _latest is not null);
        Notify();
    }

    /// Picks a station from the directory: fills the host and remembers the
    /// station's receive ranges, but does NOT connect — connecting is always
    /// a separate, explicit Connect. If a different station is currently
    /// connected, that session is ended (never switched to the new one
    /// automatically).
    public void Select(KiwiSdrStation station) => Select(WebSdrFavorite.FromStation(station));

    /// Picks a favorite — same rules as a directory pick. A favorite with no
    /// saved ranges (added from a typed host) uses 0–30 MHz.
    public void Select(WebSdrFavorite favorite)
    {
        if (IsConnected && favorite.Id != WebSdrFavorite.Key(_hostPort))
        {
            Disconnect();
        }
        PickedStation = favorite;
        HostPort = favorite.HostPort;
        Evaluate();
        Notify();
    }

    /// A station clicked in the Stations window's websdr.org tab. Reuses
    /// what's already known about that host (a favorite, or the current
    /// pick — its ranges and title are learned on the first connect) rather
    /// than starting over from the bare host.
    public void SelectWebSdr(string hostPort)
    {
        var key = WebSdrFavorite.Key(hostPort);
        var station = _favorites.FirstOrDefault(f => f.Id == key)
            ?? (_pickedStation?.Id == key ? _pickedStation : null)
            ?? WebSdrFavorite.Create(hostPort, hostPort);
        Select(station with { Platform = SdrPlatform.WebSdr });
    }

    /// Records what the loaded page turned out to be (and, for a WebSDR, its
    /// ranges and title) on the current pick and on a matching favorite, so
    /// the next load uses the right URL form and range check. A name the
    /// user or the directory gave is kept; only a bare-host name is
    /// replaced by the page title.
    private void LearnStation(SdrPlatform platform, List<FrequencyRange>? bands, string? title)
    {
        var host = _hostPort.Trim();
        if (host.Length == 0)
        {
            return;
        }
        WebSdrFavorite Learned(WebSdrFavorite station)
        {
            var learned = station with { Platform = platform };
            if (bands is not null)
            {
                learned = learned with { Bands = FrequencyRange.Encode(bands) };
            }
            if (!string.IsNullOrEmpty(title) && learned.Name == learned.HostPort)
            {
                learned = learned with { Name = title };
            }
            return learned;
        }
        var updated = Learned(CurrentStation ?? WebSdrFavorite.Create(host, host));
        if (updated != _pickedStation)
        {
            PickedStation = updated;
        }
        var index = _favorites.FindIndex(f => f.Id == updated.Id);
        if (index >= 0)
        {
            var favorite = Learned(_favorites[index]);
            if (favorite != _favorites[index])
            {
                var list = new List<WebSdrFavorite>(_favorites) { [index] = favorite };
                SaveFavorites(list);
            }
        }
    }

    // Favorites

    public bool IsFavorite(string hostPort)
    {
        var key = WebSdrFavorite.Key(hostPort);
        return _favorites.Any(f => f.Id == key);
    }

    /// The star next to the host field: saves the current host — with the
    /// picked station's name/location/ranges if that's where it came from,
    /// else the directory's entry for a typed host that happens to be listed
    /// (`directoryStations` is empty until the Stations window has loaded
    /// once; FillInFavorites catches up then) — or removes it if it's
    /// already a favorite.
    public void ToggleFavoriteForCurrentHost(IReadOnlyList<KiwiSdrStation> directoryStations)
    {
        var host = _hostPort.Trim();
        if (host.Length == 0)
        {
            return;
        }
        if (IsFavorite(host))
        {
            RemoveFavorite(host);
            return;
        }
        var key = WebSdrFavorite.Key(host);
        var listed = directoryStations.FirstOrDefault(s => WebSdrFavorite.Key(s.HostPort) == key);
        var favorite = listed is not null
            ? WebSdrFavorite.FromStation(listed)
            : CurrentStation ?? WebSdrFavorite.Create(host, host);
        SaveFavorites([.. _favorites, favorite]);
    }

    /// Gives favorites saved from a typed host (named after the host, no
    /// location/ranges) the directory's details once it's loaded. A name the
    /// user has changed is kept.
    public void FillInFavorites(IReadOnlyList<KiwiSdrStation> stations)
    {
        var byKey = new Dictionary<string, KiwiSdrStation>();
        foreach (var station in stations)
        {
            byKey.TryAdd(WebSdrFavorite.Key(station.HostPort), station);
        }
        var defaultBands = FrequencyRange.Encode(KiwiSdrUrlBuilder.DefaultBands);
        var updated = _favorites.Select(f =>
        {
            if (!byKey.TryGetValue(f.Id, out var station))
            {
                return f;
            }
            var filled = f;
            if (filled.Name == filled.HostPort)
            {
                filled = filled with { Name = station.Name };
            }
            if (filled.Location.Length == 0)
            {
                filled = filled with { Location = station.Location };
            }
            if (filled.Bands is null || filled.Bands == defaultBands)
            {
                filled = filled with { Bands = FrequencyRange.Encode(station.Bands) };
            }
            if (filled.Platform is null)
            {
                filled = filled with { Platform = SdrPlatform.KiwiSdr };
            }
            return filled;
        }).ToList();
        if (!updated.SequenceEqual(_favorites))
        {
            SaveFavorites(updated);
        }
    }

    /// The Stations window's star column.
    public void ToggleFavorite(KiwiSdrStation station)
    {
        if (IsFavorite(station.HostPort))
        {
            RemoveFavorite(station.HostPort);
        }
        else
        {
            SaveFavorites([.. _favorites, WebSdrFavorite.FromStation(station)]);
        }
    }

    public void RemoveFavorite(string hostPort)
    {
        var key = WebSdrFavorite.Key(hostPort);
        SaveFavorites(_favorites.Where(f => f.Id != key).ToList());
    }

    /// Manage Favorites' drag reorder: the favorites' ids in their new order.
    public void ReorderFavorites(IReadOnlyList<string> ids)
    {
        var byId = _favorites.ToDictionary(f => f.Id);
        var reordered = ids.Where(byId.ContainsKey).Select(id => byId[id]).ToList();
        // Anything the list didn't mention stays, at the end.
        reordered.AddRange(_favorites.Where(f => !ids.Contains(f.Id)));
        if (!reordered.SequenceEqual(_favorites))
        {
            SaveFavorites(reordered);
        }
    }

    /// Blank names fall back to the host rather than leaving an empty menu item.
    public void RenameFavorite(string id, string name)
    {
        var index = _favorites.FindIndex(f => f.Id == id);
        if (index < 0)
        {
            return;
        }
        var trimmed = name.Trim();
        var renamed = _favorites[index] with { Name = trimmed.Length == 0 ? _favorites[index].HostPort : trimmed };
        if (renamed == _favorites[index])
        {
            return;
        }
        if (_pickedStation?.Id == id)
        {
            PickedStation = _pickedStation with { Name = renamed.Name };
        }
        SaveFavorites(new List<WebSdrFavorite>(_favorites) { [index] = renamed });
    }

    // Session

    /// Ends the receiver session: the window navigates to about:blank when
    /// Page goes null, which unloads the page and closes its WebSocket
    /// (freeing the listener slot).
    ///
    /// A recording in progress is saved first — unloading the page would
    /// throw it away — so the unload waits for that (≤5 s); the returned
    /// task finishes once it has. The UI shows disconnected immediately.
    public Task Disconnect()
    {
        IsConnected = false;
        UpdateMainAudio();
        _muteCts?.Cancel();
        _pendingReload = null;
        _pendingInPlace = null;
        _lastIssuedUrl = null;
        Task done;
        if (IsRecording)
        {
            EndRecording();
            done = SaveThenUnloadAsync();
        }
        else
        {
            UnloadIfStillDisconnected();
            done = Task.CompletedTask;
        }
        Evaluate();
        Notify();
        return done;
    }

    private async Task SaveThenUnloadAsync()
    {
        NoteSaved(await Bridge.StopAsync());
        UnloadIfStillDisconnected();
        Notify();
    }

    private void UnloadIfStillDisconnected()
    {
        if (IsConnected)
        {
            return;
        }
        StopTuningPoll();
        _loadCts?.Cancel();
        _loadCts = null;
        _loadedPlatform = null;
        Page = null;
        _tunedTarget = null;
    }

    public void ToggleRecording()
    {
        if (IsRecording)
        {
            EndRecording();
            Run(async () =>
            {
                NoteSaved(await Bridge.StopAsync());
                Notify();
            });
        }
        else
        {
            if (!IsConnected || Page is null)
            {
                return;
            }
            IsRecording = true;
            RecordingNote = null;
            StartSegment();
        }
        Notify();
    }

    /// The platform of the page on screen, once it has loaded and been
    /// checked (SdrPageBridge.DetectPlatformAsync); null while none is, or
    /// one is still loading. Only a loaded WebSDR page is retuned in place.
    private SdrPlatform? _loadedPlatform;
    private CancellationTokenSource? _loadCts;

    /// The web view finished loading a receiver page: check what it is (a
    /// typed host was loaded as a Kiwi, which may be wrong) and record that,
    /// apply Mute to a WebSDR (it has no URL parameter for it), and if a
    /// recording spans the reload (a retune), start the next file. A host
    /// that turned out to be a WebSDR is then retuned in place to the rig,
    /// since the `?f=` it was loaded with means nothing to it.
    public void PageDidLoad()
    {
        _loadCts?.Cancel();
        var cts = _loadCts = new CancellationTokenSource();
        Run(async () =>
        {
            var expected = Bridge.Platform;
            var detected = await Bridge.DetectPlatformAsync();
            if (cts.IsCancellationRequested || !IsConnected)
            {
                return;
            }
            var platform = detected ?? expected;
            _loadedPlatform = platform;
            if (detected is not null)
            {
                var bands = await Bridge.ReadBandsAsync();
                var title = platform == SdrPlatform.WebSdr ? await Bridge.PageTitleAsync() : null;
                if (cts.IsCancellationRequested)
                {
                    return;
                }
                LearnStation(platform, bands, title);
            }
            StartTuningPoll();
            if (platform == SdrPlatform.WebSdr && PageShouldBeMuted)
            {
                ApplyPageMute();
            }
            if (IsRecording && !_reloading)
            {
                StartSegment();
            }
            if (platform != expected)
            {
                _lastIssuedUrl = null;
                Evaluate();
            }
            Notify();
        });
    }

    // Click-to-tune (page → rig)

    /// What the current page is tuned to, per the last poll; null before
    /// the page has settled on its first frequency, and cleared whenever a
    /// new page is requested.
    private PageTuning? _pageTuning;
    /// The tuning already acted on (or the page's initial tuning), so each
    /// change is sent to the rig once.
    private PageTuning? _handledPageTuning;
    private CancellationTokenSource? _tuningPollCts;
    /// A rig tune sent from the page that the rig state hasn't shown yet.
    private (long FrequencyHz, RigMode? Mode, DateTime Until)? _pendingRigTune;

    /// Starts on each finished page load (not on request) so a read can't
    /// come from the page being navigated away from.
    private void StartTuningPoll()
    {
        StopTuningPoll();
        var cts = _tuningPollCts = new CancellationTokenSource();
        Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                var reading = await Bridge.ReadTuningAsync();
                if (cts.IsCancellationRequested)
                {
                    return;
                }
                if (reading is { } r)
                {
                    PageTuningRead(new PageTuning(r.FrequencyHz, r.Mode));
                }
                try
                {
                    await Task.Delay(TuningPollInterval, cts.Token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        });
    }

    private void StopTuningPoll()
    {
        _tuningPollCts?.Cancel();
        _tuningPollCts = null;
        _pageTuning = null;
        _handledPageTuning = null;
    }

    private void PageTuningRead(PageTuning reading)
    {
        // The page's first settled tuning is where it was loaded to (the
        // rig's frequency, or the Kiwi's own last one for a bare host page)
        // — never something the user did, so never sent to the rig.
        if (_pageTuning is null)
        {
            _pageTuning = reading;
            _handledPageTuning = reading;
            return;
        }
        // Wait for the tuning to hold still for a poll, so a drag or a spun
        // mouse wheel sends where it stopped, not every step on the way.
        if (reading != _pageTuning)
        {
            _pageTuning = reading;
            return;
        }
        if (reading == _handledPageTuning)
        {
            return;
        }
        _handledPageTuning = reading;
        TuneRigFromPage(reading);
    }

    private void TuneRigFromPage(PageTuning reading)
    {
        if (!_tuneRig)
        {
            return;
        }
        var rig = _rig.Current();
        var frequencyChanged = Math.Abs(reading.FrequencyHz - rig.FrequencyHz) > SameFrequencyToleranceHz;
        var newMode = Bridge.Platform.RigModeForPageMode(reading.Mode, rig.Mode);
        if (!frequencyChanged && newMode is null)
        {
            return;
        }

        var description = KiwiSdrUrlBuilder.KHzString(reading.FrequencyHz) + " kHz " + reading.Mode.ToUpperInvariant();
        if (rig.FrequencyHz <= 0)
        {
            Status = $"Rig not tuned to {description}: no rig frequency yet (rig not connected?)";
            Notify();
            return;
        }
        if (rig.Ptt)
        {
            Status = $"Rig not tuned to {description}: it's transmitting";
            Notify();
            return;
        }
        // The rig rejects a VFO frequency set while in Memory mode.
        if (rig.InMemoryMode)
        {
            Status = $"Rig not tuned to {description}: it's in Memory mode";
            Notify();
            return;
        }

        var until = DateTime.Now + RigTuneGrace;
        _pendingRigTune = (reading.FrequencyHz, newMode, until);
        _rig.Tune(frequencyChanged ? reading.FrequencyHz : null, newMode);
        _lastTunedDescription = description;
        Status = $"Tuned the rig to {description} from the {Bridge.Platform.DisplayName()} at {Now()}";
        Notify();
        // If the rig never shows the new tuning (rejected, disconnected),
        // follow its actual state again once the grace period is over.
        Run(async () =>
        {
            await Task.Delay(RigTuneGrace + TimeSpan.FromMilliseconds(100));
            if (_pendingRigTune is { } pending && DateTime.Now >= pending.Until)
            {
                _pendingRigTune = null;
                Evaluate();
                Notify();
            }
        });
    }

    /// Whether the page on screen is already at `hz`/`token` (after
    /// click-to-tune, or the rig tuned to where the page was), so following
    /// the rig there needs no reload.
    private bool PageAlreadyAt(long hz, string? token)
    {
        if (_pageTuning is not { } tuning || Math.Abs(tuning.FrequencyHz - hz) > SameFrequencyToleranceHz)
        {
            return false;
        }
        // A page mode with no rig equivalent (Kiwi IQ/DRM) was picked in the
        // page on purpose; reloading to the rig's mode after every click
        // would keep undoing it.
        if (token is null || Bridge.Platform.ModeFamily(tuning.Mode) is not { } family)
        {
            return true;
        }
        return family == token;
    }

    private void StartSegment()
    {
        _startCts?.Cancel();
        SegmentStartedAt = null;
        var label = _tunedTarget is { } t ? Recordings.Label(t.FrequencyHz, t.Mode?.DisplayName() ?? "") : "";
        var cts = _startCts = new CancellationTokenSource();
        Run(async () =>
        {
            var started = await Bridge.StartAsync(label, cts.Token);
            if (cts.IsCancellationRequested || !IsRecording)
            {
                return;
            }
            if (started)
            {
                SegmentStartedAt = DateTime.Now;
            }
            else
            {
                EndRecording();
                RecordingNote = $"Recording didn't start — the {Bridge.Platform.DisplayName()}'s audio isn't running.";
            }
            Notify();
        });
    }

    private void EndRecording()
    {
        IsRecording = false;
        SegmentStartedAt = null;
        _startCts?.Cancel();
        _startCts = null;
    }

    private void NoteSaved(string? path)
    {
        if (path is not null)
        {
            RecordingNote = $"Saved “{Path.GetFileNameWithoutExtension(path)}”";
        }
    }

    /// The Kiwi stopped (and saved) on its own — its audio connection
    /// closed, e.g. a listening time limit. Not restarted automatically.
    private void KiwiEndedRecording(string? path)
    {
        if (!IsRecording || _reloading)
        {
            NoteSaved(path);
        }
        else
        {
            EndRecording();
            RecordingNote = "Recording stopped by the KiwiSDR (its connection closed)"
                + (path is null ? "" : $" — saved “{Path.GetFileNameWithoutExtension(path)}”");
        }
        Notify();
    }

    /// Called by the window when a load fails outright (bad host, station
    /// down) so the status line says so instead of a stale "Tuned to".
    public void ReportLoadFailure(string message)
    {
        Status = $"Couldn't load {_hostPort}: {message}";
        Notify();
    }

    /// `forceHostPage`: on window open / host change, show the page even
    /// when there's nothing to tune to yet (rig out of range, not
    /// connected, or Follow off), so the user isn't staring at a blank view.
    private void Evaluate(bool forceHostPage = false)
    {
        if (KiwiSdrUrlBuilder.BaseUrl(_hostPort) is not { } baseUrl)
        {
            Status = _hostPort.Length == 0
                ? "Enter a KiwiSDR or WebSDR host:port and press Connect."
                : $"“{_hostPort}” isn't a valid host:port.";
            return;
        }

        var lastTuned = _lastTunedDescription is null ? "" : $" — last tuned to {_lastTunedDescription}";
        if (!IsConnected)
        {
            Status = "Disconnected" + lastTuned;
            return;
        }

        if (!_followRig)
        {
            if (forceHostPage)
            {
                Issue(baseUrl);
            }
            Status = "Follow off" + lastTuned;
            return;
        }

        if (_latest is not { } latest)
        {
            if (forceHostPage)
            {
                Issue(baseUrl);
            }
            Status = "Waiting for rig state…";
            return;
        }

        switch (CurrentPlatform.Retune(_hostPort, latest.FrequencyHz, latest.Mode, ActiveBands))
        {
            case SdrRetune.Tune(var tuneUrl, var hz, var token):
                // The rig hasn't caught up with a tune sent from the page
                // yet: following its old value would undo the user's click.
                if (_pendingRigTune is { } pending)
                {
                    var caughtUp = Math.Abs(hz - pending.FrequencyHz) <= SameFrequencyToleranceHz
                        && (pending.Mode is null || latest.Mode == pending.Mode);
                    if (!caughtUp && DateTime.Now < pending.Until)
                    {
                        return;
                    }
                    _pendingRigTune = null;
                }
                _lastTunedDescription = (KiwiSdrUrlBuilder.KHzString(hz) + " kHz " + (token?.ToUpperInvariant() ?? "")).Trim();
                // Status is refreshed even when the URL is unchanged (e.g.
                // back in range at the same frequency), so it never goes stale.
                if (!forceHostPage && tuneUrl != _lastIssuedUrl && PageAlreadyAt(hz, token))
                {
                    _lastIssuedUrl = tuneUrl;
                    _tunedTarget = latest;
                    _lastTunedAt = DateTime.Now;
                }
                else if (forceHostPage || tuneUrl != _lastIssuedUrl)
                {
                    Issue(tuneUrl, latest, forceHostPage ? null : WebSdrUrlBuilder.TuneValue(hz, token));
                    _lastTunedAt = DateTime.Now;
                }
                var time = _lastTunedAt.ToString("T");
                Status = token is null
                    ? $"Tuned to {_lastTunedDescription} at {time} (mode unchanged — {latest.Mode?.DisplayName() ?? "this mode"} has no {CurrentPlatform.DisplayName()} equivalent)"
                    : $"Tuned to {_lastTunedDescription} at {time}";
                break;
            case SdrRetune.OutOfRange(var hz, var bands):
                if (forceHostPage)
                {
                    Issue(baseUrl);
                }
                Status = $"Not retuned: {hz / 1_000_000.0:0.000} MHz is outside this {CurrentPlatform.DisplayName()}'s range ({FrequencyRange.Describe(bands)})";
                break;
            case SdrRetune.NoFrequency:
                if (forceHostPage)
                {
                    Issue(baseUrl);
                }
                Status = "Not retuned: no rig frequency yet (rig not connected?)";
                break;
        }
    }

    /// Adds the Kiwi's own `mute=1` when muted here (or transmitting with
    /// Mute on TX on), so a reload comes up muted. Kept out of
    /// _lastIssuedUrl, which dedups on the tuning alone — toggling Mute
    /// must not trigger a reload.
    private string WithMuteParameter(string url) =>
        PageShouldBeMuted && CurrentPlatform == SdrPlatform.KiwiSdr
            ? url + (url.Contains('?') ? "&" : "?") + "mute=1"
            : url;

    /// Loads `newUrl` — unless a recording is running on the current page,
    /// in which case that file is saved first (a reload would lose it) and
    /// the load follows; PageDidLoad then starts the next file.
    ///
    /// `inPlace`: the `setfreqtune()` value for the same tuning. Used
    /// instead of a load when the page on screen is a loaded WebSDR.
    private void Issue(string newUrl, FollowTarget? tuned = null, string? inPlace = null)
    {
        if (inPlace is not null && tuned is { } target && _loadedPlatform == SdrPlatform.WebSdr && Page is not null && !_reloading)
        {
            RetuneInPlace(newUrl, inPlace, target);
            return;
        }
        StopTuningPoll();
        _loadCts?.Cancel();
        _loadCts = null;
        _loadedPlatform = null;
        _pendingInPlace = null;
        _lastIssuedUrl = newUrl;
        var request = new PageRequest(WithMuteParameter(newUrl), CurrentPlatform,
                                      (_pendingReload?.Request.Id ?? Page?.Id ?? 0) + 1);
        if (!IsRecording || Page is null)
        {
            _tunedTarget = tuned;
            Bridge.Platform = request.Platform;
            Page = request;
            return;
        }
        // The bridge keeps the old page's platform until the new page is
        // requested: the stop below is still the old page's recorder.
        _pendingReload = (request, tuned);
        if (_reloading)
        {
            return;
        }
        _startCts?.Cancel();
        SegmentStartedAt = null;
        _reloading = true;
        Run(async () =>
        {
            var path = await Bridge.StopAsync();
            NoteSaved(path);
            _reloading = false;
            if (IsConnected && _pendingReload is { } next)
            {
                _pendingReload = null;
                _tunedTarget = next.Tuned;
                Bridge.Platform = next.Request.Platform;
                Page = next.Request;
            }
            Notify();
        });
    }

    // In-place retune (WebSDR)

    /// The newest WebSDR retune waiting its turn; only the newest survives
    /// if the rig moves again while a recording is being saved.
    private (string Value, FollowTarget Tuned)? _pendingInPlace;
    private bool _retuningInPlace;

    /// Retunes the loaded WebSDR page through its own `setfreqtune()` — no
    /// reload. While recording, the current file is saved first and a new
    /// one started afterwards (one file per frequency, same as a Kiwi
    /// retune). The click-to-tune baseline is reset so the page reporting
    /// its new frequency isn't taken for the user tuning it.
    private void RetuneInPlace(string url, string value, FollowTarget tuned)
    {
        _lastIssuedUrl = url;
        _pendingInPlace = (value, tuned);
        if (_retuningInPlace)
        {
            return;
        }
        _retuningInPlace = true;
        Run(async () =>
        {
            try
            {
                while (_pendingInPlace is { } next)
                {
                    _pendingInPlace = null;
                    if (IsRecording)
                    {
                        _startCts?.Cancel();
                        SegmentStartedAt = null;
                        NoteSaved(await Bridge.StopAsync());
                    }
                    if (!IsConnected || _loadedPlatform != SdrPlatform.WebSdr)
                    {
                        break;
                    }
                    _pageTuning = null;
                    _handledPageTuning = null;
                    await Bridge.RetuneInPlaceAsync(next.Value);
                    _tunedTarget = next.Tuned;
                    _pageTuning = null;
                    _handledPageTuning = null;
                    if (IsRecording && _pendingInPlace is null)
                    {
                        StartSegment();
                    }
                }
            }
            finally
            {
                _retuningInPlace = false;
                Notify();
            }
        });
    }
}

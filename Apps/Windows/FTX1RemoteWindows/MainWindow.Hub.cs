using FTX1RemoteWindows.Controls;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Hub;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;

namespace FTX1RemoteWindows;

/// The iPad's Desktop hub (Apps/Windows/README.md, "Desktop hub for the
/// iPad"): Services/Hub/HubServer.cs pushes this window's state (phase 1)
/// and hands the iPad's commands to Services/Hub/RigCommandDispatcher.cs,
/// which runs them through this window's own methods (phase 2, the
/// IHubRigHost members at the end), relays MAIN/SUB receive audio
/// (phase 3, <see cref="RelayHubAudio"/>), and pushes the memory list and
/// APRS history and answers Deep Settings reads (phase 4,
/// <see cref="PushHubListsIfDue"/>, <see cref="ReadMenuItemForHubAsync"/>).
///
/// The hub runs whenever Settings → Hub allows it, connected to the rig or
/// not, so an iPad stays connected across rigctld reconnects. Pushes are
/// driven by one 100 ms timer that sends the state whenever its JSON
/// changed: each poll stamps LastUpdated (so every poll is pushed) and a
/// local UI action — or an iPad command — that changes _lastState shows up
/// within 100 ms; at most ~10 pushes a second however busy the window is.
/// The iPad doesn't apply its own commands optimistically, so that push is
/// how its controls follow.
public sealed partial class MainWindow : IHubRigHost
{
    private readonly HubServer _hub = new();
    private RigCommandDispatcher? _hubDispatcher;
    private DispatcherQueueTimer? _hubTimer;
    private string? _hubLastJson;
    private readonly HubAudioEncoder _hubMainEncoder = new();
    private readonly HubAudioEncoder _hubSubEncoder = new();
    /// The Mac's rates: memory list at most once a second, APRS history at
    /// most every 2 s.
    private readonly HubPushThrottle _hubMemoryListThrottle = new(TimeSpan.FromSeconds(1));
    private readonly HubPushThrottle _hubAprsListThrottle = new(TimeSpan.FromSeconds(2));
    private string? _hubLastMemoryListJson;
    private string? _hubLastAprsListJson;

    private void InitHub()
    {
        _hubDispatcher = new RigCommandDispatcher(this);
        _hub.CommandReceived += _hubDispatcher.Enqueue;
        // The FIFO's awaits resume on the UI thread it starts on.
        DispatcherQueue.TryEnqueue(() => _ = _hubDispatcher.RunAsync());
        _hubTimer = DispatcherQueue.CreateTimer();
        _hubTimer.Interval = TimeSpan.FromMilliseconds(100);
        _hubTimer.Tick += (_, _) =>
        {
            PushHubStateIfChanged();
            PushHubListsIfDue();
        };
        // Progress (scanningChannel) as well as contents: the iPad shows
        // the read running.
        _memoryListStore.EntriesChanged += _hubMemoryListThrottle.MarkDirty;
        _memoryListStore.StatusChanged += _hubMemoryListThrottle.MarkDirty;
        _aprsStore.Changed += _hubAprsListThrottle.MarkDirty;
        _hub.MenuItemReader = ReadMenuItemForHubAsync;
        if (AppSettings.HubEnabled)
        {
            _ = StartHubAsync();
        }
    }

    /// Settings → Hub's server, for its live status and client list.
    internal HubServer Hub => _hub;

    /// Matches the hub to the saved setting.
    private async Task ApplyHubSettingAsync()
    {
        if (AppSettings.HubEnabled && !_hub.IsListening)
        {
            await StartHubAsync();
        }
        else if (!AppSettings.HubEnabled && _hub.IsListening)
        {
            _hubTimer?.Stop();
            await _hub.StopAsync();
        }
    }

    private async Task StartHubAsync()
    {
        await _hub.StartAsync();
        if (_hub.IsListening)
        {
            _hubLastJson = null;
            PushHubStateIfChanged();
            // Both lists at once, so the first client gets them on connect.
            _hubLastMemoryListJson = null;
            _hubLastAprsListJson = null;
            _hubMemoryListThrottle.MarkDirty();
            _hubAprsListThrottle.MarkDirty();
            PushHubListsIfDue();
            _hubTimer?.Start();
        }
    }

    private void StopHub()
    {
        _hubTimer?.Stop();
        _ = _hub.StopAsync();
    }

    private void PushHubStateIfChanged()
    {
        if (!_hub.IsListening)
        {
            return;
        }
        string json;
        try
        {
            json = HubWire.Serialize(RigStateWireMapper.Push(_lastState, HubExtras()));
        }
        catch (Exception ex)
        {
            AppLog.Write($"hub: state encode failed: {ex.Message}");
            return;
        }
        if (json == _hubLastJson)
        {
            return;
        }
        _hubLastJson = json;
        _hub.Publish(json);
    }

    /// The memory list and APRS history, each when it changed and its
    /// throttle allows (UI thread: both stores live there). A push whose
    /// JSON equals the last one isn't sent again.
    private void PushHubListsIfDue()
    {
        if (!_hub.IsListening)
        {
            return;
        }
        var now = Environment.TickCount64;
        if (_hubMemoryListThrottle.TakeDue(now))
        {
            PublishIfChanged(ref _hubLastMemoryListJson, "memory list", () => HubListWireMapper.MemoryList(
                _memoryListStore.Entries, _memoryListStore.LastScanned, _memoryListStore.ScanningChannel), _hub.PublishMemoryList);
        }
        if (_hubAprsListThrottle.TakeDue(now))
        {
            PublishIfChanged(ref _hubLastAprsListJson, "APRS list",
                () => HubListWireMapper.AprsList(_aprsStore.Stations, _aprsStore.Messages), _hub.PublishAprsList);
        }
    }

    private static void PublishIfChanged<T>(ref string? last, string what, Func<T> build, Action<string> publish)
    {
        string json;
        try
        {
            json = HubWire.Serialize(build());
        }
        catch (Exception ex)
        {
            AppLog.Write($"hub: {what} encode failed: {ex.Message}");
            return;
        }
        if (json == last)
        {
            return;
        }
        last = json;
        publish(json);
    }

    /// A Deep Settings item for a client's read_menu_item — the same read as
    /// this app's Deep Settings dialog (the raw P4, null if the rig doesn't
    /// answer with it). From the hub's thread, off the command FIFO; the
    /// client serializes it with everything else on the link.
    private Task<string?> ReadMenuItemForHubAsync(int p1, int p2, int p3) =>
        _client is { } client ? client.GetMenuItemAsync(p1, p2, p3) : Task.FromResult<string?>(null);

    /// Receive audio for the iPad, from the audio source's callback (never
    /// the UI thread): MAIN and SUB as roles (after the swap), before this
    /// app's own mute/volume/squelch, each chunk → one 8 kHz frame per
    /// channel. SUB only when the source really has a second channel, as
    /// on the Mac. Nothing is encoded while no client is connected. In
    /// Remote mode this app is the Pi's one audio client, so the iPad hears
    /// audio only while this app's audio is on.
    private void RelayHubAudio(float[] main, float[] sub, bool hasSub, int sampleRate)
    {
        if (!_hub.HasClients || sampleRate <= 0)
        {
            return;
        }
        try
        {
            var mainFrame = _hubMainEncoder.Encode(main, sampleRate, HubAudioTags.Main);
            if (mainFrame.Length > 1)
            {
                _hub.BroadcastAudio(mainFrame);
            }
            if (hasSub)
            {
                var subFrame = _hubSubEncoder.Encode(sub, sampleRate, HubAudioTags.Sub);
                if (subFrame.Length > 1)
                {
                    _hub.BroadcastAudio(subFrame);
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"hub: audio encode failed: {ex.Message}");
        }
    }

    /// Whether this app's audio is running — Settings → Hub says so when
    /// not, since the iPad then hears nothing.
    internal bool HubAudioRunning => _audioSource is not null;

    /// What the wire needs from outside _lastState, as the window shows it.
    private HubStateExtras HubExtras()
    {
        var now = DateTime.UtcNow;
        string? Heard((string Callsign, DateTime At)? heard) =>
            heard is { } h && now - h.At < AprsCallsignShownFor ? h.Callsign : null;
        return new HubStateExtras(
            TransmitEnabled: AppSettings.TransmitEnabled,
            AudioChannelsSwapped: _swapTracker.Swapped,
            SingleReceive: _singleReceive,
            SplitEnabled: _splitOn,
            TxSideSub: _txSideSub,
            AprsActive: AppSettings.IsAprsActive(IsConnected ? _lastState.FrequencyHz : null),
            AprsLastCallsign: Heard(_aprsMainLastHeard),
            AprsSubActive: AppSettings.IsAprsActive(IsConnected ? _lastState.SecondaryFrequencyHz : null),
            AprsSubLastCallsign: Heard(_aprsSubLastHeard));
    }

    // IHubRigHost: the dispatcher's way in, each member the method this
    // window's own control uses.

    RigctldClient? IHubRigHost.Client => _client;
    bool IHubRigHost.TransmitEnabled => AppSettings.TransmitEnabled;
    long IHubRigHost.MainFrequencyHz => _lastState.FrequencyHz;
    bool IHubRigHost.MemoryScanActive => _lastState.MemoryScanActive;
    bool IHubRigHost.MemoryScanSub => _lastState.MemoryScanSub;
    MenuGrid IHubRigHost.Menu => _menuGrid;
    FilterPanel IHubRigHost.Filter => _filterPanel;

    Task IHubRigHost.StopMemoryScanAsync(HubScanStop stop) => _client is { } client
        ? StopMemoryScanForAsync(client, null, stop == HubScanStop.Keep ? ScanStopTxSide.Keep : ScanStopTxSide.Restore)
        : Task.CompletedTask;

    Task IHubRigHost.SetMainFrequencyAsync(long hz) => SetMainFrequencyAsync(hz);
    Task IHubRigHost.SetSubFrequencyAsync(long hz) => SetSubFrequencyAsync(hz);
    Task IHubRigHost.SwapVfoAsync() => SwapVfoAsync();
    Task IHubRigHost.SetMainModeAsync(RigMode mode) => SetMainModeAsync(mode);
    Task IHubRigHost.SetMainModeC4fmAsync() => SetMainModeC4fmAsync();
    Task IHubRigHost.SetSubModeAsync(RigMode? mode, bool c4fm) => SetSubModeAsync(mode, c4fm);
    Task IHubRigHost.SetBandAsync(Band band) => SetBandAsync(band);
    Task IHubRigHost.SendPttOffAsync() => SendPttOffAsync();
    Task IHubRigHost.SetPowerLevelAsync(double level) => SetPowerLevelAsync(level);
    Task IHubRigHost.SetTxSideAsync(bool sub) => SetTxSideAsync(sub);
    Task IHubRigHost.SetVfoMemoryModeAsync(bool memory) => SetVfoMemoryModeAsync(memory);
    Task IHubRigHost.SetMemoryChannelAsync(bool sub, int channel) => SetMemoryChannelAsync(sub, channel);
    Task IHubRigHost.StepMemoryChannelAsync(bool sub, bool up) => StepMemoryChannelAsync(sub, up);
    Task IHubRigHost.RecallMemoryChannelAsync(int channel, bool sub) => RecallMemoryChannelAsync(channel, sub);
    Task IHubRigHost.StartMemoryScanAsync(bool sub, bool up) => StartMemoryScanAsync(sub, up);
    Task IHubRigHost.StopMemoryScanFromButtonAsync() => StopMemoryScanFromButtonAsync();
    Task IHubRigHost.SetTransmitEnabledAsync(bool enabled) => SetTransmitEnabledAsync(enabled);

    /// The speaker override, from the iPad: the tracker's Changed handler
    /// moves this window's toggle and saves it.
    void IHubRigHost.SetAudioChannelsSwapped(bool swapped) =>
        _swapTracker.SetManually(swapped, "manual toggle from a hub client");

    /// The Mem List window's Refresh (the window, if open, shows the read's
    /// progress too).
    string IHubRigHost.RefreshMemoryList()
    {
        if (_memoryListStore.IsScanning)
        {
            return "already reading the list";
        }
        if (_client is null)
        {
            return "dropped: not connected to the rig";
        }
        _memoryListStore.Refresh(() => _client);
        return "reading the list";
    }
}

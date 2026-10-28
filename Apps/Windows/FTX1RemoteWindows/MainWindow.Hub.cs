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
/// <see cref="PushHubListsIfDue"/>, <see cref="ReadMenuItemForHubAsync"/>),
/// and keys the rig for the iPad's PTT and sends its microphone to the
/// Pi's ftx1-txaudio.py (Remote) or the Transmit audio output (Local)
/// (phase 5, <see cref="_hubTx"/> and the PTT members at the end), and
/// writes the CW keyer memory for the iPad's CW pane and stops the keyer
/// when its player drops, the lock goes on, the hub stops or the rig is
/// disconnected, confirming each stop (phase 6, <see cref="_hubKeyer"/> and
/// the keyer members at the end).
///
/// The hub runs whenever Settings → Mobile allows it, connected to the rig or
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
    /// Transmit audio for a hub client's PTT: keyed state, sink, silence
    /// watchdog. UI thread only.
    private HubTransmitAudio? _hubTx;
    /// Hub clients' keyer plays: played since the last stop, and whether the
    /// rig's TX is that play. UI thread only.
    private readonly HubKeyerTracker _hubKeyer = new();

    private void InitHub()
    {
        _hubDispatcher = new RigCommandDispatcher(this);
        _hubTx = new HubTransmitAudio(OpenHubTxSink);
        _hub.CommandReceived += _hubDispatcher.Enqueue;
        _hub.TxAudioReceived += _hubDispatcher.EnqueueTxAudio;
        _hub.PttHolderDisconnected += _hubDispatcher.EnqueueHolderDisconnected;
        _hub.KeyerPlayerDisconnected += _hubDispatcher.EnqueueKeyerPlayerDisconnected;
        _hub.CwKeyerHandler = WriteHubKeyerAsync;
        _hub.StatusChanged += () => DispatcherQueue.TryEnqueue(RefreshKeyerForNewHubClient);
        // The FIFO's awaits resume on the UI thread it starts on.
        DispatcherQueue.TryEnqueue(() => _ = _hubDispatcher.RunAsync());
        _hubTimer = DispatcherQueue.CreateTimer();
        _hubTimer.Interval = TimeSpan.FromMilliseconds(100);
        _hubTimer.Tick += (_, _) =>
        {
            PushHubStateIfChanged();
            PushHubListsIfDue();
            CheckHubTxWatchdog();
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

    /// Settings → Mobile's server, for its live status and client list.
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
            await UnkeyIfHubKeyedAsync("hub turned off");
            await StopHubKeyerIfPlayedAsync("hub turned off");
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

    /// Whether this app's audio is running — Settings → Mobile says so when
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

    // Phase 5: PTT and transmit audio from a hub client.

    /// The TX audio watchdog, from the 100 ms hub timer: keyed for a hub
    /// client and no first frame within 5 s of the key, or no frame for
    /// 1.5 s after one → unkey, through the FIFO.
    private void CheckHubTxWatchdog()
    {
        if (_hubTx is not { KeyedBy: { } client } tx)
        {
            return;
        }
        var reason = tx.TakeWatchdogExpiry(Environment.TickCount64) switch
        {
            TxWatchdogExpiry.NoFirstFrame => "watchdog: no transmit audio within 5 s of the key — unkeying",
            TxWatchdogExpiry.Silence => "watchdog: transmit audio stopped while keyed — unkeying",
            _ => null,
        };
        if (reason is not null)
        {
            _hubDispatcher?.EnqueueUnkey(client, $"client {client}, {reason}");
        }
    }

    /// Where a transmission's audio goes, opened on its first frame: the Pi
    /// in Remote mode, the Transmit audio output in Local mode (never the
    /// default output). Null (logged) when there's nowhere to send it.
    private ITxAudioSink? OpenHubTxSink()
    {
        if (_connectedMode == ConnectionMode.Remote)
        {
            var remote = new RemoteTxAudioClient(_connectedHost);
            remote.Start();
            AppLog.Write($"hub: transmit audio → Pi {_connectedHost}:{RemoteTxAudioClient.DefaultPort}");
            return remote;
        }
        var local = LocalTxAudioPlayer.Open(AppSettings.TxAudioOutputDeviceId, AppSettings.TxAudioOutputDeviceName, out var error);
        if (local is null)
        {
            AppLog.Write($"hub: transmit audio dropped: {error}");
        }
        return local;
    }

    /// Ends hub TX audio after an unkey this window made itself (its PTT
    /// release, the lock, a disconnect), logging why if it was keyed for a
    /// hub client. The rig unkey is the caller's.
    private void EndHubTransmit(string reason)
    {
        if (_hubTx?.Unkeyed() is { } client)
        {
            AppLog.Write($"hub: unkey — client {client} ({reason})");
        }
    }

    /// Unkeys the rig if it's keyed for a hub client (the hub stopping).
    private async Task UnkeyIfHubKeyedAsync(string reason)
    {
        if (_hubTx?.IsKeyed == true)
        {
            await ((IHubRigHost)this).UnkeyFromHubAsync(reason);
        }
    }

    int? IHubRigHost.HubKeyedBy => _hubTx?.KeyedBy;

    async Task IHubRigHost.KeyFromHubAsync(int clientId)
    {
        if (_client is not { } client || _hubTx is not { } tx)
        {
            return;
        }
        AppLog.Write($"hub: key — client {clientId} (holder press) at {_lastState.FrequencyHz} Hz");
        // Marked before the round trip, as the window's button sets
        // _pttHeld: the frames queued behind this command are looked at
        // only after it completes anyway.
        tx.Keyed(clientId, Environment.TickCount64);
        _lastState.Ptt = true;
        UpdateTransmitControls();
        try
        {
            await client.SetPttAsync(true);
        }
        catch (Exception ex)
        {
            AppLog.Write($"hub: key for client {clientId} failed: {ex.Message}");
            tx.Unkeyed();
            _lastState.Ptt = false;
            UpdateTransmitControls();
        }
    }

    async Task IHubRigHost.UnkeyFromHubAsync(string reason)
    {
        var was = _hubTx?.Unkeyed();
        AppLog.Write(was is null ? $"hub: unkey ({reason})" : $"hub: unkey — {reason}");
        await SendPttOffAsync();
    }

    void IHubRigHost.TxAudioFromHub(int clientId, byte[] pcm)
    {
        if (_hubTx is not { } tx)
        {
            return;
        }
        if (tx.Frame(clientId, pcm, Environment.TickCount64) == TxFrameResult.DroppedNotKeyed)
        {
            LogHubTxDropped(clientId);
        }
    }

    private long? _hubTxDropLoggedAt;

    /// Frames from the holder while the rig isn't keyed for it (a refused
    /// press, after an unkey), at most every 5 s.
    private void LogHubTxDropped(int clientId)
    {
        var now = Environment.TickCount64;
        if (_hubTxDropLoggedAt is { } last && now - last < 5000)
        {
            return;
        }
        _hubTxDropLoggedAt = now;
        AppLog.Write($"hub: client {clientId}: TX audio dropped (the rig isn't keyed for it through the hub)");
    }

    // Phase 6: the CW keyer for the iPad's CW pane.

    /// A client's cw_keyer write (text) or TEXT check (no text), already
    /// checked by HubKeyerPolicy — the same calls as this app's own
    /// CwSender. From the hub's thread, off the command FIFO; the client's
    /// round-trip lock orders it with everything else on the link. Throws
    /// with a readable message, which goes back as the reply's error.
    private async Task<string?> WriteHubKeyerAsync(int slot, string? text)
    {
        var client = _client ?? throw new InvalidOperationException("Not connected to the rig");
        if (text is null)
        {
            await CwSender.EnsureTextMemoryAsync(client, slot);
            return null;
        }
        return await client.WriteKeyerMemoryAsync(slot, text);
    }

    private int _hubClientCount;

    /// BK-IN, keyer speed and pitch as soon as a client connects, rather than
    /// at the next slow poll: the iPad's CW pane blocks on BK-IN and times
    /// its chunks by the speed, both from the pushed state. The slow tier
    /// keeps them current while a client stays connected.
    private void RefreshKeyerForNewHubClient()
    {
        var count = _hub.Clients.Count;
        var grew = count > _hubClientCount;
        _hubClientCount = count;
        if (grew && _client is { } client)
        {
            _ = _menuGrid.RefreshKeyerAsync(client);
        }
    }

    /// The lock, hub off and disconnect: a confirmed "KY00" if a hub client
    /// played the keyer since the last stop.
    private async Task StopHubKeyerIfPlayedAsync(string reason)
    {
        if (_hubKeyer.PlayedSinceStop)
        {
            await ((IHubRigHost)this).StopHubKeyerConfirmedAsync(reason);
        }
    }

    string? IHubRigHost.KeyerPlayRefusal() => HubKeyerPolicy.PlayRefusal(
        windowPtt: _pttHeld,
        mox: _lastState.MoxEnabled == true,
        hubPtt: _hubTx?.IsKeyed == true,
        rigTransmitting: _lastState.Ptt,
        hubKeyerActive: _hubKeyer.Active);

    void IHubRigHost.KeyerPlayed() => _hubKeyer.Played(Environment.TickCount64);

    void IHubRigHost.KeyerStopped() => _hubKeyer.Stopped();

    /// "KY00", then the rig's TX state ~1 s later, retried and finally PTT
    /// off (HubKeyerStop) — every try and the result in app.log. A stop that
    /// couldn't be confirmed also goes on the status line.
    async Task IHubRigHost.StopHubKeyerConfirmedAsync(string reason)
    {
        if (_client is not { } client)
        {
            AppLog.Write($"hub: keyer stop — not connected to the rig, nothing sent ({reason})");
            _hubKeyer.Stopped();
            return;
        }
        var result = await HubKeyerStop.RunAsync(reason,
            sendStop: () => client.SetRawIntAsync("KY0", 0, 1),
            readTransmitting: async () => await client.GetPttAsync(),
            pttOff: () => client.SetPttAsync(false),
            delay: d => Task.Delay(d),
            log: AppLog.Write);
        _hubKeyer.Stopped();
        if (result is HubKeyerStopResult.StillTransmitting or HubKeyerStopResult.Unconfirmed)
        {
            StatusText.Text = Loc.S("mainWindow.theKeyerMayStill");
        }
    }

    // IHubRigHost: the dispatcher's way in, each member the method this
    // window's own control uses.

    RigctldClient? IHubRigHost.Client => _client;
    bool IHubRigHost.TransmitEnabled => AppSettings.TransmitEnabled;
    TransmitSignal IHubRigHost.Transmitter => TransmitterNow();
    PrivilegeProfile? IHubRigHost.Privileges => _activePrivileges;
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

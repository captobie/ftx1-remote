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
/// IHubRigHost members at the end).
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

    private void InitHub()
    {
        _hubDispatcher = new RigCommandDispatcher(this);
        _hub.CommandReceived += _hubDispatcher.Enqueue;
        // The FIFO's awaits resume on the UI thread it starts on.
        DispatcherQueue.TryEnqueue(() => _ = _hubDispatcher.RunAsync());
        _hubTimer = DispatcherQueue.CreateTimer();
        _hubTimer.Interval = TimeSpan.FromMilliseconds(100);
        _hubTimer.Tick += (_, _) => PushHubStateIfChanged();
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
}

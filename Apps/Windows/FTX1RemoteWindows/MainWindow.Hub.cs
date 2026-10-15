using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Hub;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;

namespace FTX1RemoteWindows;

/// The iPad's Desktop hub (Apps/Windows/README.md, "Desktop hub for the
/// iPad"), phase 1: Services/Hub/HubServer.cs pushes this window's state.
///
/// The hub runs whenever Settings → Hub allows it, connected to the rig or
/// not, so an iPad stays connected across rigctld reconnects. Pushes are
/// driven by one 100 ms timer that sends the state whenever its JSON
/// changed: each poll stamps LastUpdated (so every poll is pushed) and a
/// local UI action that changes _lastState shows up within 100 ms — at
/// most ~10 pushes a second however busy the window is.
public sealed partial class MainWindow
{
    private readonly HubServer _hub = new();
    private DispatcherQueueTimer? _hubTimer;
    private string? _hubLastJson;

    private void InitHub()
    {
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
}

using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Hub;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace FTX1RemoteWindows;

/// APRS transmit — beacons, messages and acks as Bell 202 audio through the
/// same TX audio path as the RTTY/PSK window (the Pi's ftx1-txaudio.py in
/// Remote mode, Settings → Audio → Transmit audio output in Local mode).
/// The Mac's HubService+APRSTransmitLink.swift plus the keying helpers in
/// HubService.swift; the transmitter and messaging are Services/
/// AprsTransmitter.cs and AprsMessaging.cs.
public sealed partial class MainWindow
{
    private AprsTransmitter _aprsTransmitter = null!;
    private AprsMessaging _aprsMessaging = null!;
    private DispatcherQueueTimer _aprsTimer = null!;
    /// The open transmission's audio sink; one per packet.
    private ITxAudioSink? _aprsSink;
    /// Every key/unkey batch waits for the one before: two independent tasks
    /// interleaved on the Mac ("FT1", "TX0", "FT0", then "TX1" keyed MAIN's HF
    /// frequency until the License guard unkeyed it).
    private Task _aprsKeyChain = Task.CompletedTask;

    private void InitAprsTransmit()
    {
        AprsTransmitSettings.Config = new AppAprsTransmitConfig();
        _aprsTransmitter = new AprsTransmitter(new AprsTransmitLink(this), AppLog.Write);
        _aprsMessaging = new AprsMessaging(_aprsStore, _aprsTransmitter, AppLog.Write);
        _aprsMessaging.SettingsChanged();
        _aprsTimer = DispatcherQueue.CreateTimer();
        _aprsTimer.Interval = TimeSpan.FromSeconds(1);
        _aprsTimer.Tick += (_, _) => _aprsMessaging.Tick();
        _aprsTimer.Start();
    }

    private void StopAprsTransmit()
    {
        _aprsTimer.Stop();
        _aprsTransmitter.StopAll("app quitting");
    }

    private void AprsBeaconNowMenuItem_Click(object sender, RoutedEventArgs e) => _aprsMessaging.BeaconNow();

    /// A decoded message from either receiver: acks/auto-acks via the
    /// messaging, then listed — except our own (digipeated copies of what we
    /// sent; M.LIST already has them) and acks/rejects addressed to us (shown
    /// as the sent message's delivery state instead). UI thread.
    private void ReceivedAprsMessage(string from, string to, string text, string? messageId, AprsSource source)
    {
        _aprsMessaging.HandleIncoming(from, to, text, messageId);
        if (AprsTransmitSettings.SourceCall is { } myCall)
        {
            if (from.ToUpperInvariant() == myCall)
            {
                return;
            }
            if (to.ToUpperInvariant() == myCall && messageId is null && AprsOutgoing.ReplyTo(text, null) is not null)
            {
                return;
            }
        }
        _aprsStore.RecordMessage(from, to, text, messageId, DateTimeOffset.Now, source);
    }

    private void EnqueueAprsKeying(Func<Task> step)
    {
        var previous = _aprsKeyChain;
        _aprsKeyChain = RunAfterAsync(previous, step);
    }

    private static async Task RunAfterAsync(Task previous, Func<Task> step)
    {
        try
        {
            await previous;
        }
        catch
        {
            // The earlier step reported its own failure.
        }
        await step();
    }

    /// Moves the TX side first when the packet needs the other receiver
    /// (the transmit gate was already judged for it), then keys.
    private async Task KeyForAprsAsync(AprsSource? switchTo)
    {
        if (_client is null)
        {
            return;
        }
        if (switchTo is { } side)
        {
            await SetTxSideAsync(side == AprsSource.Sub);
        }
        _lastState.Ptt = true;
        UpdateTransmitControls();
        try
        {
            await _client.SetPttAsync(true);
        }
        catch (Exception ex)
        {
            StatusText.Text = Loc.F("mainWindow.setPTTFailedX", ex.Message);
        }
    }

    /// Unkeys, then the TX side back. "Off" needs no gate.
    private async Task UnkeyForAprsAsync(AprsSource? restoreSide)
    {
        await SendPttOffAsync();
        if (restoreSide is { } side && _client is not null)
        {
            await SetTxSideAsync(side == AprsSource.Sub);
        }
    }

    /// The Mac's HubService+APRSTransmitLink, on this window.
    private sealed class AprsTransmitLink(MainWindow window) : IAprsTransmitLink
    {
        public AprsTransmitDecision PlanTransmit()
        {
            if (!window.IsConnected)
            {
                return AprsTransmitDecision.Blocked(Loc.S("digiLink.notConnected"));
            }
            if (window._lastState.Ptt || window._pttHeld || window._lastState.MoxEnabled == true
                || window._hubTx?.IsKeyed == true || window._digiSender.IsTransmitting || window._tuning)
            {
                return AprsTransmitDecision.Blocked(Loc.S("digiLink.alreadyTransmitting"));
            }
            if (window._connectedMode == ConnectionMode.Local && string.IsNullOrEmpty(AppSettings.TxAudioOutputDeviceId))
            {
                return AprsTransmitDecision.Blocked(Loc.S("digiLink.noTransmitAudioOutput"));
            }
            return AprsTransmitPlanner.Plan(window.AprsRigView(), AppSettings.TransmitEnabled, window._activePrivileges,
                AppSettings.AprsFrequencyHz, AppSettings.AprsToleranceHz);
        }

        /// Judged as if <paramref name="side"/> transmits: right after keying the
        /// rig may still report the old TX side (the "FT" switch lands a poll
        /// later), and the main gate would judge that one.
        public string? TransmitBlock(AprsSource side)
        {
            if (!window.IsConnected)
            {
                return Loc.S("digiLink.notConnected");
            }
            var rig = window.AprsRigView();
            var signal = side == AprsSource.Main ? rig.Main : rig.Sub;
            return TransmitGate.BlockReason(TransmitAction.PttOn, AppSettings.TransmitEnabled, signal, window._activePrivileges);
        }

        public void Key(AprsSource? switchTo)
        {
            // A fresh sink per packet, dropped here (not in the chained step)
            // because the first audio follows this call at once.
            window._aprsSink = null;
            window.EnqueueAprsKeying(() => window.KeyForAprsAsync(switchTo));
        }

        public void Unkey(AprsSource? restoreSide)
        {
            var sink = window._aprsSink;
            window._aprsSink = null;
            sink?.Finish();
            window.EnqueueAprsKeying(() => window.UnkeyForAprsAsync(restoreSide));
        }

        public void SendAudio(byte[] pcm)
        {
            window._aprsSink ??= window.OpenHubTxSink();
            window._aprsSink?.Send(pcm);
        }

        public bool ChannelBusy(AprsSource side, double seconds) =>
            (side == AprsSource.Main ? window._aprsMainDecoder : window._aprsSubDecoder).HeardActivity(seconds);
    }

    private AprsRigView AprsRigView() => new(
        _lastState.MemoryScanActive,
        _splitOn,
        _singleReceive,
        _txSideSub,
        new TransmitSignal(_lastState.FrequencyHz, _lastState.Mode, _lastState.MainIsC4fm == true),
        new TransmitSignal(_lastState.SecondaryFrequencyHz ?? 0, _lastState.SubMode, _lastState.SubIsC4fm == true));
}

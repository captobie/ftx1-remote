using FTX1RemoteWindows.Controls;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.FreeDv;
using FTX1RemoteWindows.Services.Hub;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using NAudio.Wave;

namespace FTX1RemoteWindows;

/// Tools → FreeDV (Controls/FreeDvWindow.cs; FreeDV RADE V1 and FreeDV
/// Reporter in Services/FreeDv/): the Mac's HubService wiring for the
/// receiver, sender and reporter plus HubService+FreeDVTransmitLink.swift. Keying goes through the same
/// transmit gate as the PTT button; the sender's audio goes where the iPad's
/// microphone audio goes — the Pi's ftx1-txaudio.py in Remote mode, Settings →
/// Audio → Transmit audio output in Local mode.
public sealed partial class MainWindow
{
    private FreeDvWindow? _freeDvWindow;
    private FreeDvReceiver _freeDvReceiver = null!;
    private FreeDvSender _freeDvSender = null!;
    private FreeDvReporter _freeDvReporter = null!;
    /// While the window is open: the Kiwi's dial changes without telling
    /// anyone, and the rig may be disconnected.
    private DispatcherQueueTimer? _freeDvReporterTimer;
    /// The open transmission's audio sink; one per transmission.
    private ITxAudioSink? _freeDvSink;
    /// Bumped on every key/unkey, so a key still waiting for the memory scan
    /// to stop doesn't fire after the unkey that followed it.
    private int _freeDvKeyGeneration;
    /// Which receivers' own playback FreeDV is holding muted.
    private bool _freeDvHoldsMain;
    private bool _freeDvHoldsSub;

    /// Called once from the constructor, after InitFt8.
    private void InitFreeDv()
    {
        Action<Action> post = work => DispatcherQueue.TryEnqueue(() => work());
        _freeDvReceiver = new FreeDvReceiver(post, AppSettings.FreeDv, AppSettings.SaveFreeDv,
            () => new FreeDvSpeechPlayer(ResolveFreeDvOutput),
            channel => channel == CwAudioChannel.MyKiwiSdr ? _localSdrSource.FrequencyHz : null,
            label => Recordings.NewRecordingPath(label, DateTime.Now),
            path => new MediaFoundationReader(path),
            AppLog.Write);
        _freeDvSender = new FreeDvSender(new FreeDvTransmitLink(this),
            new FreeDvMicrophone(() => AppSettings.FreeDv.MicrophoneDeviceId),
            () => AppSettings.Callsign, post, AppSettings.FreeDv.TxLevelDb, AppLog.Write);
        _freeDvSender.StateChanged += state => _freeDvReceiver.SetSenderActive(state != FreeDvSender.SenderState.Idle);

        _freeDvReceiver.VoiceChanged += ApplyFreeDvAudioOverrides;
        _localSdrSource.AddConsumer(
            "freedv",
            () => _freeDvReceiver.IsRunning && _freeDvReceiver.Channel == CwAudioChannel.MyKiwiSdr,
            (samples, rate) => _freeDvReceiver.Ingest(samples, rate, CwAudioChannel.MyKiwiSdr));
        _localSdrSource.Changed += () => _freeDvReceiver.SetKiwiMode(_localSdrSource.Mode);
        _freeDvReceiver.ChannelChanged += UpdateFreeDvSources;
        _freeDvReporter = new FreeDvReporter(AppSettings.FreeDv, AppSettings.SaveFreeDv,
            $"FTX1Remote {UpdateChecker.CurrentVersionText}",
            () => (AppSettings.Callsign, AppSettings.GridSquare), AppLog.Write, FreeDvReporterUrlOverride());
        _freeDvReceiver.ChannelChanged += UpdateFreeDvReporterFrequency;
        _freeDvReceiver.HeardLive += station =>
        {
            // A remote WebSDR isn't at our QTH: its spots aren't ours to
            // report.
            if (station.Channel != CwAudioChannel.WebSdr)
            {
                _freeDvReporter.ReportHeard(station.Callsign, station.SnrDb);
            }
        };
        _freeDvSender.StateChanged += state => _freeDvReporter.SetTransmitting(state != FreeDvSender.SenderState.Idle);
    }

    /// Debug builds: FTX1REMOTE_FREEDV_REPORTER_URL points the reporter at a
    /// stand-in server (ws://…) instead of qso.freedv.org, for testing
    /// without putting this station on the real list.
    private static Uri? FreeDvReporterUrlOverride()
    {
#if DEBUG
        if (Environment.GetEnvironmentVariable("FTX1REMOTE_FREEDV_REPORTER_URL") is { Length: > 0 } url)
        {
            AppLog.Write($"freedv-reporter: using {url} instead of {FreeDvReporterProtocol.DefaultHost}");
            return new Uri(url);
        }
#endif
        return null;
    }

    private void UpdateFreeDvSources()
    {
        _localSdrSource.Update();
        UpdateFt8WebSdrTap();
    }

    private void FreeDvButton_Click(object sender, RoutedEventArgs e)
    {
        if (_freeDvWindow is null)
        {
            var window = new FreeDvWindow(_freeDvReceiver, _freeDvSender, _freeDvReporter, new FreeDvWindowLink
            {
                SingleReceive = () => IsConnected ? _singleReceive : null,
                LocalSdr = _localSdrSource,
                WebSdrNote = Ft8WebSdrNote,
                ShowRecordings = ShowRecordings,
                TuneMain = TuneFromFreeDvReporter,
            });
            _freeDvWindow = window;
            window.Closed += (_, _) =>
            {
                _freeDvWindow = null;
                // Not left keyed with nobody watching: closing ends the over.
                _freeDvSender.Finish();
                _freeDvReceiver.Stop();
                _freeDvReporterTimer?.Stop();
                _freeDvReporter.SetActive(false);
                UpdateFreeDvSources();
            };
            PushRigStateToFreeDv();
            _freeDvReceiver.Start();
            UpdateFreeDvSources();
            if (_freeDvReporterTimer is null)
            {
                _freeDvReporterTimer = DispatcherQueue.CreateTimer();
                _freeDvReporterTimer.Interval = TimeSpan.FromSeconds(2);
                _freeDvReporterTimer.Tick += (_, _) => UpdateFreeDvReporterFrequency();
            }
            _freeDvReporterTimer.Start();
            UpdateFreeDvReporterFrequency();
            _freeDvReporter.SetActive(true);
        }
        _freeDvWindow.Activate();
    }

    /// Modes and frequencies only while connected (the last session's would
    /// otherwise linger in _lastState).
    private void PushRigStateToFreeDv()
    {
        _freeDvReceiver.RigInfoChanged(IsConnected
            ? new FreeDvRigInfo(
                Transmitting: _lastState.Ptt || _pttHeld,
                MainMode: _lastState.MainIsC4fm == true ? null : _lastState.Mode,
                SubMode: _lastState.SubIsC4fm == true ? null : _lastState.SubMode,
                MainHz: _lastState.FrequencyHz > 0 ? _lastState.FrequencyHz : null,
                SubHz: _lastState.SecondaryFrequencyHz,
                MainIsC4fm: _lastState.MainIsC4fm == true,
                SubIsC4fm: _lastState.SubIsC4fm == true)
            : default);
        UpdateFreeDvReporterFrequency();
    }

    /// What FreeDV Reporter shows as our frequency: the FreeDV window's
    /// source (MAIN, SUB, the Kiwi), else where the rig would transmit.
    private void UpdateFreeDvReporterFrequency()
    {
        var channel = _freeDvReceiver.Channel;
        long? hz = null;
        if (IsConnected || channel == CwAudioChannel.MyKiwiSdr)
        {
            hz = channel switch
            {
                CwAudioChannel.Main => _lastState.FrequencyHz,
                CwAudioChannel.Sub => _lastState.SecondaryFrequencyHz,
                CwAudioChannel.MyKiwiSdr => _localSdrSource.FrequencyHz,
                _ => TransmitterNow().FrequencyHz,
            };
        }
        _freeDvReporter.SetFrequency(hz is > 0 ? hz : null);
    }

    /// The window's station list: MAIN to a FreeDV Reporter station's
    /// frequency, on the band's sideband (LSB below 10 MHz, USB above; DATA-U
    /// kept if MAIN is already in it). The WebSDR click-to-tune rules: not
    /// while transmitting, not in Memory mode. Returns why it didn't tune.
    private string? TuneFromFreeDvReporter(long frequencyHz)
    {
        if (!IsConnected)
        {
            return Loc.S("common.theRigIsntConnected");
        }
        if (_lastState.Ptt || _pttHeld || _freeDvSender.IsActive)
        {
            return Loc.S("mainWindow.theRigIsTransmitting");
        }
        if (_lastState.InMemoryMode)
        {
            return Loc.S("mainWindow.mAINIsInMemory");
        }
        var mode = FreeDvSidebands.For(frequencyHz) == FreeDvSideband.Lower
            ? RigMode.Lsb
            : _lastState.Mode == RigMode.DataUsb ? RigMode.DataUsb : RigMode.Usb;
        long? hz = frequencyHz != _lastState.FrequencyHz ? frequencyHz : null;
        RigMode? newMode = mode != _lastState.Mode || _lastState.MainIsC4fm == true ? mode : null;
        if (hz is not null || newMode is not null)
        {
            AppLog.Write($"freedv-reporter: tune {frequencyHz} Hz {mode.DisplayName()}");
            _ = TuneFromWebSdrAsync(hz, newMode);
        }
        return null;
    }

    /// While FreeDV voice is received from MAIN or SUB, that receiver's own
    /// playback is muted, so the decoded speech isn't played over the modem
    /// noise (the Mac's setMainAudioOverride/setSubAudioOverride, holder
    /// .freeDV). Only a change of FreeDV's own hold acts, so an operator who
    /// unmuted meanwhile isn't overridden.
    private void ApplyFreeDvAudioOverrides()
    {
        CwAudioChannel? voice = _freeDvReceiver.IsReceivingVoice ? _freeDvReceiver.Channel : null;
        var main = voice == CwAudioChannel.Main;
        if (main != _freeDvHoldsMain)
        {
            _freeDvHoldsMain = main;
            ApplyMainAudioOverride(MainAudioHeld);
        }
        var sub = voice == CwAudioChannel.Sub;
        if (sub != _freeDvHoldsSub)
        {
            _freeDvHoldsSub = sub;
            ApplySubAudioOverride(sub);
        }
    }

    /// Sub's counterpart to ApplyMainAudioOverride (same rules): mutes it only
    /// if it isn't muted already, and unmutes it only if this muted it.
    private void ApplySubAudioOverride(bool active)
    {
        if (active)
        {
            if (_subPlayer.IsMuted)
            {
                return;
            }
            AppSettings.SubMutedByFreeDv = true;
            SetSubMuted(true);
        }
        else
        {
            if (!AppSettings.SubMutedByFreeDv)
            {
                return;
            }
            AppSettings.SubMutedByFreeDv = false;
            SetSubMuted(false);
        }
    }

    private void SetSubMuted(bool muted)
    {
        _subPlayer.IsMuted = muted;
        SubMuteToggle.IsChecked = muted;
        AppSettings.SubAudio.Muted = muted;
        AppSettings.SaveAudio();
    }

    /// Where the decoded speech plays: Settings → Audio's output device, with
    /// the main playback's guard — in Local mode never the radio's own USB
    /// audio, which would feed its transmit input.
    private (string? DeviceId, string? Blocked) ResolveFreeDvOutput()
    {
        var chosenId = AppSettings.AudioOutputDeviceId;
        var outputId = AudioPlayback.ResolveOutputId(chosenId);
        var mode = IsConnected ? _connectedMode : AppSettings.ConnectionMode;
        var captureId = AppSettings.LocalAudioDeviceId;
        if (mode == ConnectionMode.Local && outputId is not null
            && (outputId == AppSettings.TxAudioOutputDeviceId
                || (captureId.Length > 0 && LocalAudioCapture.IsSameAdapter(captureId, outputId))))
        {
            var usingDefault = chosenId.Length == 0 || outputId != chosenId;
            return (null, usingDefault
                ? Loc.S("mainWindow.windowsDefaultOutputIs")
                : Loc.S("mainWindow.theOutputChosenIn"));
        }
        return (outputId, null);
    }

    /// Keys the rig for the FreeDV sender, as the PTT button does: the
    /// transmit gate has already been checked, the memory scan stops first.
    private async Task KeyForFreeDvAsync()
    {
        var generation = ++_freeDvKeyGeneration;
        _freeDvSink = null;
        _lastState.Ptt = true;
        UpdateTransmitControls();
        await StopMemoryScanBeforeTransmitAsync();
        if (generation != _freeDvKeyGeneration || _client is not { } client)
        {
            return;
        }
        try
        {
            await client.SetPttAsync(true);
        }
        catch (Exception ex)
        {
            StatusText.Text = Loc.F("mainWindow.setPTTFailedX", ex.Message);
        }
    }

    private async Task UnkeyForFreeDvAsync()
    {
        _freeDvKeyGeneration++;
        var sink = _freeDvSink;
        _freeDvSink = null;
        sink?.Finish();
        await SendPttOffAsync();
    }

    /// Opens the sink on the first audio of a transmission.
    private void SendFreeDvAudio(byte[] pcm)
    {
        _freeDvSink ??= OpenHubTxSink();
        _freeDvSink?.Send(pcm);
    }

    /// The window closed, or the app is quitting.
    private void ShutDownFreeDv()
    {
        _freeDvSender.Stop();
        _freeDvWindow?.Close();
        _freeDvReporterTimer?.Stop();
        _freeDvReporter.SetActive(false);
        _freeDvReceiver.Dispose();
    }

    /// The Mac's HubService+FreeDVTransmitLink, on this window.
    private sealed class FreeDvTransmitLink(MainWindow window) : IFreeDvTransmitLink
    {
        public string? TransmitBlock(bool keyedBySender)
        {
            if (!window.IsConnected)
            {
                return Loc.S("digiLink.notConnected");
            }
            if (window.TransmitBlockReason(TransmitAction.PttOn) is { } reason)
            {
                return reason;
            }
            // The band's sideband (freedv.org: LSB below 10 MHz, USB above).
            var transmitter = window.TransmitterNow();
            var expected = FreeDvSidebands.For(transmitter.FrequencyHz);
            if (transmitter.IsC4fm || transmitter.Mode is not { } mode || !expected.Suits(mode))
            {
                var name = transmitter.IsC4fm ? "C4FM" : transmitter.Mode?.DisplayName() ?? "—";
                return Loc.F("freeDvLink.wrongMode", name, expected == FreeDvSideband.Lower ? "LSB" : "USB / DATA-U");
            }
            if (keyedBySender)
            {
                return null;
            }
            if (window._lastState.Ptt || window._pttHeld || window._lastState.MoxEnabled == true
                || window._hubTx?.IsKeyed == true || window._digiSender.IsTransmitting
                || window._aprsTransmitter.IsTransmitting || window._tuning)
            {
                return Loc.S("digiLink.alreadyTransmitting");
            }
            // Only before keying: these walk Windows' device list.
            var local = window._connectedMode == ConnectionMode.Local;
            var txOutput = AppSettings.TxAudioOutputDeviceId;
            // Local mode sends the audio to the chosen device, never the
            // default one.
            if (local && (txOutput.Length == 0 || AudioPlayback.ResolveOutputId(txOutput) != txOutput))
            {
                return Loc.S("digiLink.noTransmitAudioOutput");
            }
            if (FreeDvMicrophone.Resolve(AppSettings.FreeDv.MicrophoneDeviceId) is not { } microphone)
            {
                return Loc.S("freeDvMic.notConnected");
            }
            // Windows often makes the radio's own input the default recording
            // device, so the resolved microphone is checked, not just a chosen one.
            var rigInput = AppSettings.LocalAudioDeviceId;
            if (local && (rigInput.Length > 0
                    ? microphone == rigInput
                    : LocalAudioCapture.IsSameAdapter(microphone, txOutput)))
            {
                return Loc.S("freeDvLink.micIsRigInput");
            }
            return null;
        }

        public bool RigIsKeyed => window._lastState.Ptt;

        public void SetKeyed(bool keyed) => _ = keyed ? window.KeyForFreeDvAsync() : window.UnkeyForFreeDvAsync();

        public void SendAudio(byte[] pcm) => window.SendFreeDvAudio(pcm);
    }
}

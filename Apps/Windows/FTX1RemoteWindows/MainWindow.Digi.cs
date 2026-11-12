using FTX1RemoteWindows.Controls;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Digi;
using FTX1RemoteWindows.Services.Hub;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;

namespace FTX1RemoteWindows;

/// Tools → RTTY/PSK (Controls/DigiWindow.cs, decoding in
/// Services/Digi/DigiReceiver.cs, sending in Services/Digi/DigiSender.cs):
/// the Mac's HubService+DigiTransmitLink.swift plus the window's wiring.
/// Keying goes through the same transmit gate as the PTT button; the
/// sender's audio goes where the iPad's microphone audio goes — the Pi's
/// ftx1-txaudio.py in Remote mode, Settings → Audio → Transmit audio output
/// in Local mode.
public sealed partial class MainWindow
{
    private DigiWindow? _digiWindow;
    private readonly DigiReceiver _digiReceiver;
    private readonly DigiSender _digiSender;
    /// The open transmission's audio sink; one per transmission.
    private ITxAudioSink? _digiSink;
    /// Bumped on every key/unkey, so a key still waiting for the memory scan
    /// to stop doesn't fire after the unkey that followed it.
    private int _digiKeyGeneration;

    private void DigiButton_Click(object sender, RoutedEventArgs e)
    {
        if (_digiWindow is null)
        {
            _digiWindow = new DigiWindow(_digiReceiver, _digiSender, new DigiWindowLink
            {
                SingleReceive = () => IsConnected ? _singleReceive : null,
                IsConnected = () => IsConnected,
                ReadMenuItemAsync = ReadMenuItemForDigiAsync,
                ModSourceWarningAsync = DigiModSourceWarningAsync,
            });
            _digiWindow.Closed += (_, _) => _digiWindow = null;
            PushRigStateToDigi();
        }
        _digiWindow.Activate();
    }

    /// Modes only while connected (the last session's would otherwise linger
    /// in _lastState); null in C4FM, which has no RigMode here.
    private void PushRigStateToDigi() => _digiReceiver.RigInfoChanged(IsConnected
        ? new DigiRigInfo(
            _lastState.Ptt || _pttHeld,
            _lastState.MainIsC4fm == true ? null : _lastState.Mode,
            _lastState.SubIsC4fm == true ? null : _lastState.SubMode)
        : default);

    private async Task<string?> ReadMenuItemForDigiAsync(int p1, int p2, int p3)
    {
        if (_client is not { } client)
        {
            return null;
        }
        try
        {
            return await client.GetMenuItemAsync(p1, p2, p3);
        }
        catch (Exception ex)
        {
            AppLog.Write($"digi: menu read EX{p1:00}{p2:00}{p3:00} failed: {ex.Message}");
            return null;
        }
    }

    /// The transmitting mode's MOD SOURCE (MODE DATA EX010413, MODE SSB
    /// EX010113), when it would send something other than this window's
    /// audio: MIC or Bluetooth. USB and AUTO pass. Null when fine or unknown.
    private async Task<string?> DigiModSourceWarningAsync()
    {
        var link = (IDigiTransmitLink)new DigiTransmitLink(this);
        var group = link.TransmitMode switch
        {
            RigMode.DataUsb => (P2: 4, Name: "DATA"),
            RigMode.Usb or RigMode.Lsb => (P2: 1, Name: "SSB"),
            _ => default,
        };
        if (group.Name is null)
        {
            return null;
        }
        if (!int.TryParse(await ReadMenuItemForDigiAsync(1, group.P2, 13), out var value))
        {
            return null;
        }
        var source = value switch
        {
            0 => "MIC",
            2 => "Bluetooth",
            _ => null,
        };
        return source is null ? null : Loc.F("digiLink.modSourceWarning", group.Name, source);
    }

    /// Keys the rig for the RTTY/PSK sender, as the PTT button does: the
    /// transmit gate has already been checked, the memory scan stops first.
    private async Task KeyForDigiAsync()
    {
        var generation = ++_digiKeyGeneration;
        _digiSink = null;
        _lastState.Ptt = true;
        UpdateTransmitControls();
        await StopMemoryScanBeforeTransmitAsync();
        if (generation != _digiKeyGeneration || _client is not { } client)
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

    private async Task UnkeyForDigiAsync()
    {
        _digiKeyGeneration++;
        var sink = _digiSink;
        _digiSink = null;
        sink?.Finish();
        await SendPttOffAsync();
    }

    /// Opens the sink on the first audio of a transmission (the Pi's
    /// connection in Remote mode, the output device in Local mode).
    private void SendDigiAudio(byte[] pcm)
    {
        _digiSink ??= OpenHubTxSink();
        _digiSink?.Send(pcm);
    }

    /// The Mac's HubService+DigiTransmitLink, on this window.
    private sealed class DigiTransmitLink(MainWindow window) : IDigiTransmitLink
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
            if (!keyedBySender && (window._lastState.Ptt || window._pttHeld || window._lastState.MoxEnabled == true
                    || window._hubTx?.IsKeyed == true || window._aprsTransmitter.IsTransmitting))
            {
                return Loc.S("digiLink.alreadyTransmitting");
            }
            // Only before keying; Local mode sends the audio to the chosen
            // device, never the default one.
            if (!keyedBySender && window._connectedMode == ConnectionMode.Local
                && string.IsNullOrEmpty(AppSettings.TxAudioOutputDeviceId))
            {
                return Loc.S("digiLink.noTransmitAudioOutput");
            }
            return null;
        }

        public RigMode? TransmitMode
        {
            get
            {
                if (!window.IsConnected)
                {
                    return null;
                }
                var transmitter = window.TransmitterNow();
                return transmitter.IsC4fm ? null : transmitter.Mode;
            }
        }

        public bool RigIsKeyed => window._lastState.Ptt;

        public void SetKeyed(bool keyed) => _ = keyed ? window.KeyForDigiAsync() : window.UnkeyForDigiAsync();

        public void SendAudio(byte[] pcm) => window.SendDigiAudio(pcm);
    }
}

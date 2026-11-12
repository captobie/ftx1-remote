using FTX1RemoteWindows.Models;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows;

/// The TUNE button — the Mac's TuneTone (CLAUDE.md "TUNE button"). Switches
/// MAIN to CW, keys a plain carrier so an external auto-tuner (ATU-100 Plus)
/// sees RF, and on the next press or after 20 s unkeys and puts the previous
/// mode back (only if the mode is still CW). No audio is sent; the power is
/// the rig's RF POWER. Goes through TransmitGate, judged as CW.
public sealed partial class MainWindow
{
    private const int TuneTimeoutSeconds = 20;
    private const long TuneKeyLossGraceMs = 2000;
    private const long TuneKeyLossLimitMs = 1000;

    private DispatcherQueueTimer? _tuneTimer;
    private bool _tuning;
    private long _tuneStartedMs;
    private long? _tuneKeyLostAtMs;
    private RigMode? _tunePreviousMode;
    private string? _tuneMessage;
    private int _tuneSecondsLeft = TuneTimeoutSeconds;

    private void InitTuneControls()
    {
        _tuneTimer = DispatcherQueue.CreateTimer();
        _tuneTimer.Interval = TimeSpan.FromMilliseconds(100);
        _tuneTimer.Tick += (_, _) => TuneTick();
        UpdateTuneButton();
    }

    /// Why TUNE would be refused now; null when it would start.
    private string? TuneBlockReason()
    {
        if (_tuning)
        {
            return null;
        }
        if (!IsConnected)
        {
            return Loc.S("digiLink.notConnected");
        }
        if (_pttHeld || _lastState.Ptt || _lastState.MoxEnabled == true || _digiSender.IsTransmitting
            || _aprsTransmitter.IsTransmitting)
        {
            return Loc.S("digiLink.alreadyTransmitting");
        }
        if (_splitOn != true && _txSideSub == true)
        {
            return Loc.S("tune.txOnSub");
        }
        // The gate judges the transmission as it will be: in CW.
        var tx = TransmitterNow() with { Mode = RigMode.Cw, IsC4fm = false };
        return TransmitGate.BlockReason(TransmitAction.PttOn, AppSettings.TransmitEnabled, tx, _activePrivileges);
    }

    private async void TuneButton_Click(object sender, RoutedEventArgs e)
    {
        if (_tuning)
        {
            await StopTuneAsync(null);
        }
        else
        {
            await StartTuneAsync();
        }
    }

    private async Task StartTuneAsync()
    {
        if (_tuning || _client is not { } client)
        {
            return;
        }
        if (TuneBlockReason() is { } reason)
        {
            _tuneMessage = reason;
            StatusText.Text = reason;
            UpdateTuneButton();
            return;
        }
        _tuneMessage = null;
        _tuneSecondsLeft = TuneTimeoutSeconds;
        _tunePreviousMode = _lastState.Mode;
        _tuneStartedMs = Environment.TickCount64;
        _tuneKeyLostAtMs = null;
        _tuning = true;
        UpdateTuneButton();
        AppLog.Write($"tune: started (was {_tunePreviousMode?.DisplayName() ?? "?"})");
        try
        {
            await StopMemoryScanBeforeTransmitAsync();
            if (!_tuning)
            {
                return;
            }
            // In order: mode, then key.
            if (_tunePreviousMode != RigMode.Cw)
            {
                _commandGeneration++;
                await client.SetModeAsync(RigMode.Cw);
                _lastState.Mode = RigMode.Cw;
            }
            if (!_tuning)
            {
                // Stopped while the mode change was going out.
                await RestoreTuneModeAsync(client);
                return;
            }
            await client.SetPttAsync(true);
            _tuneTimer?.Start();
        }
        catch (Exception ex)
        {
            AppLog.Write($"tune: start failed: {ex.Message}");
            await StopTuneAsync(Loc.F("mainWindow.setPTTFailedX", ex.Message));
        }
    }

    /// Unkeys and restores the mode. <paramref name="reason"/> becomes the
    /// button's tooltip and the status line.
    private async Task StopTuneAsync(string? reason)
    {
        if (!_tuning)
        {
            return;
        }
        _tuning = false;
        _tuneTimer?.Stop();
        _tuneMessage = reason;
        if (reason is not null)
        {
            StatusText.Text = reason;
        }
        UpdateTuneButton();
        AppLog.Write($"tune: stopped{(reason is null ? "" : $": {reason}")}");
        if (_client is not { } client)
        {
            return;
        }
        // Never gated, like every unkey.
        await SendPttOffAsync();
        await RestoreTuneModeAsync(client);
    }

    /// Only if the operator hasn't changed the mode meanwhile.
    private async Task RestoreTuneModeAsync(RigctldClient client)
    {
        var previous = _tunePreviousMode;
        _tunePreviousMode = null;
        if (previous is { } mode && mode != RigMode.Cw && _lastState.Mode == RigMode.Cw)
        {
            try
            {
                _commandGeneration++;
                await client.SetModeAsync(mode);
                _lastState.Mode = mode;
            }
            catch (Exception ex)
            {
                StatusText.Text = Loc.F("mainWindow.setModeFailedX", ex.Message);
            }
        }
    }

    private async void TuneTick()
    {
        if (!_tuning)
        {
            _tuneTimer?.Stop();
            return;
        }
        var now = Environment.TickCount64;
        var elapsed = now - _tuneStartedMs;
        if (elapsed >= TuneTimeoutSeconds * 1000L)
        {
            await StopTuneAsync(Loc.F("tune.timeout", TuneTimeoutSeconds));
            return;
        }
        var left = (int)Math.Ceiling((TuneTimeoutSeconds * 1000L - elapsed) / 1000.0);
        if (left != _tuneSecondsLeft)
        {
            _tuneSecondsLeft = left;
            UpdateTuneButton();
        }
        if (!IsConnected)
        {
            await StopTuneAsync(Loc.S("digiLink.notConnected"));
            return;
        }
        if (!AppSettings.TransmitEnabled)
        {
            await StopTuneAsync(Loc.S("tune.transmitOff"));
            return;
        }
        if (elapsed > TuneKeyLossGraceMs && !_lastState.Ptt)
        {
            if (_tuneKeyLostAtMs is { } lostAt)
            {
                if (now - lostAt > TuneKeyLossLimitMs)
                {
                    await StopTuneAsync(Loc.S("tune.keyingEnded"));
                }
            }
            else
            {
                _tuneKeyLostAtMs = now;
            }
        }
        else
        {
            _tuneKeyLostAtMs = null;
        }
    }

    /// Disconnect or window close mid-tune: unkey and restore before the
    /// client goes. Returns true when it sent the unkey.
    private bool StopTuneBeforeDisconnect()
    {
        if (!_tuning)
        {
            return false;
        }
        _tuning = false;
        _tuneTimer?.Stop();
        AppLog.Write("tune: stopped by disconnect");
        var previous = _tunePreviousMode;
        _tunePreviousMode = null;
        if (_client is { } client)
        {
            try
            {
                client.SetPttAsync(false).Wait(TimeSpan.FromSeconds(1));
                if (previous is { } mode && mode != RigMode.Cw && _lastState.Mode == RigMode.Cw)
                {
                    client.SetModeAsync(mode).Wait(TimeSpan.FromSeconds(1));
                }
            }
            catch (Exception ex)
            {
                AppLog.Write($"tune: unkey before disconnect failed: {ex.Message}");
            }
        }
        UpdateTuneButton();
        return true;
    }

    /// Caption, colour and enabled state; runs after every poll via
    /// UpdateTransmitControls too, since the block reason depends on rig state.
    private void UpdateTuneButton()
    {
        if (TuneButton is null)
        {
            return;
        }
        var reason = TuneBlockReason();
        TuneButton.Content = _tuning ? $"TUNE {_tuneSecondsLeft}" : "TUNE";
        if (_tuning)
        {
            TuneButton.Background = new SolidColorBrush(Colors.Red);
            TuneButton.Foreground = new SolidColorBrush(Colors.White);
        }
        else
        {
            TuneButton.ClearValue(Control.BackgroundProperty);
            TuneButton.ClearValue(Control.ForegroundProperty);
        }
        TuneButton.IsEnabled = _tuning || reason is null;
        ToolTipService.SetToolTip(TuneButton, _tuning
            ? Loc.S("tune.helpStop")
            : reason ?? _tuneMessage ?? Loc.F("tune.help", TuneTimeoutSeconds));
    }
}

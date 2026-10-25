using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows;

/// Wavelog CAT, both ways (Settings → Logbook → Wavelog) — the Mac's
/// HubService.wavelogRadio/wavelogTuner: the rig's state reported to
/// Wavelog after every poll (WavelogRadioReporter), and spots clicked in
/// Wavelog tuning MAIN (WavelogTuneListener). Both run from window open to
/// close, whether or not the rig is connected.
public sealed partial class MainWindow
{
    private WavelogRadioReporter _wavelogReporter = null!;
    private WavelogTuneListener _wavelogTuner = null!;

    private void InitWavelog()
    {
        _wavelogReporter = new WavelogRadioReporter();
        _wavelogReporter.Start();
        _wavelogTuner = new WavelogTuneListener(TuneFromWavelogOnUiThreadAsync, () => AppSettings.WavelogUrl);
        ApplyWavelogSettings(resend: false);
        PushRigStateToWavelog();
    }

    private void StopWavelog()
    {
        _wavelogReporter.Stop();
        _wavelogTuner.Stop();
    }

    /// After Settings → Save: the listener follows its switch and port, and
    /// the reporter sends again with whatever changed.
    private void ApplyWavelogSettings(bool resend = true)
    {
        _wavelogTuner.Apply(AppSettings.WavelogTuneEnabled, AppSettings.WavelogTunePort);
        if (resend)
        {
            _wavelogReporter.Resend();
        }
    }

    /// After every poll and on disconnect, like the WebSDR window's push.
    private void PushRigStateToWavelog() => _wavelogReporter.Update(WavelogStatusNow());

    /// What Wavelog is told: the transmitting side (the Log pane's rule,
    /// CwTransmitterNow), and MAIN as RX while it isn't the one
    /// transmitting and differs — the Mac's WavelogRadioReporter.status.
    private Wavelog.RadioStatus? WavelogStatusNow()
    {
        if (CwTransmitterNow() is not { FrequencyHz: > 0 } tx)
        {
            return null;
        }
        var status = new Wavelog.RadioStatus(
            tx.FrequencyHz,
            Wavelog.CatMode(tx.Mode, tx.IsC4fm),
            PowerWatts: tx.PowerLevel is { } level ? Math.Round(level * 100) : null);
        if ((_splitOn == true || _txSideSub == true) && _lastState.FrequencyHz > 0)
        {
            var mainMode = Wavelog.CatMode(_lastState.Mode, _lastState.MainIsC4fm == true);
            if (_lastState.FrequencyHz != tx.FrequencyHz || mainMode != status.Mode)
            {
                status = status with { FrequencyRxHz = _lastState.FrequencyHz, ModeRx = mainMode };
            }
        }
        return status;
    }

    /// The listener's callback, from the thread pool.
    private Task<string?> TuneFromWavelogOnUiThreadAsync(WavelogTuneRequest request)
    {
        var result = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!DispatcherQueue.TryEnqueue(() => result.TrySetResult(TuneFromWavelog(request))))
        {
            result.TrySetResult("the app is closing");
        }
        return result.Task;
    }

    /// A spot clicked in Wavelog: MAIN's frequency and, when Wavelog named
    /// one, its mode — the WebSDR window's click-to-tune rules (not while
    /// transmitting, not in Memory mode), through the same paths. Returns
    /// why it didn't tune, in words Settings shows.
    private string? TuneFromWavelog(WavelogTuneRequest request)
    {
        if (!IsConnected)
        {
            return "the rig isn't connected";
        }
        if (_lastState.Ptt || _pttHeld)
        {
            return "the rig is transmitting";
        }
        if (_lastState.InMemoryMode)
        {
            return "MAIN is in Memory mode — press V/M first";
        }
        long? hz = request.FrequencyHz != _lastState.FrequencyHz ? request.FrequencyHz : null;
        RigMode? mode = request.Mode is { } m && (m != _lastState.Mode || _lastState.MainIsC4fm == true) ? m : null;
        if (hz is not null || mode is not null)
        {
            _ = TuneFromWebSdrAsync(hz, mode);
        }
        return null;
    }
}

using FTX1RemoteWindows.Controls;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Ft8;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace FTX1RemoteWindows;

/// Tools → FT8 / FT4 (Controls/Ft8Window.cs, decoding in
/// Services/Ft8/Ft8DecodeCoordinator.cs over the native ft8_lib): the Mac's
/// HubService wiring for the two coordinators, stores and the PSK Reporter
/// uploader. Decoding runs only while a mode's window is open, and both can be
/// open at once; the spots outlive the window (like the Mac's stores) so a
/// reopened window shows the session so far.
public sealed partial class MainWindow
{
    private Ft8Store _ft8Store = null!;
    private Ft8Store _ft4Store = null!;
    private Ft8DecodeCoordinator _ft8Coordinator = null!;
    private Ft8DecodeCoordinator _ft4Coordinator = null!;
    private PskReporterUploader _pskReporter = null!;
    private Ft8Window? _ft8Window;
    private Ft8Window? _ft4Window;

    // WebSDR source: one capture of the WebSDR window's audio shared by both
    // windows (the RTTY/PSK and CW receivers each own theirs), running while
    // either decodes with WebSDR picked.
    private WebSdrAudioTap? _ft8WebSdrTap;
    private DispatcherQueueTimer? _ft8WebSdrTimer;
    private WebSdrTapPhase _ft8WebSdrPhase = WebSdrTapPhase.Stopped;
    private string? _ft8WebSdrFailure;

    /// Called once from the constructor.
    private void InitFt8()
    {
        _pskReporter = new PskReporterUploader(DispatcherQueue);
        _ft8Store = new Ft8Store(Ft8Mode.Ft8);
        _ft4Store = new Ft8Store(Ft8Mode.Ft4);
        _ft8Coordinator = WireFt8(_ft8Store);
        _ft4Coordinator = WireFt8(_ft4Store);
    }

    private bool Ft8WantsWebSdr =>
        (_ft8Store.IsRunning && _ft8Store.Channel == CwAudioChannel.WebSdr)
        || (_ft4Store.IsRunning && _ft4Store.Channel == CwAudioChannel.WebSdr);

    /// Starts or stops the WebSDR capture to match what the windows want.
    private void UpdateFt8WebSdrTap()
    {
        if (Ft8WantsWebSdr)
        {
            _ft8WebSdrTap ??= new WebSdrAudioTap(
                (samples, rate) =>
                {
                    // Capture thread; each coordinator drops it unless its window picked WebSDR.
                    _ft8Coordinator.Ingest(samples, rate, CwAudioChannel.WebSdr);
                    _ft4Coordinator.Ingest(samples, rate, CwAudioChannel.WebSdr);
                },
                (phase, detail) => DispatcherQueue.TryEnqueue(() =>
                {
                    _ft8WebSdrPhase = phase;
                    _ft8WebSdrFailure = detail;
                }));
            if (_ft8WebSdrTimer is null)
            {
                _ft8WebSdrTimer = DispatcherQueue.CreateTimer();
                _ft8WebSdrTimer.Interval = TimeSpan.FromSeconds(2);
                _ft8WebSdrTimer.Tick += (_, _) => RefreshFt8WebSdrTarget();
            }
            RefreshFt8WebSdrTarget();
            _ft8WebSdrTap.Start();
            _ft8WebSdrTimer.Start();
        }
        else
        {
            _ft8WebSdrTimer?.Stop();
            _ft8WebSdrTap?.Stop();
        }
    }

    private void RefreshFt8WebSdrTarget() => _ft8WebSdrTap?.SetTarget(_webSdrWindow?.BrowserProcessId);

    /// What's wrong with the WebSDR source, if anything (the CW window's wording).
    private string? Ft8WebSdrNote()
    {
        if (_webSdrWindow is not { } webSdr)
        {
            return Loc.S("cwWindow.openTheWebSDRWindow");
        }
        if (!webSdr.Model.IsConnected)
        {
            return Loc.S("cwWindow.connectTheWebSDRWindow");
        }
        return _ft8WebSdrPhase switch
        {
            WebSdrTapPhase.Failed => Loc.F("cwWindow.cantCaptureTheWebSDRs", _ft8WebSdrFailure),
            WebSdrTapPhase.Silent when webSdr.Model.IsMuted => Loc.S("cwWindow.theWebSDRIsMuted"),
            WebSdrTapPhase.Silent => Loc.S("cwWindow.theWebSDRIsSilent"),
            WebSdrTapPhase.WaitingForWebSdr => Loc.S("cwWindow.waitingForTheWebSDR"),
            _ => null,
        };
    }

    private Ft8DecodeCoordinator WireFt8(Ft8Store store)
    {
        var coordinator = new Ft8DecodeCoordinator(store.Mode, work => DispatcherQueue.TryEnqueue(() => work()))
        {
            // Read on the decoder's worker when a slot begins.
            DialFrequencyProvider = channel => channel switch
            {
                CwAudioChannel.Sub => _lastState.SecondaryFrequencyHz ?? 0,
                CwAudioChannel.MyKiwiSdr => _localSdrSource.FrequencyHz ?? 0,
                _ => _lastState.FrequencyHz,
            },
        };
        coordinator.SetChannel(store.Channel);
        store.ChannelChanged += channel =>
        {
            coordinator.SetChannel(channel);
            _localSdrSource.Update();
            UpdateFt8WebSdrTap();
        };
        _localSdrSource.AddConsumer(
            store.Mode.Name().ToLowerInvariant(),
            () => store.IsRunning && store.Channel == CwAudioChannel.MyKiwiSdr,
            (samples, rate) => coordinator.Ingest(samples, rate, CwAudioChannel.MyKiwiSdr));
        coordinator.SpotsDecoded += decoded =>
        {
            var spots = decoded.Select(d => new Ft8Spot(d, store.Mode.Name())).ToList();
            store.Record(spots);
            _pskReporter.Enqueue(spots);
        };
        coordinator.CycleStatusChanged += store.UpdateCycleStatus;
        return coordinator;
    }

    /// From the audio routing (audio thread), every chunk: cheap while no
    /// window decodes.
    private void IngestFt8(float[] main, float[] sub, int sampleRate)
    {
        var wanted8 = _ft8Store.IsRunning;
        var wanted4 = _ft4Store.IsRunning;
        if (!wanted8 && !wanted4)
        {
            return;
        }
        var subHasAudio = sub.Any(sample => sample != 0);
        foreach (var (store, coordinator) in new[] { (_ft8Store, _ft8Coordinator), (_ft4Store, _ft4Coordinator) })
        {
            if (!store.IsRunning)
            {
                continue;
            }
            if (subHasAudio)
            {
                store.NoteSubAudio();
            }
            coordinator.Ingest(main, sampleRate, CwAudioChannel.Main);
            coordinator.Ingest(sub, sampleRate, CwAudioChannel.Sub);
        }
    }

    private void Ft8Button_Click(object sender, RoutedEventArgs e) => OpenFt8Window(Ft8Mode.Ft8);

    private void Ft4Button_Click(object sender, RoutedEventArgs e) => OpenFt8Window(Ft8Mode.Ft4);

    private void OpenFt8Window(Ft8Mode mode)
    {
        var existing = mode == Ft8Mode.Ft8 ? _ft8Window : _ft4Window;
        if (existing is not null)
        {
            existing.Activate();
            return;
        }
        var store = mode == Ft8Mode.Ft8 ? _ft8Store : _ft4Store;
        var coordinator = mode == Ft8Mode.Ft8 ? _ft8Coordinator : _ft4Coordinator;
        var window = new Ft8Window(store, _pskReporter, _localSdrSource, () => IsConnected ? _singleReceive : null, Ft8WebSdrNote);
        if (mode == Ft8Mode.Ft8)
        {
            _ft8Window = window;
        }
        else
        {
            _ft4Window = window;
        }
        window.Closed += (_, _) =>
        {
            StopFt8Decoding(mode);
            if (mode == Ft8Mode.Ft8)
            {
                _ft8Window = null;
            }
            else
            {
                _ft4Window = null;
            }
        };
        store.IsRunning = true;
        coordinator.Start();
        _localSdrSource.Update();
        UpdateFt8WebSdrTap();
        _pskReporter.Start(mode);
        window.Activate();
    }

    /// The window closed, or the app is quitting with it open.
    private void StopFt8Decoding(Ft8Mode mode)
    {
        var store = mode == Ft8Mode.Ft8 ? _ft8Store : _ft4Store;
        (mode == Ft8Mode.Ft8 ? _ft8Coordinator : _ft4Coordinator).Stop();
        store.IsRunning = false;
        _localSdrSource.Update();
        UpdateFt8WebSdrTap();
        _pskReporter.Stop(mode);
    }

    /// Both windows (app shutdown).
    private void ShutDownFt8()
    {
        _ft8Window?.Close();
        _ft4Window?.Close();
        _ft8WebSdrTimer?.Stop();
        _ft8WebSdrTap?.Dispose();
        _pskReporter.Dispose();
        _ft8Coordinator.Dispose();
        _ft4Coordinator.Dispose();
    }

    private void ApplyThemeToFt8Windows()
    {
        _ft8Window?.ApplyTheme();
        _ft4Window?.ApplyTheme();
    }
}

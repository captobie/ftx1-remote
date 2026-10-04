using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using FTX1RemoteWindows.Controls;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows;

/// v1 core-rig-control window: VFO A/B, mode, PTT, power, SWR, band — see
/// Apps/Windows/README.md's "v1 scope" — plus Main/Sub audio playback from
/// the Pi's :8532 stream, the MENU grid (Controls/MenuGrid.cs), Deep
/// Settings, the Filter rows, the waterfall/oscilloscope and APRS decoding
/// (Services/AprsDecoder.cs, lists in Controls/AprsListWindow.cs) and the
/// WebSDR window (Controls/WebSdrWindow.cs) and the CW window
/// (Controls/CwWindow.cs, decoding in Services/CwReceiver.cs).
public sealed partial class MainWindow : Window
{
    /// rigctld's port — fixed in both modes: the Pi's rigctld.service
    /// listens on it (matching RigctldSettings.remoteHost on the Mac), and
    /// a Local rigctld is launched on it so WSJT-X's "Hamlib NET rigctl"
    /// default (localhost:4532) finds it too.
    private const int RigctldPort = 4532;

    /// Local mode connects over IPv4 loopback and launches rigctld with
    /// -T pinned to the same address (see RigctldProcessController).
    private const string LocalHost = "127.0.0.1";

    /// How long a freshly spawned rigctld gets to open the COM port and
    /// bind its listener before a connect failure is reported — the
    /// counterpart of the Mac's startupGracePeriod. Remote mode and an
    /// adopted rigctld get a single attempt, same as before.
    private static readonly TimeSpan LocalStartupGracePeriod = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan LocalStartupRetryInterval = TimeSpan.FromMilliseconds(250);

    private RigctldClient? _client;
    private readonly RigctldProcessController _rigctldProcess = new();
    private readonly DispatcherQueueTimer _pollTimer;

    /// Suppresses ComboBox SelectionChanged handlers while the poll loop
    /// is writing a freshly-read value into them, so reading the rig's
    /// current mode/band doesn't turn around and re-send it as a set
    /// command.
    private bool _suppressSelectionEvents;

    /// Same idea for the power slider: the poll moving it to the rig's
    /// current level used to fire ValueChanged and send that level straight
    /// back ("L RFPOWER") every second.
    private bool _suppressPowerEvents;

    /// True from a pointer press on the power slider until release. While
    /// set, ValueChanged doesn't send (one command on release instead of one
    /// per drag tick) and the poll leaves the slider alone, so it can't snap
    /// the thumb back mid-drag.
    private bool _powerDragging;
    /// The poll also leaves the slider alone briefly after a send, until
    /// the rig reports the new level — otherwise a poll that read the old
    /// level just before the set landed would flick the thumb back.
    private DateTime _powerHoldUntil;
    private static readonly TimeSpan PowerHoldAfterSend = TimeSpan.FromSeconds(2);

    private readonly RigState _lastState = new();

    /// The MENU grid; shares _lastState, and its settings are read in the
    /// slow poll tier.
    private readonly MenuGrid _menuGrid;

    /// The Filter rows (WIDTH, SHIFT, CONTOUR/APF, N/W, NOTCH, MAIN/SUB and
    /// the display); shares _lastState, read in the slow poll tier.
    private readonly FilterPanel _filterPanel;

    /// The waterfall/oscilloscope between the meters (Controls/
    /// ScopeDisplay.cs), fed by _scopeProcessor from the audio thread.
    private readonly ScopeDisplay _scope = new();
    private readonly ScopeProcessor _scopeProcessor;
    /// Frames from the audio thread, drained on the UI thread. One drain is
    /// queued at a time (_scopeDrainPending), so a busy UI thread gets a
    /// batch of rows rather than a backlog of dispatcher items.
    private readonly ConcurrentQueue<ScopeFrame> _scopeFrames = new();
    private volatile float[]? _latestSubSpectrum;
    private int _scopeDrainPending;
    /// The running audio source's rate, for the FFT's Hz-per-bin.
    private volatile int _audioSampleRate;
    private ScopeDisplayMode _scopeMode;
    /// Not persisted, like the Mac's HubService.waterfallZoom/
    /// oscilloscopeZoom: 0.25-4x in steps of 1.25x.
    private float _waterfallZoom = 1;
    private float _oscilloscopeZoom = 1;
    private const float MinScopeZoom = 0.25f;
    private const float MaxScopeZoom = 4;
    private const float ScopeZoomStep = 1.25f;

    /// APRS decoding, one decoder per receiver (the Mac's aprsDecoder/
    /// aprsDecoderSub), fed from the audio thread while that receiver's VFO
    /// is on the APRS frequency; both feed the one shared history.
    private readonly AprsDecoder _aprsMainDecoder = new("main");
    private readonly AprsDecoder _aprsSubDecoder = new("sub");
    private readonly AprsStore _aprsStore = new();
    /// The open S.LIST/M.LIST windows, at most one of each.
    private readonly Dictionary<AprsListKind, AprsListWindow> _aprsWindows = [];
    /// The WebSDR window, while open (one at a time, like the Mac's Window
    /// scene).
    private WebSdrWindow? _webSdrWindow;
    /// CW decoding (the Mac's HubService.cwReceiver): fed both receivers'
    /// audio from the audio thread, decoding only while _cwWindow is open.
    private readonly CwReceiver _cwReceiver;
    /// The CW window's send pane (the Mac's HubService.cwSender); keeps
    /// sending a queued line when the window closes.
    private readonly CwSender _cwSender;
    private CwWindow? _cwWindow;
    /// The CW page's RECORD (the Mac's HubService.audioRecorder): fed Main
    /// from the audio thread, a no-op while not recording.
    private readonly AudioRecorder _audioRecorder = new();
    /// The CW page's PLAY window, while open.
    private RecordingsWindow? _recordingsWindow;
    /// Each VFO's last polled frequency, for the audio thread's APRS gate
    /// (0 = unknown). Written by the poll, read with Volatile on the audio
    /// thread.
    private long _aprsMainGateHz;
    private long _aprsSubGateHz;
    /// Last gate state per receiver (audio thread), so only opening and
    /// closing get logged.
    private bool _aprsMainGateOpen;
    private bool _aprsSubGateOpen;
    /// The most recently decoded station on each receiver and when, shown
    /// in that VFO's box for 5 s — the Mac's aprsLastCallsignHeard/
    /// aprsLastCallsignHeardSub.
    private (string Callsign, DateTime At)? _aprsMainLastHeard;
    private (string Callsign, DateTime At)? _aprsSubLastHeard;
    private static readonly TimeSpan AprsCallsignShownFor = TimeSpan.FromSeconds(5);

    /// The analog meters under each VFO (Controls/SMeter.cs), fed every poll.
    private readonly SMeter _mainMeter = new(isSub: false);
    private readonly SMeter _subMeter = new(isSub: true);

    /// Upper bound of the SQL sliders, which show `SquelchRange - threshold`
    /// so that further right = tighter — same inversion and range as the
    /// Mac's ContentView.squelchDisplayRange.
    private const double SquelchRange = 0.05;

    private readonly ChannelPlayer _mainPlayer;
    private readonly ChannelPlayer _subPlayer;
    private readonly AudioPlayback _playback;
    /// The Pi stream (Remote) or the local input device (Local), while
    /// audio is running.
    private IAudioSource? _audioSource;
    /// Why audio couldn't start at all (no input device chosen, feedback
    /// guard, ...), shown instead of a link state.
    private string? _audioSetupError;
    private string _connectedHost = "";
    private readonly DispatcherQueueTimer _audioStatusTimer;
    private string? _playbackError;
    /// Set while the feedback guard is holding playback back (Local mode:
    /// Windows' default output is the radio's own codec). Windows makes a
    /// freshly plugged USB audio device the default output, so this happens
    /// after every replug of the radio; the status timer rechecks every
    /// <see cref="PlaybackRecheckTicks"/> ticks and starts playback once the
    /// default output is something else.
    private string? _playbackBlockedForDeviceId;
    private int _playbackRecheckCountdown;
    /// Informational playback note (e.g. the chosen output is unplugged and
    /// Windows' default is used instead), shown after the link state.
    private string? _playbackNote;
    private const int PlaybackRecheckTicks = 8;

    /// Suppresses the audio controls' change handlers while the constructor
    /// loads saved values into them.
    private bool _suppressAudioEvents;

    /// L/R audio vs. Main/Sub role parity — see AudioChannelSwapTracker.
    private readonly AudioChannelSwapTracker _swapTracker;
    /// Copy of _swapTracker.Swapped for the audio receive thread.
    private volatile bool _audioChannelsSwapped;
    /// Bumped by every app command that moves a VFO. A poll that saw one
    /// land mid-cycle has a mix of before/after values, so it skips swap
    /// tracking rather than risk reading the app's own swap as a
    /// front-panel one (the Mac's commandGeneration, same reason).
    private int _commandGeneration;
    /// "FR" (FUNCTION RX): false dual receive, true single, null not read
    /// yet. Read in the slow tier.
    private bool? _singleReceive;
    /// "ST" (SPLIT) and "FT" (which side transmits: false MAIN, true SUB),
    /// read in the slow tier; they pick the TXRX/RX tags and the TX button's
    /// caption (RigState.mainTxRxLabel/subTxRxLabel on the Mac).
    private bool? _splitOn;
    private bool? _txSideSub;
    private int _pollCount;
    /// C4FM caller/reflector lookup, started and stopped by
    /// UpdateWpsdMonitorState as settings and the rig's modes change.
    private readonly WpsdCallsignMonitor _wpsdMonitor = new();
    /// When the in-flight poll started, for the stuck-poll watchdog in
    /// PollOnceAsync; null when none is running.
    private DateTime? _pollStartedAt;
    private DateTime _lastStuckLog;
    /// Last logged (Main, Sub) poll result — the poll log line is
    /// written only when it changes, so a 500 ms poll doesn't flood app.log.
    private (long?, long?) _lastLoggedPoll;
    private bool _pollInFlight;

    /// Main's frequency/mode as last polled in plain VFO mode — frozen once
    /// Memory mode is entered, and put back after leaving it: "VM000" sent
    /// over CAT leaves Main parked on the memory channel's values, and the
    /// rig exposes no read of its parked VFO (the Mac's
    /// HubService.lastVFOState, which has the full story). Null until a
    /// VFO-mode poll completes; the exit is then a bare "VM000". Mode is
    /// null in C4FM (this app's RigMode has none), so only the frequency is
    /// restored then.
    private (long Hz, RigMode? Mode)? _lastVfoState;

    /// True from a press on the PTT button until its release (or capture
    /// loss). Every release sends PTT off, even when the press was blocked
    /// from keying — same as the Mac's DragGesture onEnded — so pressing
    /// and releasing also unkeys a TX started elsewhere.
    private bool _pttPointerDown;
    /// True while this app is keying the rig from a held PTT press. Shown as
    /// transmitting straight away, rather than waiting for the poll.
    private bool _pttHeld;
    private Brush? _pttIdleBackground;

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        Title = "FTX-1 Remote";
        InitVfoEntryFlyouts();
        SetInitialWidth();
        AppLog.Write($"app: started ({AppSettings.ConnectionMode} mode, audio swapped={AppSettings.AudioChannelsSwapped}, version {UpdateChecker.CurrentVersionText})");
        if (AppSettings.CheckForUpdatesAtLaunch && Content is FrameworkElement root)
        {
            void OnLoaded(object? s, RoutedEventArgs e)
            {
                root.Loaded -= OnLoaded;
                _ = CheckForUpdateAtLaunchAsync();
            }
            root.Loaded += OnLoaded;
        }

        _menuGrid = new MenuGrid(_lastState) { Client = null };
        _menuGrid.StatusMessage += message => StatusText.Text = message;
        _menuGrid.PowerLevelSent += level =>
        {
            // Same hold as the main slider's own sends, so a poll that read
            // the old level can't flick either control back.
            _powerHoldUntil = DateTime.UtcNow + PowerHoldAfterSend;
            _suppressPowerEvents = true;
            PowerSlider.Value = level * 100;
            _suppressPowerEvents = false;
        };
        _menuGrid.FrequencyRequested += async hz => await SetMainFrequencyAsync(hz);
        _menuGrid.AprsListRequested += ShowAprsList;
        _menuGrid.RecordingsRequested += ShowRecordings;
        _menuGrid.RecordToggleRequested += ToggleRecording;
        MenuGridHost.Child = _menuGrid;
        _filterPanel = new FilterPanel(_lastState);
        _filterPanel.StatusMessage += message => StatusText.Text = message;
        FilterPanelHost.Child = _filterPanel;
        ScopeHost.Child = _scope;
        _scopeProcessor = new ScopeProcessor(
            frame =>
            {
                _scopeFrames.Enqueue(frame);
                ScheduleScopeDrain();
            },
            spectrum =>
            {
                _latestSubSpectrum = spectrum;
                ScheduleScopeDrain();
            });
        SetScopeMode(AppSettings.ScopeDisplayMode);
        MainMeterHost.Child = _mainMeter;
        SubMeterHost.Child = _subMeter;

        _cwReceiver = new CwReceiver(DispatcherQueue, () => _webSdrWindow is { } webSdr
            ? new WebSdrState(webSdr.BrowserProcessId, webSdr.Model.IsConnected, webSdr.Model.IsMuted)
            : null);
        _cwSender = new CwSender(new CwRigLink
        {
            Client = () => _client,
            BlockReason = CwSendBlockReason,
            SpeedWpm = () => _lastState.CwSpeedWpm,
            Ptt = () => _lastState.Ptt,
        });
        _cwSender.ActiveChanged += _cwReceiver.SetSenderActive;
        WireAprsDecoder(_aprsMainDecoder, AprsSource.Main);
        WireAprsDecoder(_aprsSubDecoder, AprsSource.Sub);

        ApplyAppearance();
        ShowDisconnected();
        _wpsdMonitor.CallsignUpdated += callsign => DispatcherQueue.TryEnqueue(() =>
        {
            // A late reply after Stop() must not bring a caller back.
            if (!_wpsdActive)
            {
                return;
            }
            if (callsign != _lastState.C4fmCallsign)
            {
                AppLog.Write($"wpsd: caller {callsign ?? "none"}");
            }
            _lastState.C4fmCallsign = callsign;
            UpdateC4fmDisplay();
        });
        _wpsdMonitor.ReflectorUpdated += reflector => DispatcherQueue.TryEnqueue(() =>
        {
            if (!_wpsdActive)
            {
                return;
            }
            if (reflector != _lastState.C4fmReflector)
            {
                AppLog.Write($"wpsd: reflector {reflector ?? "none"}");
            }
            _lastState.C4fmReflector = reflector;
            UpdateC4fmDisplay();
        });
        _suppressSelectionEvents = true;
        foreach (RigMode mode in Enum.GetValues<RigMode>())
        {
            ModeComboBox.Items.Add(new ComboBoxItem { Content = mode.DisplayName(), Tag = mode });
        }
        foreach (var band in BandPlan.All)
        {
            BandComboBox.Items.Add(new ComboBoxItem { Content = band.Name, Tag = band });
        }
        _suppressSelectionEvents = false;

        // The slider's Thumb handles (and marks handled) its own pointer
        // events, hence handledEventsToo. Capture loss covers a release
        // outside the window.
        PowerSlider.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => _powerDragging = true), true);
        PowerSlider.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(PowerSlider_PointerDone), true);
        PowerSlider.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler(PowerSlider_PointerDone), true);

        _pollTimer = DispatcherQueue.CreateTimer();
        // Settings → Polling; 500 ms by default, the Mac's fast-tier
        // default, so the S-meters move live.
        _pollTimer.Interval = TimeSpan.FromMilliseconds(AppSettings.PollIntervalMs);
        _pollTimer.Tick += async (_, _) => await PollOnceAsync();

        // Mid-session only: during Connect, ConnectToFreshRigctldAsync
        // notices the exit itself and reports it through its own catch.
        _rigctldProcess.UnexpectedExit += message =>
            DispatcherQueue.TryEnqueue(async () =>
            {
                if (IsConnected)
                {
                    await DisconnectAsync(message);
                }
            });

        _swapTracker = new AudioChannelSwapTracker(AppSettings.AudioChannelsSwapped);
        _audioChannelsSwapped = _swapTracker.Swapped;
        AudioSwapToggle.IsChecked = _swapTracker.Swapped;
        UpdateAudioSwapTooltip();
        _swapTracker.Changed += reason =>
        {
            // A front-panel swap puts the other receiver on Main, so the
            // remembered VFO isn't Main's any more (see SwapVfoButton_Click),
            // and the selected filter side may now hold other values.
            if (reason.StartsWith("front-panel", StringComparison.Ordinal))
            {
                _lastVfoState = null;
                _filterPanel.RequestRefresh(TimeSpan.FromMilliseconds(400));
            }
            _audioChannelsSwapped = _swapTracker.Swapped;
            AppSettings.AudioChannelsSwapped = _swapTracker.Swapped;
            AudioSwapToggle.IsChecked = _swapTracker.Swapped;
            UpdateAudioSwapTooltip();
            AppLog.Write($"audio-routing: swapped={_swapTracker.Swapped} ({reason}) main {_lastState.FrequencyHz} sub {_lastState.SecondaryFrequencyHz}");
        };

        var mainAudio = AppSettings.MainAudio;
        var subAudio = AppSettings.SubAudio;
        // The WebSDR window always opens disconnected, so a Main mute it made
        // can only be left over from a session that ended without closing it
        // (a crash) — lift it, like the Mac's HubService.init.
        if (AppSettings.MainMutedByWebSdr)
        {
            AppSettings.MainMutedByWebSdr = false;
            mainAudio.Muted = false;
            AppSettings.SaveAudio();
        }
        _mainPlayer = new ChannelPlayer((float)mainAudio.Volume, (float)mainAudio.SquelchThreshold, mainAudio.Muted);
        _subPlayer = new ChannelPlayer((float)subAudio.Volume, (float)subAudio.SquelchThreshold, subAudio.Muted);
        _playback = new AudioPlayback(_mainPlayer, _subPlayer);

        _pttIdleBackground = PttButton.Background;
        TransmitEnabledSwitch.IsOn = AppSettings.TransmitEnabled;
        UpdateTransmitControls();

        _suppressAudioEvents = true;
        AudioSwitch.IsOn = AppSettings.AudioEnabled;
        MainMuteToggle.IsChecked = mainAudio.Muted;
        MainVolumeSlider.Value = mainAudio.Volume;
        MainSquelchSlider.Value = SquelchRange - mainAudio.SquelchThreshold;
        SubMuteToggle.IsChecked = subAudio.Muted;
        SubVolumeSlider.Value = subAudio.Volume;
        SubSquelchSlider.Value = SquelchRange - subAudio.SquelchThreshold;
        _suppressAudioEvents = false;

        _audioStatusTimer = DispatcherQueue.CreateTimer();
        _audioStatusTimer.Interval = TimeSpan.FromMilliseconds(250);
        _audioStatusTimer.Tick += (_, _) =>
        {
            RecheckBlockedPlayback();
            UpdateAudioStatus();
        };

        // Don't leave a rigctld we spawned running after the window closes
        // (an adopted one is left alone — see RigctldProcessController).
        Closed += (_, _) =>
        {
            _pollTimer.Stop();
            UnkeyBeforeDisconnect();
            _audioStatusTimer.Stop();
            _wpsdMonitor.Stop();
            _playback.Stop();
            _ = _audioSource?.StopAsync();
            _client?.Disconnect();
            _client = null;
            _rigctldProcess.Stop();
            _aprsMainDecoder.Dispose();
            _aprsSubDecoder.Dispose();
            foreach (var window in _aprsWindows.Values.ToList())
            {
                window.Close();
            }
            _webSdrWindow?.Close();
            _cwWindow?.Close();
            _recordingsWindow?.Close();
            _cwReceiver.Dispose();
            _audioRecorder.Stop();
        };
    }

    private bool IsConnected => _client is not null;

    /// The mode of the current session (set on a successful Connect) — the
    /// Settings rigctld tab is locked while connected, but this is what
    /// audio gating reads.
    private ConnectionMode _connectedMode;

    /// The connection bar while disconnected: which connection Connect
    /// will use, now that its settings live in the Settings dialog.
    private void ShowDisconnected()
    {
        ConnectionStateText.Text = AppSettings.ConnectionMode == ConnectionMode.Local
            ? $"Disconnected · Local, {(AppSettings.ComPort.Length > 0 ? AppSettings.ComPort : "no COM port set")} @ {AppSettings.BaudRate}"
            : $"Disconnected · Remote, {(AppSettings.PiHost.Length > 0 ? AppSettings.PiHost : "no Pi host set")}";
        ConnectionStateText.Foreground = new SolidColorBrush(Colors.Gray);
    }

    /// The launch-time update check: silent unless a newer release exists
    /// (a failed check is only logged). Offers the release page; "Later"
    /// just dismisses it until the next launch.
    private async Task CheckForUpdateAtLaunchAsync()
    {
        try
        {
            var update = await UpdateChecker.CheckAsync();
            if (update is null)
            {
                return;
            }
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                RequestedTheme = (Content as FrameworkElement)?.RequestedTheme ?? ElementTheme.Default,
                Title = "Update available",
                Content = $"FTX1Remote {UpdateChecker.Display(update.Version)} is available (you have {UpdateChecker.CurrentVersionText}).",
                PrimaryButtonText = "Download",
                CloseButtonText = "Later",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await Windows.System.Launcher.LaunchUriAsync(new Uri(update.PageUrl));
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"update check failed: {ex.Message}");
        }
    }

    private async void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsDialog(this, IsConnected);
        SettingsButton.IsEnabled = false;
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
        }
        finally
        {
            SettingsButton.IsEnabled = true;
        }
        await ApplySettingsAsync(dialog);
    }

    /// Applies what Save changed. The connection settings apply on the
    /// next Connect (the dialog locks them while connected); everything
    /// else takes effect now.
    private async Task ApplySettingsAsync(SettingsDialog dialog)
    {
        AppLog.Write($"settings: saved ({AppSettings.ConnectionMode} mode, poll {AppSettings.PollIntervalMs} ms, slow tier every {AppSettings.SlowPollEvery})");
        if (!IsConnected)
        {
            ShowDisconnected();
        }
        ApplyAppearance();
        _pollTimer.Interval = TimeSpan.FromMilliseconds(AppSettings.PollIntervalMs);

        if (dialog.WpsdHostChanged)
        {
            // A different hotspot: don't keep showing the old one's caller.
            _lastState.C4fmCallsign = null;
            _lastState.C4fmReflector = null;
        }
        if (dialog.AprsClearHistory)
        {
            AppLog.Write("aprs-store: history cleared");
            _aprsStore.ClearHistory();
        }
        _aprsStore.ApplyLimits();

        // Restarted so new lookup intervals don't wait out an old delay.
        _wpsdMonitor.Stop();
        UpdateWpsdMonitorState();

        if (dialog.AudioInputChanged && IsConnected && _connectedMode == ConnectionMode.Local && AudioSwitch.IsOn)
        {
            await StopAudioAsync();
            StartAudio();
        }
        else if (dialog.AudioOutputChanged)
        {
            // Only playback restarts; the audio source keeps running.
            StartPlayback();
            UpdateAudioStatus();
        }
    }

    /// Settings → Appearance: the theme (on the window's root, so every
    /// control follows) and the MENU grid's value color.
    private void ApplyAppearance()
    {
        RootScrollViewer.RequestedTheme = AppSettings.Theme.ElementTheme();
        _menuGrid.ValueColor = AppSettings.ButtonValueColor.Color();
        foreach (var window in _aprsWindows.Values)
        {
            window.ApplyTheme();
        }
        _webSdrWindow?.ApplyTheme();
        _cwWindow?.ApplyTheme();
        _recordingsWindow?.ApplyTheme();
    }

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        if (IsConnected)
        {
            await DisconnectAsync(null);
            return;
        }

        var mode = AppSettings.ConnectionMode;
        string host;
        string description;
        if (mode == ConnectionMode.Remote)
        {
            host = AppSettings.PiHost;
            if (host.Length == 0)
            {
                StatusText.Text = "Set the Pi's Tailscale hostname in Settings first.";
                return;
            }
            description = $"{host}:{RigctldPort}";
        }
        else
        {
            host = LocalHost;
            if (AppSettings.RigctldPath.Length == 0 || AppSettings.ComPort.Length == 0)
            {
                StatusText.Text = "Set rigctld.exe and the COM port in Settings first.";
                return;
            }
            description = $"{AppSettings.ComPort} @ {AppSettings.BaudRate} via local rigctld";
        }

        ConnectButton.IsEnabled = false;
        ConnectionStateText.Text = mode == ConnectionMode.Local ? "Starting rigctld…" : "Connecting…";
        ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Orange);
        StatusText.Text = "";

        var client = new RigctldClient(host, RigctldPort);
        try
        {
            if (mode == ConnectionMode.Local)
            {
                var started = await _rigctldProcess.StartAsync(new RigctldProcessController.Configuration(
                    AppSettings.RigctldPath,
                    AppSettings.ModelNumber,
                    AppSettings.ComPort,
                    AppSettings.BaudRate,
                    LocalHost,
                    RigctldPort));
                if (started == RigctldProcessController.StartResult.Adopted)
                {
                    // Its COM port/baud rate are whatever it was started
                    // with — rigctld can't report them, so don't claim ours.
                    description = $"already-running rigctld on localhost:{RigctldPort}";
                    await client.ConnectAsync();
                }
                else
                {
                    ConnectionStateText.Text = "Connecting…";
                    await ConnectToFreshRigctldAsync(client);
                }
            }
            else
            {
                // TODO (Apps/Windows/README.md "Reconnect / connection-state
                // UI"): distinguish a TCP-connect failure (Pi/Tailscale
                // unreachable) from a connected-but-bad-CAT-reply failure here
                // once that split is designed — right now both surface as the
                // same generic RigctldError.
                await client.ConnectAsync();
            }
            _client = client;
            _menuGrid.ClearState();
            _menuGrid.Client = client;
            _filterPanel.ClearState();
            _filterPanel.Client = client;
            ClearMemoryState();
            ClearC4fmState();
            // Run the slow tier (FR, MENU grid) on the first poll.
            _pollCount = 0;
            ConnectionStateText.Text = $"Connected to {description}";
            AppLog.Write($"connection: connected to {description} ({mode}); audio swapped={_swapTracker.Swapped}");
            _cwSender.OnConnected();
            ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green);
            _scope.SetActive(true);
            ConnectButton.Content = "Disconnect";
            _connectedMode = mode;
            _connectedHost = host;
            _pollTimer.Start();
            if (AudioSwitch.IsOn)
            {
                StartAudio();
            }
            else
            {
                UpdateAudioStatus();
            }
            await PollOnceAsync();
        }
        catch (Exception ex)
        {
            await client.DisposeAsync();
            _rigctldProcess.Stop();
            ShowDisconnected();
            StatusText.Text = $"Connect failed: {ex.Message}";
            AppLog.Write($"connection: connect failed: {ex.Message}");
        }
        finally
        {
            ConnectButton.IsEnabled = true;
        }
    }

    /// A just-spawned rigctld takes a moment to open the COM port and bind
    /// its listener, so the first connects race it — retry quietly for
    /// LocalStartupGracePeriod (same idea as the Mac's isFreshStart), but
    /// give up at once if rigctld has already exited, with hamlib's own
    /// stderr as the reason. Also requires one good frequency read: hamlib
    /// 4.x's rigctld keeps listening even when it couldn't open the rig
    /// (wrong COM port or baud rate, radio off), and every command then
    /// fails — without this check that would show as "Connected" with
    /// nothing ever updating.
    private async Task ConnectToFreshRigctldAsync(RigctldClient client)
    {
        var deadline = DateTime.UtcNow + LocalStartupGracePeriod;
        var connected = false;
        // Separate from `connected`, which a timed-out read resets to force
        // a fresh socket: with the radio off every read times out, and the
        // final message must still say rigctld was reached.
        var reachedRigctld = false;
        Exception? lastError = null;
        while (DateTime.UtcNow < deadline)
        {
            if (!_rigctldProcess.IsOwnedProcessRunning)
            {
                throw new RigctldError(WithStderr("rigctld exited during startup"));
            }
            try
            {
                if (!connected)
                {
                    await client.ConnectAsync(TimeSpan.FromSeconds(1));
                    connected = true;
                    reachedRigctld = true;
                }
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                _ = await client.GetFrequencyAsync(cts.Token);
                return;
            }
            catch (Exception ex) when (ex is RigctldError or OperationCanceledException or IOException)
            {
                lastError = ex;
                if (ex is not RigctldError)
                {
                    // A timed-out or broken read can leave a half-read
                    // reply behind — start the next try on a fresh socket.
                    client.Disconnect();
                    connected = false;
                }
                await Task.Delay(LocalStartupRetryInterval);
            }
        }
        throw new RigctldError(WithStderr(reachedRigctld
            ? "rigctld is running but the radio isn't answering — check the COM port, baud rate, and that the radio is on"
            : $"couldn't reach rigctld on localhost:{RigctldPort} ({lastError?.Message})"));
    }

    private string WithStderr(string message)
    {
        var tail = _rigctldProcess.StderrTail();
        return tail.Length > 0 ? $"{message}. rigctld said: {tail}" : message;
    }

    /// Tears down the connection (and a rigctld this app spawned). A
    /// non-null reason is shown as the status line — used when rigctld
    /// exits underneath a session.
    private async Task DisconnectAsync(string? reason)
    {
        AppLog.Write($"connection: disconnecting{(reason is null ? "" : $" — {reason}")}");
        _pollTimer.Stop();
        UnkeyBeforeDisconnect();
        await StopAudioAsync();
        var client = _client;
        _client = null;
        _menuGrid.Client = null;
        _filterPanel.Client = null;
        _scope.SetActive(false);
        _mainMeter.Reset();
        _subMeter.Reset();
        ClearMemoryState();
        Volatile.Write(ref _aprsMainGateHz, 0);
        Volatile.Write(ref _aprsSubGateHz, 0);
        ClearC4fmState();
        PushRigStateToWebSdr();
        PushRigStateToCw();
        if (client is not null)
        {
            await client.DisposeAsync();
        }
        _rigctldProcess.Stop();
        ShowDisconnected();
        ConnectButton.Content = "Connect";
        if (reason is not null)
        {
            StatusText.Text = reason;
        }
    }

    /// Polls each field independently, falling back to the last-known
    /// value on any individual failure rather than tearing down the whole
    /// connection. This is not incidental caution — see
    /// Apps/Windows/README.md's porting table entry for "Poll loop": the
    /// Mac app shipped exactly this bug (one unwrapped read in the poll
    /// cycle causing reconnect storms over the Tailscale hop) and only
    /// caught it during real-hardware validation on 2026-09-07.
    private async Task PollOnceAsync()
    {
        if (_client is not { } client)
        {
            return;
        }
        if (_pollInFlight)
        {
            // Watchdog: a poll that never finishes blocks every later poll
            // and every command (they share the client's round-trip lock),
            // so say where it's stuck, every 5 s while it lasts.
            if (_pollStartedAt is { } started && DateTime.UtcNow - started > TimeSpan.FromSeconds(5)
                && DateTime.UtcNow - _lastStuckLog > TimeSpan.FromSeconds(5))
            {
                _lastStuckLog = DateTime.UtcNow;
                AppLog.Write($"poll: stuck for {(DateTime.UtcNow - started).TotalSeconds:F0} s; last rigctld command '{client.LastCommand}' sent {(DateTime.UtcNow - client.LastCommandAt).TotalSeconds:F1} s ago");
            }
            return;
        }
        // Over Tailscale a poll can outlast the 500 ms tick; overlapping polls
        // would interleave their reads and confuse swap tracking.
        _pollInFlight = true;
        _pollStartedAt = DateTime.UtcNow;
        try
        {
            await PollFieldsAsync(client);
        }
        finally
        {
            var took = DateTime.UtcNow - _pollStartedAt.Value;
            if (took > TimeSpan.FromSeconds(2))
            {
                AppLog.Write($"poll: took {took.TotalSeconds:F1} s");
            }
            _pollInFlight = false;
            _pollStartedAt = null;
        }
    }

    private async Task PollFieldsAsync(RigctldClient client)
    {
        var generationAtStart = _commandGeneration;
        long? polledMain = null;
        long? polledSub = null;

        try
        {
            var hz = await client.GetFrequencyAsync();
            polledMain = hz;
            _lastState.FrequencyHz = hz;
            Volatile.Write(ref _aprsMainGateHz, hz);
            FrequencyAText.Text = FormatHz(hz);
            var band = BandPlan.BandContaining(hz);
            SetComboSelection(BandComboBox, band?.Name);
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: getFrequency failed: {ex.Message}");
        }

        try
        {
            var hz = await client.GetSecondaryFrequencyAsync();
            polledSub = hz;
            _lastState.SecondaryFrequencyHz = hz;
            Volatile.Write(ref _aprsSubGateHz, hz);
            FrequencyBText.Text = FormatHz(hz);
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: getSecondaryFrequency failed: {ex.Message}");
        }

        // Fast tier, like the Mac's refreshFastTier, so _lastVfoState never
        // pairs a frequency with a stale VFO/Memory reading.
        var mainMemory = await ReadMemoryStateAsync(client, sub: false);
        var subMemory = await ReadMemoryStateAsync(client, sub: true);

        var slowTier = _pollCount++ % AppSettings.SlowPollEvery == 0;
        if (slowTier)
        {
            try
            {
                if (await client.GetRawIntAsync("FR") is { } fr)
                {
                    var single = fr == 1;
                    if (single != _singleReceive)
                    {
                        AppLog.Write($"audio-routing: FR reply {fr} — {(single ? "single" : "dual")} receive");
                    }
                    _singleReceive = single;
                    _filterPanel.SingleReceive = single;
                    // The Mac's VFODisplayBox: SUB's border goes gray while it isn't shown.
                    SubVfoBox.BorderBrush = new SolidColorBrush(single ? Windows.UI.Color.FromArgb(102, 128, 128, 128) : Windows.UI.Color.FromArgb(179, 0, 255, 0));
                }
            }
            catch (Exception ex)
            {
                AppLog.Write($"poll: FR failed: {ex.Message}");
            }

            try
            {
                if (await client.GetRawBoolAsync("ST") is { } split)
                {
                    _splitOn = split;
                }
                if (await client.GetRawDigitAsync("FT") is { } ft)
                {
                    _txSideSub = ft == 1;
                }
                UpdateTxRxIndicators();
            }
            catch (Exception ex)
            {
                AppLog.Write($"poll: ST/FT failed: {ex.Message}");
            }

            // Slow tier: modes rarely change, and a C4FM switch only has to
            // start the WPSD lookup and skip the MENU grid's GT0/PR1 (which
            // go unanswered in C4FM). Main's fast-tier mode read also clears
            // MainIsC4fm as soon as it reads a mode this app knows.
            _lastState.MainIsC4fm = await ReadC4fmAsync(client, sub: false) ?? _lastState.MainIsC4fm;
            // Sub's whole mode, not just C4FM: the filter controls need it
            // while SUB is selected (hamlib's "m" only reads the active side).
            if (await ReadModeCodeAsync(client, sub: true) is { } subCode)
            {
                _lastState.SubIsC4fm = subCode is 'H' or 'I';
                _lastState.SubMode = RigModeExtensions.FromCatModeCode(subCode) ?? _lastState.SubMode;
            }
            if (_lastState.MainIsC4fm == true && _lastState.Mode is not null)
            {
                // hamlib's mode read fails in C4FM, which left the last
                // analog mode showing.
                _lastState.Mode = null;
                _suppressSelectionEvents = true;
                ModeComboBox.SelectedItem = null;
                _suppressSelectionEvents = false;
            }
        }

        var generationChanged = generationAtStart != _commandGeneration;
        if ((polledMain, polledSub) != _lastLoggedPoll)
        {
            _lastLoggedPoll = (polledMain, polledSub);
            AppLog.Write($"poll: main={polledMain?.ToString() ?? "failed"} sub={polledSub?.ToString() ?? "failed"}{(generationChanged ? " (command mid-poll, swap tracking skipped)" : "")} swapped={_swapTracker.Swapped}");
        }

        if (polledMain is { } main && !generationChanged)
        {
            _swapTracker.OnPoll(main, polledSub);
        }

        // A V/M or channel command that landed mid-poll already set these
        // optimistically; this poll's reads may predate it.
        if (!generationChanged)
        {
            ApplyMemoryState(mainMemory, subMemory);
        }

        try
        {
            var mode = await client.GetModeAsync();
            _lastState.Mode = mode;
            SetComboSelection(ModeComboBox, mode?.DisplayName());
            if (mode is not null)
            {
                _lastState.MainIsC4fm = false;
            }
            UpdateModeTags();
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: getMode failed: {ex.Message}");
        }

        // Only from a genuine VFO-mode snapshot — in Memory mode Main's
        // frequency/mode are the channel's, not the VFO's.
        if (_lastState.InVfoMode && polledMain is { } vfoHz && generationAtStart == _commandGeneration)
        {
            _lastVfoState = (vfoHz, _lastState.Mode);
        }

        try
        {
            var ptt = await client.GetPttAsync();
            _lastState.Ptt = ptt;
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: getPtt failed: {ex.Message}");
        }

        try
        {
            var level = await client.GetLevelAsync("RFPOWER");
            // Held like the slider, so the MENU grid's RF POWER label
            // doesn't flick back to a level read just before a send landed.
            if (level is { } shown && !_powerDragging && DateTime.UtcNow >= _powerHoldUntil)
            {
                _lastState.PowerLevel = shown;
                _suppressPowerEvents = true;
                PowerSlider.Value = shown * 100;
                _suppressPowerEvents = false;
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: getLevel(RFPOWER) failed: {ex.Message}");
        }

        // The meters use only this poll's readings (null on failure, so the
        // needle rests); the text fields keep their last value.
        double? polledWatts = null;
        double? polledSwr = null;
        try
        {
            var watts = await client.GetLevelAsync("RFPOWER_METER_WATTS");
            polledWatts = watts;
            if (watts is { } w)
            {
                _lastState.PowerWatts = w;
                PowerWattsText.Text = $"{w:F1} W";
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: getLevel(RFPOWER_METER_WATTS) failed: {ex.Message}");
        }

        try
        {
            var swr = await client.GetLevelAsync("SWR");
            polledSwr = swr;
            if (swr is { } s)
            {
                _lastState.Swr = s;
                SwrText.Text = $"{s:F2}";
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: getLevel(SWR) failed: {ex.Message}");
        }

        await PollMetersAsync(client, polledWatts, polledSwr);

        // Last, so its C4FM check sees this poll's mode. Each read is
        // best-effort inside.
        if (slowTier)
        {
            await _menuGrid.RefreshFromRigAsync(client);
            await _filterPanel.RefreshFromRigAsync(client);
            // The CW window's speed/BK-IN/pitch, unless the CW page has
            // just read them.
            if (_cwWindow is not null)
            {
                await _menuGrid.RefreshKeyerAsync(client);
            }
        }
        // Main's mode may have changed (fast tier), which changes which
        // filter controls apply.
        _filterPanel.RefreshUI();

        UpdateWpsdMonitorState();

        // Also refreshes the MENU grid (RF POWER, and the MOX/ANT TUNE gate
        // follows the new frequency).
        UpdateTransmitControls();

        PushRigStateToWebSdr();
    }

    private static async Task<bool?> ReadC4fmAsync(RigctldClient client, bool sub)
    {
        try
        {
            return await client.IsC4fmAsync(sub);
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: {(sub ? "MD1" : "MD0")} failed: {ex.Message}");
            return null;
        }
    }

    private static async Task<char?> ReadModeCodeAsync(RigctldClient client, bool sub)
    {
        try
        {
            return await client.GetModeCodeAsync(sub);
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: {(sub ? "MD1" : "MD0")} failed: {ex.Message}");
            return null;
        }
    }

    /// True while the WPSD lookup is meant to be running; its updates are
    /// dropped otherwise, so a reply already in flight when it stopped
    /// can't bring a caller back.
    private bool _wpsdActive;

    /// Starts/stops the WPSD lookup to match the settings and the rig — on
    /// every poll, like the Mac's updateWPSDMonitorState, so the checkbox,
    /// host and a mode change all take effect without reconnecting. Runs
    /// while either side is in C4FM: there's one hotspot, whichever VFO
    /// happens to be listening to it. Start/Stop are no-ops when already
    /// in that state.
    private void UpdateWpsdMonitorState()
    {
        var host = AppSettings.WpsdHost;
        if (IsConnected && AppSettings.WpsdEnabled && host.Length > 0
            && (_lastState.MainIsC4fm == true || _lastState.SubIsC4fm == true))
        {
            _wpsdActive = true;
            _wpsdMonitor.Start(host);
        }
        else
        {
            _wpsdActive = false;
            _wpsdMonitor.Stop();
            _lastState.C4fmCallsign = null;
            _lastState.C4fmReflector = null;
        }
        UpdateC4fmDisplay();
    }

    /// A new session starts from unread, like ClearMemoryState.
    private void ClearC4fmState()
    {
        _lastState.MainIsC4fm = null;
        _lastState.SubIsC4fm = null;
        UpdateWpsdMonitorState();
    }

    /// The callsign line under each frequency, like the Mac's VFODisplayBox
    /// call sites: in C4FM the WPSD caller and reflector; otherwise, while
    /// that VFO is on the APRS frequency, "APRS" in the reflector's slot and
    /// the last station decoded on that receiver for 5 s. Re-run every poll,
    /// which is what lets the APRS callsign expire.
    private void UpdateC4fmDisplay()
    {
        UpdateModeTags();
        ShowCallsignLine(C4fmCallsignAText, C4fmReflectorAText, _lastState.MainIsC4fm == true,
            AppSettings.IsAprsActive(IsConnected ? _lastState.FrequencyHz : null), _aprsMainLastHeard);
        ShowCallsignLine(C4fmCallsignBText, C4fmReflectorBText, _lastState.SubIsC4fm == true,
            AppSettings.IsAprsActive(IsConnected ? _lastState.SecondaryFrequencyHz : null), _aprsSubLastHeard);
    }

    private void ShowCallsignLine(TextBlock callsign, TextBlock reflector, bool c4fm, bool aprsActive,
        (string Callsign, DateTime At)? aprsLastHeard)
    {
        if (c4fm)
        {
            callsign.Text = _lastState.C4fmCallsign ?? "";
            reflector.Text = _lastState.C4fmReflector ?? "";
        }
        else if (aprsActive)
        {
            callsign.Text = aprsLastHeard is { } heard && DateTime.UtcNow - heard.At < AprsCallsignShownFor ? heard.Callsign : "";
            reflector.Text = "APRS";
        }
        else
        {
            callsign.Text = "";
            reflector.Text = "";
        }
    }

    /// S-meter reads, same as the Mac's refreshFastTier: Main from hamlib's
    /// STRENGTH, Sub from raw "RM2" (STRENGTH only reads the active side),
    /// and COMP/ALC/ID/VDD from raw "RM" only while transmitting — four
    /// extra round trips aren't worth paying in RX. Nothing is carried
    /// forward on failure: a live meter should fall to rest, not freeze.
    private async Task PollMetersAsync(RigctldClient client, double? powerWatts, double? swr)
    {
        async Task<T?> Try<T>(string what, Func<Task<T?>> read) where T : struct
        {
            try
            {
                return await read();
            }
            catch (Exception ex)
            {
                AppLog.Write($"poll: {what} failed: {ex.Message}");
                return null;
            }
        }

        _lastState.SmeterDb = await Try("getLevel(STRENGTH)", () => client.GetLevelAsync("STRENGTH"));
        var subRaw = await Try("RM2", () => client.GetMeterReadingAsync(2));
        _lastState.SubSmeterDb = subRaw is { } raw ? SMeterScale.StrengthDb(raw) : null;
        _lastState.TxMeters = _lastState.Ptt
            ? new TxMeterReadings(
                Comp: await Try("RM3", () => client.GetMeterReadingAsync(3)),
                Alc: await Try("RM4", () => client.GetMeterReadingAsync(4)),
                Idd: await Try("RM7", () => client.GetMeterReadingAsync(7)),
                Vdd: await Try("RM8", () => client.GetMeterReadingAsync(8)))
            : null;

        var readings = new MeterReadings(powerWatts, swr, _lastState.TxMeters);
        _mainMeter.Update(_lastState.SmeterDb, readings, _lastState.Ptt);
        _subMeter.Update(_lastState.SubSmeterDb, readings, _lastState.Ptt);
    }

    private void SetComboSelection(ComboBox box, string? tagText)
    {
        if (tagText is null)
        {
            return;
        }
        _suppressSelectionEvents = true;
        foreach (var item in box.Items.OfType<ComboBoxItem>())
        {
            if (Equals(item.Content, tagText) || (item.Tag is Band b && b.Name == tagText))
            {
                box.SelectedItem = item;
                break;
            }
        }
        _suppressSelectionEvents = false;
    }

    /// The rig's own grouping, in MHz: 14.074.000 (MHz.kHz.Hz); no unit label.
    private static string FormatHz(long hz) =>
        $"{hz / 1_000_000}.{hz / 1_000 % 1_000:000}.{hz % 1_000:000}";

    /// Tunes the Main VFO: the VFO entry flyout and the MENU grid's HOME. An app
    /// tune resets swap tracking's baseline, so it isn't mistaken for a
    /// front-panel swap.
    private async Task SetMainFrequencyAsync(long hz)
    {
        if (_client is not { } client)
        {
            return;
        }
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        try
        {
            await client.SetFrequencyAsync(hz);
            StatusText.Text = "";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set frequency failed: {ex.Message}";
        }
    }

    private async void SwapVfoButton_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        _commandGeneration++;
        // The remembered VFO belonged to the receiver that's now Sub:
        // restoring it after V/M would put the other receiver's frequency
        // and mode on Main. Re-learned at the next VFO-mode poll; until
        // then leaving Memory is a bare "VM000".
        _lastVfoState = null;
        AppLog.Write($"swap: ⇄ clicked (main {_lastState.FrequencyHz}, sub {_lastState.SecondaryFrequencyHz}, single receive {_singleReceive?.ToString() ?? "unknown"}, poll in flight {_pollInFlight})");
        try
        {
            await _client.SwapActiveVfoAsync();
            AppLog.Write("swap: SV sent");
            _swapTracker.OnAppSwap(_singleReceive, _lastState.FrequencyHz, _lastState.SecondaryFrequencyHz);
            if (_singleReceive == true)
            {
                AppLog.Write($"audio-routing: app swap in single-receive display — audio channels left as is (swapped={_swapTracker.Swapped})");
            }
            // Show the swap now rather than on the next poll.
            if (_lastState.SecondaryFrequencyHz is { } sub)
            {
                (_lastState.FrequencyHz, _lastState.SecondaryFrequencyHz) = (sub, _lastState.FrequencyHz);
                FrequencyAText.Text = FormatHz(_lastState.FrequencyHz);
                FrequencyBText.Text = FormatHz(_lastState.SecondaryFrequencyHz.Value);
            }
            // The modes swap too, so the filter controls match their
            // receivers until the polls confirm; then re-read the selected
            // side's filter, which now holds the other VFO's settings or not.
            if (_lastState.SubMode is { } subMode)
            {
                (_lastState.Mode, _lastState.SubMode) = (subMode, _lastState.Mode);
            }
            (_lastState.MainIsC4fm, _lastState.SubIsC4fm) = (_lastState.SubIsC4fm, _lastState.MainIsC4fm);
            UpdateModeTags();
            _filterPanel.RefreshUI();
            _filterPanel.RequestRefresh(TimeSpan.FromMilliseconds(400));
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Swap VFO failed: {ex.Message}";
            AppLog.Write($"swap: SV failed: {ex.Message}");
        }
    }

    /// Each box's mode, upper right: C4FM when that side is in it, else the
    /// mode's display name (blank until read).
    private void UpdateModeTags()
    {
        MainModeText.Text = _lastState.MainIsC4fm == true ? "C4FM" : _lastState.Mode?.DisplayName() ?? "";
        SubModeText.Text = _lastState.SubIsC4fm == true ? "C4FM" : _lastState.SubMode?.DisplayName() ?? "";
    }

    /// The Mac's RigState.mainTxRxLabel/subTxRxLabel: TXRX (red) on the TX
    /// side, RX (green) on the other; with split on, MAIN shows RX.
    private void UpdateTxRxIndicators()
    {
        var sub = _txSideSub == true;
        var split = _splitOn == true;
        SetTxRxTag(MainTxRxTag, MainTxRxText, !(split || sub));
        SetTxRxTag(SubTxRxTag, SubTxRxText, !split && sub);
        TxSideButton.Content = sub ? "TX:SUB" : "TX:MAIN";
    }

    private static void SetTxRxTag(Border tag, TextBlock text, bool txrx)
    {
        text.Text = txrx ? "TXRX" : "RX";
        tag.Background = new SolidColorBrush(txrx ? Microsoft.UI.Colors.Red : Microsoft.UI.Colors.Green);
    }

    private async void TxSideButton_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        var toSub = _txSideSub != true;
        try
        {
            await _client.SetRawIntAsync("FT", toSub ? 1 : 0, 1);
            _txSideSub = toSub;
            UpdateTxRxIndicators();
            AppLog.Write($"tx side: FT{(toSub ? 1 : 0)} sent");
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set TX side failed: {ex.Message}";
        }
    }

    private void AudioSwapToggle_Click(object sender, RoutedEventArgs e)
    {
        AppLog.Write("audio-routing: speaker override clicked");
        _swapTracker.Toggle();
        AudioSwapToggle.IsChecked = _swapTracker.Swapped;
    }

    private void UpdateAudioSwapTooltip()
    {
        ToolTipService.SetToolTip(AudioSwapToggle, _swapTracker.Swapped
            ? "Audio channels are swapped relative to the rig's default (L=Main, R=Sub). Click to swap back."
            : "Swap which audio channel plays as Main and Sub — use if the audio doesn't match the VFO it's under.");
    }

    // V/M memory mode (parity plan step 5)

    /// One side's VFO/Memory reading: "VM", then "MC" and "MT" only while
    /// in plain Memory mode (two extra round trips only when they mean
    /// something, as on the Mac). Null when "VM" itself failed, so the
    /// last known state is kept rather than blanked by one bad reply.
    private static async Task<(int Raw, int? Channel, string? Tag)?> ReadMemoryStateAsync(RigctldClient client, bool sub)
    {
        var p1 = sub ? 1 : 0;
        int raw;
        try
        {
            if (await client.GetVfoMemoryModeAsync(sub) is not { } value)
            {
                return null;
            }
            raw = value;
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: VM{p1} failed: {ex.Message}");
            return null;
        }
        if (raw != 11)
        {
            return (raw, null, null);
        }
        int? channel = null;
        string? tag = null;
        try
        {
            channel = await client.GetMemoryChannelAsync(sub);
            if (channel is { } c)
            {
                tag = await client.GetMemoryChannelTagAsync(c);
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"poll: MC{p1}/MT failed: {ex.Message}");
        }
        return (raw, channel, tag);
    }

    private void ApplyMemoryState((int Raw, int? Channel, string? Tag)? main, (int Raw, int? Channel, string? Tag)? sub)
    {
        if (main is { } m)
        {
            if (m.Raw != _lastState.VfoMemoryRaw)
            {
                AppLog.Write($"memory: VM0 {_lastState.VfoMemoryRaw?.ToString() ?? "unread"} -> {m.Raw}");
            }
            _lastState.VfoMemoryRaw = m.Raw;
            _lastState.MemoryChannel = m.Channel;
            _lastState.MemoryChannelTag = m.Tag;
        }
        if (sub is { } s)
        {
            _lastState.SubVfoMemoryRaw = s.Raw;
            _lastState.SubMemoryChannel = s.Channel;
            _lastState.SubMemoryChannelTag = s.Tag;
        }
        UpdateMemoryDisplay();
    }

    /// A new session starts from unread: the rig may have been changed
    /// from its front panel (or by another app) in between.
    private void ClearMemoryState()
    {
        _lastState.VfoMemoryRaw = null;
        _lastState.MemoryChannel = null;
        _lastState.MemoryChannelTag = null;
        _lastState.SubVfoMemoryRaw = null;
        _lastState.SubMemoryChannel = null;
        _lastState.SubMemoryChannelTag = null;
        _lastVfoState = null;
        UpdateMemoryDisplay();
    }

    private void UpdateMemoryDisplay()
    {
        ShowMemoryLabel(MemoryChannelAText, _lastState.VfoMemoryRaw, _lastState.MemoryChannel, _lastState.MemoryChannelTag);
        ShowMemoryLabel(MemoryChannelBText, _lastState.SubVfoMemoryRaw, _lastState.SubMemoryChannel, _lastState.SubMemoryChannelTag);
        VfoMemoryToggle.IsChecked = _lastState.VfoMemoryRaw is { } raw && raw != 0;
    }

    /// "CH n TAG" in Memory mode (the Mac's VFODisplayBox label), "VM nn"
    /// in the rig's other sub-modes, which the Mac doesn't label — shown
    /// here so a checked V/M button with no channel isn't a mystery.
    private static void ShowMemoryLabel(TextBlock label, int? raw, int? channel, string? tag)
    {
        string? text = raw switch
        {
            null or 0 => null,
            11 => channel is { } c ? (tag is null ? $"CH {c}" : $"CH {c} {tag}") : "MEM",
            { } other => $"VM {other:00}",
        };
        label.Text = text ?? "";
        label.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }

    /// Explicit set, not a blind toggle: reads the current mode and sends
    /// the opposite (the project's rule since the "PR"/MIC EQ backwards-
    /// toggle bug). Compared against plain VFO, not Memory — see
    /// RigState.InVfoMode — so any sub-mode exits to VFO.
    private async void VfoMemoryToggle_Click(object sender, RoutedEventArgs e)
    {
        if (_client is not { } client)
        {
            UpdateMemoryDisplay();
            return;
        }
        var enterMemory = _lastState.InVfoMode;
        var restore = enterMemory ? null : _lastVfoState;
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        AppLog.Write($"memory: V/M clicked (VM0 {_lastState.VfoMemoryRaw?.ToString() ?? "unread"}) — {(enterMemory ? "entering Memory" : $"leaving to VFO, restoring {restore?.Hz.ToString() ?? "nothing"} {restore?.Mode?.DisplayName() ?? ""}")}");

        _lastState.VfoMemoryRaw = enterMemory ? 11 : 0;
        _lastState.MemoryChannel = null;
        _lastState.MemoryChannelTag = null;
        UpdateMemoryDisplay();
        try
        {
            await client.SetVfoMemoryModeAsync(enterMemory);
            // In this order: the rig rejects "FA" while still in Memory
            // mode, and the client serializes commands.
            if (restore is { } last)
            {
                await client.SetFrequencyAsync(last.Hz);
                if (last.Mode is { } mode)
                {
                    await client.SetModeAsync(mode);
                }
                _lastState.FrequencyHz = last.Hz;
                FrequencyAText.Text = FormatHz(last.Hz);
            }
            StatusText.Text = "";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"V/M failed: {ex.Message}";
            AppLog.Write($"memory: V/M failed: {ex.Message}");
        }
    }

    /// The VFO boxes' click-to-enter flyouts (Controls/VfoEntryFlyout.cs),
    /// the Mac's VFODisplayBox popovers. Frequency entry is offered only in
    /// plain VFO mode (the rig rejects "FA" elsewhere); Memory mode gets the
    /// channel entry instead; the rig's other sub-modes get neither.
    private void InitVfoEntryFlyouts()
    {
        _ = new VfoEntryFlyout(FrequencyAText,
            () => EntryState(_lastState.VfoMemoryRaw, _lastState.FrequencyHz, _lastState.MemoryChannel),
            SetMainFrequencyAsync,
            channel => SetMemoryChannelAsync(sub: false, channel),
            up => StepMemoryChannelAsync(sub: false, up),
            message => StatusText.Text = message);
        _ = new VfoEntryFlyout(FrequencyBText,
            () => EntryState(_lastState.SubVfoMemoryRaw, _lastState.SecondaryFrequencyHz, _lastState.SubMemoryChannel),
            SetSubFrequencyAsync,
            channel => SetMemoryChannelAsync(sub: true, channel),
            up => StepMemoryChannelAsync(sub: true, up),
            message => StatusText.Text = message);
    }

    private VfoEntryState EntryState(int? memoryRaw, long? hz, int? channel)
    {
        var memory = memoryRaw == 11;
        var canEdit = IsConnected && hz is not null && (memoryRaw is null or 0 || memory);
        return new VfoEntryState(canEdit, memory, hz ?? 0, channel);
    }

    private async Task SetSubFrequencyAsync(long hz)
    {
        if (_client is not { } client)
        {
            return;
        }
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        await client.SetSecondaryFrequencyAsync(hz);
        StatusText.Text = "";
    }

    /// No optimistic channel number: the rig ignores a set to a blank
    /// channel, so the next poll's read-back is the only true value
    /// (the Mac dropped its optimistic value for the same reason).
    private async Task SetMemoryChannelAsync(bool sub, int channel)
    {
        if (_client is not { } client)
        {
            return;
        }
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        await (sub ? client.SetSubMemoryChannelAsync(channel) : client.SetMemoryChannelAsync(channel));
        StatusText.Text = "";
    }

    /// The rig resolves what up/down means ("CH"; its wrap and blank-channel
    /// behavior aren't confirmed yet), so nothing is shown until the next
    /// poll reads the channel back — a guessed ±1 could be a blank channel
    /// the rig skipped.
    private async Task StepMemoryChannelAsync(bool sub, bool up)
    {
        if (_client is not { } client)
        {
            return;
        }
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        await (sub ? client.StepSubMemoryChannelAsync(up) : client.StepMemoryChannelAsync(up));
        StatusText.Text = "";
    }

    private async void ModeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelectionEvents || _client is null)
        {
            return;
        }
        if (ModeComboBox.SelectedItem is not ComboBoxItem { Tag: RigMode mode })
        {
            return;
        }
        try
        {
            await _client.SetModeAsync(mode);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set mode failed: {ex.Message}";
        }
    }

    /// rigctld has no "set band" verb — same gap CommandQueue.apply's
    /// .setBand case documents on the Swift side (it's normally resolved
    /// into a .setFrequency by HubService before reaching that queue).
    /// This always jumps to the band's default calling frequency; there's
    /// no per-band "last used frequency" memory yet (Mac's BandMemory
    /// equivalent) — out of v1 scope, add if it turns out to matter.
    private async void BandComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelectionEvents || _client is null)
        {
            return;
        }
        if (BandComboBox.SelectedItem is not ComboBoxItem { Tag: Band band })
        {
            return;
        }
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        try
        {
            await _client.SetFrequencyAsync(band.DefaultFrequencyHz);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set band failed: {ex.Message}";
        }
    }

    /// Momentary PTT, like the Mac/iPad: keyed while held, unkeyed on
    /// release. Pointer capture keeps the release coming here even if it
    /// happens outside the button (or the window).
    private async void PttButton_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_pttPointerDown || _client is not { } client)
        {
            return;
        }
        if (e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse
            && !e.GetCurrentPoint(PttButton).Properties.IsLeftButtonPressed)
        {
            return;
        }
        PttButton.CapturePointer(e.Pointer);
        _pttPointerDown = true;
        e.Handled = true;
        // Checked here as well as by dimming the button, same as the Mac,
        // where HubService.send re-checks what the PTT button already shows.
        if (TransmitGate.BlockReason(TransmitAction.PttOn, AppSettings.TransmitEnabled, _lastState.FrequencyHz) is { } reason)
        {
            AppLog.Write($"transmit-gate: blocked PTT on ({reason}) at {_lastState.FrequencyHz} Hz");
            StatusText.Text = reason;
            return;
        }
        _pttHeld = true;
        UpdateTransmitControls();
        try
        {
            await client.SetPttAsync(true);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set PTT failed: {ex.Message}";
        }
    }

    /// Release, cancel and capture loss all end the press. The T 0 queues
    /// behind a T 1 still in flight (RigctldClient serializes commands), so
    /// a quick tap can't leave the rig keyed.
    private async void PttButton_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_pttPointerDown)
        {
            return;
        }
        _pttPointerDown = false;
        _pttHeld = false;
        PttButton.ReleasePointerCaptures();
        UpdateTransmitControls();
        if (_client is not { } client)
        {
            return;
        }
        try
        {
            await client.SetPttAsync(false);
            _lastState.Ptt = false;
            UpdateTransmitControls();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Unkey failed — check the rig: {ex.Message}";
        }
    }

    /// Disconnect or window close with PTT still held: the pointer release
    /// would find no client, so unkey first. Blocks briefly (the client's
    /// awaits don't need this thread) since the window may be going away.
    private void UnkeyBeforeDisconnect()
    {
        if (!_pttHeld || _client is not { } client)
        {
            return;
        }
        _pttHeld = false;
        _pttPointerDown = false;
        try
        {
            client.SetPttAsync(false).Wait(TimeSpan.FromSeconds(1));
        }
        catch (Exception ex)
        {
            AppLog.Write($"ptt: unkey before disconnect failed: {ex.Message}");
        }
    }

    /// Enable Transmit, applied at once and persisted. Switching it off
    /// mid-transmission unkeys the rig rather than only blocking the next
    /// key-up — the Mac's HubService.transmitEnabled didSet.
    private async void TransmitEnabledSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        var enabled = TransmitEnabledSwitch.IsOn;
        // Also fires when the constructor loads the saved value.
        if (enabled == AppSettings.TransmitEnabled)
        {
            return;
        }
        AppSettings.TransmitEnabled = enabled;
        UpdateTransmitControls();
        if (!enabled)
        {
            // As on the Mac, turning transmit off also stops the CW sender.
            _cwSender.Stop();
            await ForceUnkeyAsync();
        }
    }

    /// Sends PTT off and MOX off unconditionally rather than only when the
    /// last poll saw them on (the Mac checks rigState first): the poll is up
    /// to a second stale, and unkeying an idle rig is a no-op. rigctld
    /// serializes commands, so this lands after any key-up already in flight.
    private async Task ForceUnkeyAsync()
    {
        if (_client is not { } client)
        {
            return;
        }
        AppLog.Write("transmit-gate: transmit disabled — forcing PTT and MOX off");
        try
        {
            await client.SetPttAsync(false);
            _pttHeld = false;
            _lastState.Ptt = false;
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Unkey failed — check the rig: {ex.Message}";
        }
        try
        {
            await client.SetMoxAsync(false);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"MOX off failed — check the rig: {ex.Message}";
        }
        UpdateTransmitControls();
    }

    /// Shows PTT as transmitting (red, like the Mac) while this app holds it
    /// or the poll reads the rig keyed, and dims it to the Mac's 0.4 while
    /// TransmitGate would block keying. It stays pressable when dimmed: a
    /// press still sends PTT off on release, so it can unkey a TX started
    /// elsewhere.
    private void UpdateTransmitControls()
    {
        // The CW decoder pauses during TX, including straight away on a
        // held PTT press; this also runs after every poll, which is what
        // the CW sender's finish detection reads PTT from.
        PushRigStateToCw();
        _cwSender.OnPtt(_lastState.Ptt);
        var keyed = _pttHeld || _lastState.Ptt;
        var reason = TransmitGate.BlockReason(TransmitAction.PttOn, AppSettings.TransmitEnabled, _lastState.FrequencyHz);
        PttButton.Opacity = reason is null || keyed ? 1 : 0.4;
        PttButton.Background = keyed ? new SolidColorBrush(Colors.Red) : _pttIdleBackground;
        PttText.Text = keyed ? "TRANSMITTING" : "PTT";
        if (keyed)
        {
            PttText.Foreground = new SolidColorBrush(Colors.White);
        }
        else
        {
            PttText.ClearValue(TextBlock.ForegroundProperty);
        }
        ToolTipService.SetToolTip(PttButton, reason ?? "Hold to transmit");
        _menuGrid.RefreshLabels();
    }

    /// Keyboard changes (arrow keys, Home/End) send at once; pointer drags
    /// and track clicks send once, on release (PowerSlider_PointerDone).
    private async void PowerSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_suppressPowerEvents || _powerDragging)
        {
            return;
        }
        await SendPowerLevelAsync(e.NewValue);
    }

    /// The ◀/▶ buttons beside the power slider: one whole watt (1% of
    /// RFPOWER) per click. Setting the slider's value sends it through
    /// PowerSlider_ValueChanged, like an arrow key, and quick clicks add up
    /// since each one steps from the slider's own value.
    private void PowerStep_Click(object sender, RoutedEventArgs e)
    {
        var step = int.Parse((string)((Button)sender).Tag);
        PowerSlider.Value = Math.Clamp(Math.Round(PowerSlider.Value) + step, 0, 100);
    }

    private async void PowerSlider_PointerDone(object sender, PointerRoutedEventArgs e)
    {
        if (!_powerDragging)
        {
            return;
        }
        _powerDragging = false;
        // A click that didn't move the thumb shouldn't send anything.
        if (_lastState.PowerLevel is { } rig && Math.Abs(rig * 100 - PowerSlider.Value) < 0.05)
        {
            return;
        }
        await SendPowerLevelAsync(PowerSlider.Value);
    }

    private async Task SendPowerLevelAsync(double sliderValue)
    {
        if (_client is null)
        {
            return;
        }
        _powerHoldUntil = DateTime.UtcNow + PowerHoldAfterSend;
        _lastState.PowerLevel = sliderValue / 100.0;
        _menuGrid.RefreshLabels();
        try
        {
            await _client.SetPowerLevelAsync(sliderValue / 100.0);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set power failed: {ex.Message}";
        }
    }

    /// Each meter is 190 px wide (the Mac's meterWidth) when there's room,
    /// and gives way to its Mute / SQL / VOL column in a narrow window, which
    /// keeps at least 140 px. Grid star sizing with Min/MaxWidth didn't hold
    /// that minimum, hence the explicit sizing.
    private void ChannelGrid_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        const double maxMeter = 190, minMeter = 110, minControls = 140, spacing = 10;
        var host = ReferenceEquals(sender, MainChannelGrid) ? MainMeterHost : SubMeterHost;
        host.Width = Math.Clamp(e.NewSize.Width - spacing - minControls, minMeter, maxMeter);
    }

    // Waterfall / oscilloscope

    /// Queues one UI-thread drain unless one is already pending.
    private void ScheduleScopeDrain()
    {
        if (Interlocked.Exchange(ref _scopeDrainPending, 1) == 0)
        {
            DispatcherQueue.TryEnqueue(DrainScope);
        }
    }

    /// Shows every row that arrived since the last drain (so the waterfall
    /// keeps its speed), the newest trace, and the Filter display's
    /// spectrum — Main's, or Sub's while SUB is the selected filter side
    /// (the Mac's FilterDisplayHost). Frames that land after audio stopped
    /// are dropped.
    private void DrainScope()
    {
        Interlocked.Exchange(ref _scopeDrainPending, 0);
        ScopeFrame? latest = null;
        while (_scopeFrames.TryDequeue(out var frame))
        {
            latest = frame;
            if (_audioSource is not null && _scopeMode != ScopeDisplayMode.Off)
            {
                _scope.Show(frame);
            }
        }
        var sub = _lastState.FilterSide == FilterSide.Sub;
        _scopeProcessor.SubSpectrumEnabled = sub && _scopeMode != ScopeDisplayMode.Off;
        if (!sub)
        {
            _latestSubSpectrum = null;
        }
        if (_audioSource is null || _scopeMode == ScopeDisplayMode.Off)
        {
            return;
        }
        if (sub)
        {
            _filterPanel.SetSpectrum(_latestSubSpectrum ?? []);
        }
        else if (latest is not null)
        {
            _filterPanel.SetSpectrum(latest.Spectrum);
        }
    }

    private void ClearScope()
    {
        _scopeFrames.Clear();
        _latestSubSpectrum = null;
        _scope.Clear();
        _filterPanel.SetSpectrum([]);
    }

    private void ScopeModeButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string tag } && Enum.TryParse<ScopeDisplayMode>(tag, out var mode))
        {
            SetScopeMode(mode);
            AppSettings.ScopeDisplayMode = mode;
        }
    }

    /// Off also stops the FFT (ScopeProcessor.DisplayEnabled), as on the
    /// Mac; playback is unaffected.
    private void SetScopeMode(ScopeDisplayMode mode)
    {
        _scopeMode = mode;
        _scopeProcessor.DisplayEnabled = mode != ScopeDisplayMode.Off;
        _scope.Mode = mode;
        ScopeWaterfallButton.IsChecked = mode == ScopeDisplayMode.Waterfall;
        ScopeOscilloscopeButton.IsChecked = mode == ScopeDisplayMode.Oscilloscope;
        ScopeOffButton.IsChecked = mode == ScopeDisplayMode.Off;
        if (mode == ScopeDisplayMode.Off)
        {
            ClearScope();
        }
        UpdateScopeZoomControls();
    }

    /// One pair of arrows for whichever display is showing; the two zooms
    /// are separate settings. Dimmed and inert while Off.
    private void ScopeZoomButton_Click(object sender, RoutedEventArgs e)
    {
        var factor = sender is FrameworkElement { Tag: "up" } ? ScopeZoomStep : 1 / ScopeZoomStep;
        switch (_scopeMode)
        {
            case ScopeDisplayMode.Waterfall:
                _waterfallZoom = Math.Clamp(_waterfallZoom * factor, MinScopeZoom, MaxScopeZoom);
                _scopeProcessor.WaterfallZoom = _waterfallZoom;
                break;
            case ScopeDisplayMode.Oscilloscope:
                _oscilloscopeZoom = Math.Clamp(_oscilloscopeZoom * factor, MinScopeZoom, MaxScopeZoom);
                _scopeProcessor.OscilloscopeZoom = _oscilloscopeZoom;
                break;
        }
        UpdateScopeZoomControls();
    }

    private void UpdateScopeZoomControls()
    {
        var off = _scopeMode == ScopeDisplayMode.Off;
        ScopeZoomPanel.Opacity = off ? 0.3 : 1;
        ScopeZoomInButton.IsEnabled = !off;
        ScopeZoomOutButton.IsEnabled = !off;
        ScopeZoomText.Text = _scopeMode switch
        {
            ScopeDisplayMode.Waterfall => $"{_waterfallZoom:0.0}x",
            ScopeDisplayMode.Oscilloscope => $"{_oscilloscopeZoom:0.0}x",
            _ => "—",
        };
    }

    // APRS

    /// Hands a decoder's packets to the store (and the VFO box) on the UI
    /// thread.
    private void WireAprsDecoder(AprsDecoder decoder, AprsSource source)
    {
        decoder.StationHeard += (callsign, latitude, longitude, symbolTable, symbolCode, comment) =>
            DispatcherQueue.TryEnqueue(() =>
            {
                var heard = (callsign, DateTime.UtcNow);
                if (source == AprsSource.Main)
                {
                    _aprsMainLastHeard = heard;
                }
                else
                {
                    _aprsSubLastHeard = heard;
                }
                _aprsStore.RecordStation(callsign, latitude, longitude, symbolTable, symbolCode, comment, DateTimeOffset.Now, source);
                UpdateC4fmDisplay();
            });
        decoder.MessageReceived += (from, to, text, messageId) =>
            DispatcherQueue.TryEnqueue(() =>
                _aprsStore.RecordMessage(from, to, text, messageId, DateTimeOffset.Now, source));
    }

    /// Audio thread: passes one receiver's chunk to its decoder while that
    /// receiver's VFO is on the APRS frequency, logging each open/close.
    private void FeedAprs(AprsDecoder decoder, float[] samples, long vfoHz, ref bool wasOpen, string name)
    {
        var open = AppSettings.IsAprsActive(vfoHz);
        if (open != wasOpen)
        {
            wasOpen = open;
            AppLog.Write($"aprs-gate: {name} {(open ? "opened" : "closed")} at {vfoHz} Hz");
        }
        if (open)
        {
            decoder.Process(samples, _audioSampleRate);
        }
    }

    /// S.LIST / M.LIST (and the APRS button): one window of each kind,
    /// brought to the front if it's already open.
    private void ShowAprsList(AprsListKind kind)
    {
        if (!_aprsWindows.TryGetValue(kind, out var window))
        {
            window = new AprsListWindow(kind, _aprsStore);
            window.Closed += (_, _) => _aprsWindows.Remove(kind);
            _aprsWindows[kind] = window;
        }
        window.Activate();
    }

    // Recording (the CW page's PLAY/RECORD)

    /// PLAY (and the WebSDR window's Recordings button): one Recordings
    /// window, brought to the front if it's already open.
    private void ShowRecordings()
    {
        if (_recordingsWindow is null)
        {
            _recordingsWindow = new RecordingsWindow(_audioRecorder);
            _recordingsWindow.Closed += (_, _) => _recordingsWindow = null;
        }
        _recordingsWindow.Activate();
    }

    /// RECORD: starts a file named for Main's frequency/mode now (the Mac's
    /// HubService.toggleAudioRecording), or saves the one being written.
    private void ToggleRecording()
    {
        if (_audioRecorder.IsRecording)
        {
            StopRecording();
            return;
        }
        if (_audioSource is null)
        {
            StatusText.Text = "Turn on audio to record.";
            return;
        }
        var mode = _lastState.MainIsC4fm == true ? "C4FM" : _lastState.Mode?.DisplayName() ?? "";
        _audioRecorder.Start(IsConnected && _lastState.FrequencyHz > 0 ? Recordings.Label(_lastState.FrequencyHz, mode) : "");
        StatusText.Text = "Recording Main audio…";
        UpdateRecordingState();
    }

    private void StopRecording()
    {
        if (!_audioRecorder.IsRecording)
        {
            return;
        }
        var path = _audioRecorder.Stop();
        StatusText.Text = path is null
            ? "Recording stopped — no audio arrived, nothing saved."
            : $"Saved {System.IO.Path.GetFileName(path)} to Recordings.";
        UpdateRecordingState();
    }

    private void UpdateRecordingState()
    {
        _menuGrid.SetRecordingState(_audioRecorder.IsRecording, _audioSource is not null);
        _recordingsWindow?.Reload();
    }

    // WebSDR window

    private void WebSdrButton_Click(object sender, RoutedEventArgs e)
    {
        if (_webSdrWindow is null)
        {
            _webSdrWindow = new WebSdrWindow(new WebSdrRigLink
            {
                Current = CurrentRigSnapshot,
                Tune = (hz, mode) => _ = TuneFromWebSdrAsync(hz, mode),
                SetAudioActive = SetWebSdrAudioActive,
            });
            _webSdrWindow.Closed += (_, _) => _webSdrWindow = null;
            _webSdrWindow.RecordingsRequested += ShowRecordings;
            PushRigStateToWebSdr();
        }
        _webSdrWindow.Activate();
    }

    // CW window

    private void CwButton_Click(object sender, RoutedEventArgs e)
    {
        if (_cwWindow is null)
        {
            _cwWindow = new CwWindow(_cwReceiver, _cwSender, new CwWindowLink
            {
                SingleReceive = () => IsConnected ? _singleReceive : null,
                BreakIn = () => IsConnected ? _lastState.BreakIn : null,
                SetBreakIn = _menuGrid.SetBreakIn,
                SetSpeed = _menuGrid.SetCwSpeed,
            });
            _cwWindow.Closed += (_, _) => _cwWindow = null;
            PushRigStateToCw();
            // Speed/BK-IN/pitch now rather than at the next slow poll.
            if (_client is { } client)
            {
                _ = _menuGrid.RefreshKeyerAsync(client);
            }
        }
        _cwWindow.Activate();
    }

    /// Why the CW send pane can't key the rig right now (the Mac's
    /// CWSender.blockReason): checked before every chunk, and the queue
    /// waits while there's a reason. The transmit gate is TransmitGate's.
    private CwSendBlock? CwSendBlockReason()
    {
        if (!IsConnected)
        {
            return CwSendBlock.NotConnected;
        }
        if (TransmitGate.BlockReason(TransmitAction.PlayCwTextMemory, AppSettings.TransmitEnabled, _lastState.FrequencyHz) is { } reason)
        {
            return CwSendBlock.TransmitBlocked(reason);
        }
        if (_lastState.MainIsC4fm == true)
        {
            return CwSendBlock.NotCw("C4FM");
        }
        if (_lastState.Mode != RigMode.Cw)
        {
            return CwSendBlock.NotCw(_lastState.Mode?.DisplayName() ?? "an unknown mode");
        }
        if (_lastState.BreakIn == false)
        {
            return CwSendBlock.BreakInOff;
        }
        return null;
    }

    /// From UpdateTransmitControls (every poll and PTT change) and on
    /// disconnect — the Mac's cwRigCancellable.
    /// Modes only while connected (the last session's would otherwise
    /// linger in _lastState); null in C4FM, which has no RigMode here.
    private void PushRigStateToCw() => _cwReceiver.RigInfoChanged(IsConnected
        ? new CwRigInfo(
            _lastState.Ptt || _pttHeld,
            _lastState.CwPitchHz,
            _lastState.MainIsC4fm == true ? null : _lastState.Mode,
            _lastState.SubIsC4fm == true ? null : _lastState.SubMode)
        : default);

    /// Main's frequency is 0 while disconnected (the last session's would
    /// otherwise linger in _lastState), which the WebSDR window reads as
    /// "no rig frequency".
    private RigSnapshot CurrentRigSnapshot() => IsConnected
        ? new RigSnapshot(_lastState.FrequencyHz, _lastState.MainIsC4fm == true ? null : _lastState.Mode, _lastState.Ptt, _lastState.InMemoryMode)
        : new RigSnapshot(0, null, false, false);

    /// After every poll and on disconnect — the Mac's WebSDR window
    /// subscribes to hub.$rigState instead.
    private void PushRigStateToWebSdr() => _webSdrWindow?.Model.OnRigState(CurrentRigSnapshot());

    /// Click-to-tune from the WebSDR page: the same paths as the Set button
    /// and the mode picker.
    private async Task TuneFromWebSdrAsync(long? hz, RigMode? mode)
    {
        if (hz is { } frequency)
        {
            await SetMainFrequencyAsync(frequency);
        }
        if (mode is { } newMode && _client is { } client)
        {
            try
            {
                await client.SetModeAsync(newMode);
            }
            catch (Exception ex)
            {
                StatusText.Text = $"Set mode failed: {ex.Message}";
            }
        }
    }

    /// Called by the WebSDR window whenever its page becomes audible
    /// (connected and not muted there) or stops being so, so the rig's Main
    /// audio and the page's don't play over each other — the Mac's
    /// HubService.setWebSDRAudioActive. Mutes Main only if it isn't muted
    /// already, and unmutes it only if this is what muted it
    /// (AppSettings.MainMutedByWebSdr). Gates playback only, like the Mute
    /// button — APRS and the scope are unaffected.
    private void SetWebSdrAudioActive(bool active)
    {
        if (active)
        {
            if (_mainPlayer.IsMuted)
            {
                return;
            }
            AppSettings.MainMutedByWebSdr = true;
            SetMainMuted(true);
        }
        else
        {
            if (!AppSettings.MainMutedByWebSdr)
            {
                return;
            }
            AppSettings.MainMutedByWebSdr = false;
            SetMainMuted(false);
        }
    }

    private void SetMainMuted(bool muted)
    {
        _mainPlayer.IsMuted = muted;
        MainMuteToggle.IsChecked = muted;
        AppSettings.MainAudio.Muted = muted;
        AppSettings.SaveAudio();
    }

    private void AprsStationsMenuItem_Click(object sender, RoutedEventArgs e) => ShowAprsList(AprsListKind.Stations);

    private void AprsMessagesMenuItem_Click(object sender, RoutedEventArgs e) => ShowAprsList(AprsListKind.Messages);

    // Audio (Pi :8532)

    /// Starts the session's audio source and playback together: the Pi's
    /// :8532 stream in Remote mode, the chosen input device in Local mode.
    /// Runs only while the rig link is up — each source has its own retry
    /// loop, but its lifetime follows Connect/Disconnect, the Audio switch
    /// and (Local) the input device chosen in Settings → Audio.
    private void StartAudio()
    {
        if (_audioSource is not null)
        {
            return;
        }
        _audioSetupError = null;

        // The source's channels are physical L/R; after a Main/Sub swap they
        // go to the opposite roles (see AudioChannelSwapTracker).
        void Route(float[] left, float[] right)
        {
            var swapped = _audioChannelsSwapped;
            var main = swapped ? right : left;
            var sub = swapped ? left : right;
            _mainPlayer.Push(main);
            _subPlayer.Push(sub);
            // Same routed channels, so the waterfall follows a swap too.
            _scopeProcessor.Process(main, sub, _audioSampleRate);
            // And APRS: each receiver gated on its own VFO, so the Main
            // decoder always hears whatever Main is tuned to.
            FeedAprs(_aprsMainDecoder, main, Volatile.Read(ref _aprsMainGateHz), ref _aprsMainGateOpen, "Main");
            FeedAprs(_aprsSubDecoder, sub, Volatile.Read(ref _aprsSubGateHz), ref _aprsSubGateOpen, "Sub");
            // And CW, which keeps the selected receiver while its window is open.
            _cwReceiver.Ingest(main, sub, _audioSampleRate);
            // And RECORD, Main only as on the Mac.
            _audioRecorder.Ingest(main, _audioSampleRate);
        }

        IAudioSource source;
        if (_connectedMode == ConnectionMode.Remote)
        {
            source = new RemoteAudioStreamClient(_connectedHost, Route);
        }
        else
        {
            var deviceId = AppSettings.LocalAudioDeviceId;
            if (deviceId.Length == 0)
            {
                // Nothing chosen yet: the only "USB Audio" input, if there's
                // exactly one, is the FTX-1's codec's usual name.
                var usb = LocalAudioCapture.ListDevices()
                    .Where(d => d.Name.Contains("USB Audio", StringComparison.OrdinalIgnoreCase)).ToList();
                if (usb.Count == 1)
                {
                    AppSettings.SetLocalAudioDevice(usb[0].Id, usb[0].Name);
                    deviceId = usb[0].Id;
                }
            }
            if (deviceId.Length == 0)
            {
                _audioSetupError = "Choose the radio's audio input in Settings → Audio.";
                UpdateAudioStatus();
                return;
            }
            try
            {
                source = new LocalAudioCapture(deviceId, Route);
            }
            catch (Exception ex)
            {
                AppLog.Write($"local-audio: can't open {deviceId}: {ex.Message}");
                _audioSetupError = $"\"{AppSettings.LocalAudioDeviceName}\" isn't available — is the radio plugged in and on? Pick it again in Settings → Audio once it is.";
                UpdateAudioStatus();
                return;
            }
        }

        _audioSource = source;
        _audioSampleRate = source.SampleRate;
        StartPlayback();
        source.Start();
        _audioStatusTimer.Start();
        UpdateAudioStatus();
        UpdateRecordingState();
    }

    /// (Re)starts playback for the running source on the output device
    /// chosen in Settings → Audio. In Local mode, first applies the feedback guard: playing to
    /// the radio's own USB codec would feed its TX audio input (and with VOX
    /// or DATA-mode keying, could transmit it).
    private void StartPlayback()
    {
        if (_audioSource is not { } source)
        {
            return;
        }
        _playback.Stop();
        _playbackBlockedForDeviceId = null;
        _playbackError = null;
        _playbackNote = null;

        var chosenId = AppSettings.AudioOutputDeviceId;
        var outputId = AudioPlayback.ResolveOutputId(chosenId);
        var usingDefault = chosenId.Length == 0 || outputId != chosenId;
        if (chosenId.Length > 0 && usingDefault)
        {
            _playbackNote = $"\"{AppSettings.AudioOutputDeviceName}\" isn't connected, playing on Windows' default output";
        }

        var captureId = AppSettings.LocalAudioDeviceId;
        if (_connectedMode == ConnectionMode.Local && captureId.Length > 0 && outputId is not null
            && LocalAudioCapture.IsSameAdapter(captureId, outputId))
        {
            _playbackBlockedForDeviceId = captureId;
            _playbackRecheckCountdown = PlaybackRecheckTicks;
            _playbackError = usingDefault
                ? "Windows' default output is the radio's own USB audio, which would feed its transmit input — pick your speakers in Settings → Audio (or as Windows' default; Windows switches to the radio's audio when it's plugged in). Playback starts by itself once the default changes"
                : "the output chosen in Settings → Audio is the radio's own USB audio, which would feed its transmit input — pick your speakers there";
            return;
        }
        _playbackError = _playback.Start(source.SampleRate, outputId);
    }

    /// Starts playback once the feedback guard's reason has gone away. The
    /// check lists audio endpoints, so it runs every couple of seconds, not
    /// on every status tick. WasapiOut stays on the device it opened, so a
    /// default switch *to* the radio mid-session can't redirect playback.
    private void RecheckBlockedPlayback()
    {
        if (_playbackBlockedForDeviceId is not { } deviceId || _audioSource is null)
        {
            return;
        }
        if (--_playbackRecheckCountdown > 0)
        {
            return;
        }
        _playbackRecheckCountdown = PlaybackRecheckTicks;
        if (AudioPlayback.ResolveOutputId(AppSettings.AudioOutputDeviceId) is { } outputId
            && LocalAudioCapture.IsSameAdapter(deviceId, outputId))
        {
            return;
        }
        AppLog.Write("audio-playback: output is no longer the radio — starting playback");
        StartPlayback();
    }

    private async Task StopAudioAsync()
    {
        var source = _audioSource;
        _audioSource = null;
        _playbackBlockedForDeviceId = null;
        _audioStatusTimer.Stop();
        if (source is not null)
        {
            await source.StopAsync();
        }
        // A recording ends with its audio, so a file never spans two
        // sources (or two sample rates).
        StopRecording();
        UpdateRecordingState();
        ClearScope();
        _playback.Stop();
        _playbackError = null;
        _playbackNote = null;
        _audioSetupError = null;
        UpdateAudioStatus();
    }

    private void UpdateAudioStatus()
    {
        var gray = new SolidColorBrush(Colors.Gray);
        if (_audioSource is not { } source)
        {
            AudioStateText.Text = !IsConnected ? "Not connected"
                : _audioSetupError ?? (AudioSwitch.IsOn ? "Starting…" : "Off");
            AudioStateText.Foreground = _audioSetupError is null ? gray : new SolidColorBrush(Colors.Firebrick);
            AudioLevelsText.Text = "";
            MainSquelchLed.Fill = gray;
            SubSquelchLed.Fill = gray;
            return;
        }

        var status = source.GetStatus();
        var (text, color) = status.Phase switch
        {
            AudioLinkPhase.Streaming when _connectedMode == ConnectionMode.Local => ($"Capturing — {status.Detail}", Colors.Green),
            AudioLinkPhase.DeviceUnavailable => ($"Audio input unavailable, retrying — {status.Detail}", Colors.Firebrick),
            AudioLinkPhase.Connecting => ("Connecting to :8532…", Colors.Orange),
            AudioLinkPhase.Unreachable => ($"Can't reach the Pi's audio stream (:8532), retrying — {status.Detail}", Colors.Firebrick),
            AudioLinkPhase.WaitingForStream => ("Connected, no audio — another client (the Mac?) probably has the Pi's stream; will pick it up when it's free", Colors.Orange),
            AudioLinkPhase.Streaming => ("Streaming", Colors.Green),
            _ => ("Off", Colors.Gray),
        };
        if (_playbackError is not null)
        {
            text += $" · no audio output: {_playbackError}";
            color = Colors.Firebrick;
        }
        else if (_playbackNote is not null)
        {
            text += $" · {_playbackNote}";
        }
        AudioStateText.Text = text;
        AudioStateText.Foreground = new SolidColorBrush(color);

        var streaming = status.Phase == AudioLinkPhase.Streaming;
        // Raw per-channel levels — the quickest check that Main (L) and Sub
        // (R) really are separate, like the Mac's "stereo check" log line.
        var (mainRms, subRms) = _audioChannelsSwapped ? (status.RightRms, status.LeftRms) : (status.LeftRms, status.RightRms);
        AudioLevelsText.Text = streaming
            ? $"RMS  Main {mainRms:F3}   Sub {subRms:F3}{(_audioChannelsSwapped ? "   (L/R swapped)" : "")}"
            : "";
        var open = new SolidColorBrush(Colors.LimeGreen);
        MainSquelchLed.Fill = streaming && _mainPlayer.IsSquelchOpen ? open : gray;
        SubSquelchLed.Fill = streaming && _subPlayer.IsSquelchOpen ? open : gray;
    }

    private async void AudioSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (_suppressAudioEvents)
        {
            return;
        }
        AppSettings.AudioEnabled = AudioSwitch.IsOn;
        if (!IsConnected)
        {
            UpdateAudioStatus();
            return;
        }
        if (AudioSwitch.IsOn)
        {
            StartAudio();
        }
        else
        {
            await StopAudioAsync();
        }
    }

    private void MainMuteToggle_Click(object sender, RoutedEventArgs e)
    {
        AppSettings.MainMutedByWebSdr = false;  // the user's call from here on
        _mainPlayer.IsMuted = MainMuteToggle.IsChecked == true;
        AppSettings.MainAudio.Muted = _mainPlayer.IsMuted;
        AppSettings.SaveAudio();
    }

    private void SubMuteToggle_Click(object sender, RoutedEventArgs e)
    {
        _subPlayer.IsMuted = SubMuteToggle.IsChecked == true;
        AppSettings.SubAudio.Muted = _subPlayer.IsMuted;
        AppSettings.SaveAudio();
    }

    private void MainVolumeSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_suppressAudioEvents)
        {
            return;
        }
        _mainPlayer.Volume = (float)e.NewValue;
        AppSettings.MainAudio.Volume = e.NewValue;
        AppSettings.SaveAudio();
    }

    private void SubVolumeSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_suppressAudioEvents)
        {
            return;
        }
        _subPlayer.Volume = (float)e.NewValue;
        AppSettings.SubAudio.Volume = e.NewValue;
        AppSettings.SaveAudio();
    }

    private void MainSquelchSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_suppressAudioEvents)
        {
            return;
        }
        var threshold = SquelchRange - e.NewValue;
        _mainPlayer.SquelchThreshold = (float)threshold;
        AppSettings.MainAudio.SquelchThreshold = threshold;
        AppSettings.SaveAudio();
    }

    private void SubSquelchSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_suppressAudioEvents)
        {
            return;
        }
        var threshold = SquelchRange - e.NewValue;
        _subPlayer.SquelchThreshold = (float)threshold;
        AppSettings.SubAudio.SquelchThreshold = threshold;
        AppSettings.SaveAudio();
    }

    /// The window's width on first open, in DIPs: the user's preferred
    /// width (2026-10-03, read off their window at 150% scaling: 2177 px).
    /// Windows' own default was wider. The height stays Windows' default.
    private const int InitialWidthDips = 1451;

    /// Applies <see cref="InitialWidthDips"/> at this monitor's scaling,
    /// never wider than the screen's work area.
    private void SetInitialWidth()
    {
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var width = (int)Math.Round(InitialWidthDips * scale, MidpointRounding.AwayFromZero);
        var workArea = Microsoft.UI.Windowing.DisplayArea
            .GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Nearest).WorkArea;
        width = Math.Min(width, workArea.Width);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(width, AppWindow.Size.Height));
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}

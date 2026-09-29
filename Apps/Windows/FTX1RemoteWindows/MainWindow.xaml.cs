using System.Diagnostics;
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
using Windows.Storage.Pickers;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows;

/// v1 core-rig-control window: VFO A/B, mode, PTT, power, SWR, band — see
/// Apps/Windows/README.md's "v1 scope" — plus Main/Sub audio playback from
/// the Pi's :8532 stream, and the MENU grid (Controls/MenuGrid.cs). No Deep
/// Settings / waterfall / APRS here yet.
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

    private static readonly int[] BaudRates = [4800, 9600, 19200, 38400, 115200];

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
    private bool _suppressAudioInputEvents;
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
    private bool _suppressAudioOutputEvents;
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
    /// yet. Read every <see cref="SlowPollEvery"/> polls.
    private bool? _singleReceive;
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
    /// 10 × the 500 ms poll keeps the slow tier at ~5 s, where it was
    /// when the poll ran every second.
    private const int SlowPollEvery = 10;
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

    /// Memory channels 1-999 (RigState.swift's memoryChannelRange): the CAT
    /// manual's "MC" entry says 99, but its MR/MW/MZ entries say 999, and
    /// the user's rig has 278 programmed.
    private const int MinMemoryChannel = 1;
    private const int MaxMemoryChannel = 999;

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
        AppLog.Write($"app: started ({AppSettings.ConnectionMode} mode, audio swapped={AppSettings.AudioChannelsSwapped})");

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
        MenuGridHost.Child = _menuGrid;
        MainMeterHost.Child = _mainMeter;
        SubMeterHost.Child = _subMeter;

        PiHostBox.Text = AppSettings.PiHost;
        RigctldPathBox.Text = AppSettings.RigctldPath;
        WpsdEnabledCheckBox.IsChecked = AppSettings.WpsdEnabled;
        WpsdHostBox.Text = AppSettings.WpsdHost;
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
        RefreshComPorts();
        // Not in the constructor directly: WinUI 3's editable ComboBox drops
        // a Text set before its template is applied, which left the box
        // blank (showing only its "COM3" placeholder) on every launch — and
        // Connect then saved that blank as the COM port.
        ComPortComboBox.Loaded += (_, _) => ShowComPort(AppSettings.ComPort);
        RefreshAudioInputs();
        RefreshAudioOutputs();
        foreach (var rate in BaudRates)
        {
            BaudRateComboBox.Items.Add(new ComboBoxItem { Content = rate.ToString(), Tag = rate });
        }
        BaudRateComboBox.SelectedIndex = Math.Max(0, Array.IndexOf(BaudRates, AppSettings.BaudRate));
        ConnectionModeComboBox.SelectedIndex = AppSettings.ConnectionMode == ConnectionMode.Local ? 1 : 0;
        UpdateModePanels();

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
        // 500 ms, the Mac's fast-tier default, so the S-meters move live.
        _pollTimer.Interval = TimeSpan.FromMilliseconds(500);
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
            // remembered VFO isn't Main's any more (see SwapVfoButton_Click).
            if (reason.StartsWith("front-panel", StringComparison.Ordinal))
            {
                _lastVfoState = null;
            }
            _audioChannelsSwapped = _swapTracker.Swapped;
            AppSettings.AudioChannelsSwapped = _swapTracker.Swapped;
            AudioSwapToggle.IsChecked = _swapTracker.Swapped;
            UpdateAudioSwapTooltip();
            AppLog.Write($"audio-routing: swapped={_swapTracker.Swapped} ({reason}) main {_lastState.FrequencyHz} sub {_lastState.SecondaryFrequencyHz}");
        };

        var mainAudio = AppSettings.MainAudio;
        var subAudio = AppSettings.SubAudio;
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
        };
    }

    private bool IsConnected => _client is not null;

    /// The mode of the current session (set on a successful Connect) — the
    /// picker itself is locked while connected, but this is what audio
    /// gating reads.
    private ConnectionMode _connectedMode;

    private ConnectionMode SelectedMode =>
        ConnectionModeComboBox.SelectedItem is ComboBoxItem { Tag: "Local" } ? ConnectionMode.Local : ConnectionMode.Remote;

    private void ConnectionModeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateModePanels();
    }

    private void UpdateModePanels()
    {
        var local = SelectedMode == ConnectionMode.Local;
        LocalSettingsPanel.Visibility = local ? Visibility.Visible : Visibility.Collapsed;
        RemoteSettingsPanel.Visibility = local ? Visibility.Collapsed : Visibility.Visible;
    }

    /// Enables/disables the connection settings together — changing mode,
    /// host, COM port etc. mid-session would leave the UI describing a
    /// connection that isn't the one in use.
    private void SetConnectionSettingsEnabled(bool enabled)
    {
        ConnectionModeComboBox.IsEnabled = enabled;
        PiHostBox.IsEnabled = enabled;
        RigctldPathBox.IsEnabled = enabled;
        BrowseRigctldButton.IsEnabled = enabled;
        ComPortComboBox.IsEnabled = enabled;
        BaudRateComboBox.IsEnabled = enabled;
    }

    private void ComPortComboBox_DropDownOpened(object sender, object e)
    {
        RefreshComPorts();
    }

    /// Lists the COM ports Windows currently knows about, straight from the
    /// registry key SerialPort.GetPortNames() reads (so no System.IO.Ports
    /// package just for this). The box stays editable, so a port that isn't
    /// plugged in yet can still be typed.
    private void RefreshComPorts()
    {
        var typed = CurrentComPort();
        var ports = new List<string>();
        try
        {
            using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"HARDWARE\DEVICEMAP\SERIALCOMM");
            if (key is not null)
            {
                foreach (var name in key.GetValueNames())
                {
                    if (key.GetValue(name) is string port)
                    {
                        ports.Add(port);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"COM port enumeration failed: {ex.Message}");
        }
        ports.Sort((a, b) => ComPortNumber(a).CompareTo(ComPortNumber(b)));

        ComPortComboBox.Items.Clear();
        foreach (var port in ports.Distinct())
        {
            ComPortComboBox.Items.Add(port);
        }
        ShowComPort(typed);
    }

    /// Puts a port in the box by selecting its list entry — adding one if
    /// the port isn't currently listed (not plugged in yet, or hidden by a
    /// COM-number clash), so it still shows. Setting an editable
    /// ComboBox's Text programmatically doesn't reliably display in WinUI 3
    /// (and Items.Clear() wipes it), so selection is the only path used.
    private void ShowComPort(string port)
    {
        port = port.Trim();
        if (port.Length == 0)
        {
            ComPortComboBox.SelectedIndex = -1;
            return;
        }
        var match = ComPortComboBox.Items.OfType<string>()
            .FirstOrDefault(p => string.Equals(p, port, StringComparison.OrdinalIgnoreCase));
        if (match is null)
        {
            match = port.ToUpperInvariant();
            ComPortComboBox.Items.Add(match);
        }
        ComPortComboBox.SelectedItem = match;
    }

    /// What the box shows: typed text, or the selected entry if the text
    /// hasn't caught up with a selection yet.
    private string CurrentComPort()
    {
        var text = ComPortComboBox.Text?.Trim() ?? "";
        return text.Length > 0 ? text : (ComPortComboBox.SelectedItem as string ?? "");
    }

    private static int ComPortNumber(string port) =>
        port.StartsWith("COM", StringComparison.OrdinalIgnoreCase) && int.TryParse(port.AsSpan(3), out var n) ? n : int.MaxValue;

    private async void BrowseRigctldButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        // Unpackaged WinUI 3 pickers need the owning window's HWND.
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".exe");
        var file = await picker.PickSingleFileAsync();
        if (file is not null)
        {
            RigctldPathBox.Text = file.Path;
        }
    }

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        if (IsConnected)
        {
            await DisconnectAsync(null);
            return;
        }

        var mode = SelectedMode;
        AppSettings.ConnectionMode = mode;

        string host;
        string description;
        if (mode == ConnectionMode.Remote)
        {
            host = PiHostBox.Text.Trim();
            if (host.Length == 0)
            {
                StatusText.Text = "Enter the Pi's Tailscale hostname first.";
                return;
            }
            AppSettings.PiHost = host;
            description = $"{host}:{RigctldPort}";
        }
        else
        {
            host = LocalHost;
            AppSettings.RigctldPath = RigctldPathBox.Text.Trim().Trim('"');
            AppSettings.ComPort = CurrentComPort().ToUpperInvariant();
            if (BaudRateComboBox.SelectedItem is ComboBoxItem { Tag: int baud })
            {
                AppSettings.BaudRate = baud;
            }
            RigctldPathBox.Text = AppSettings.RigctldPath;
            ShowComPort(AppSettings.ComPort);
            description = $"{AppSettings.ComPort} @ {AppSettings.BaudRate} via local rigctld";
        }

        ConnectButton.IsEnabled = false;
        SetConnectionSettingsEnabled(false);
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
            ClearMemoryState();
            ClearC4fmState();
            // Run the slow tier (FR, MENU grid) on the first poll.
            _pollCount = 0;
            ConnectionStateText.Text = $"Connected to {description}";
            AppLog.Write($"connection: connected to {description} ({mode}); audio swapped={_swapTracker.Swapped}");
            ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green);
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
            SetConnectionSettingsEnabled(true);
            ConnectionStateText.Text = "Disconnected";
            ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Gray);
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
        _mainMeter.Reset();
        _subMeter.Reset();
        ClearMemoryState();
        ClearC4fmState();
        if (client is not null)
        {
            await client.DisposeAsync();
        }
        _rigctldProcess.Stop();
        SetConnectionSettingsEnabled(true);
        ConnectionStateText.Text = "Disconnected";
        ConnectionStateText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Gray);
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

        var slowTier = _pollCount++ % SlowPollEvery == 0;
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
                }
            }
            catch (Exception ex)
            {
                AppLog.Write($"poll: FR failed: {ex.Message}");
            }

            // Slow tier: modes rarely change, and a C4FM switch only has to
            // start the WPSD lookup and skip the MENU grid's GT0/PR1 (which
            // go unanswered in C4FM). Main's fast-tier mode read also clears
            // MainIsC4fm as soon as it reads a mode this app knows.
            _lastState.MainIsC4fm = await ReadC4fmAsync(client, sub: false) ?? _lastState.MainIsC4fm;
            _lastState.SubIsC4fm = await ReadC4fmAsync(client, sub: true) ?? _lastState.SubIsC4fm;
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
        }

        UpdateWpsdMonitorState();

        // Also refreshes the MENU grid (RF POWER, and the MOX/ANT TUNE gate
        // follows the new frequency).
        UpdateTransmitControls();
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

    /// Each side shows the caller and reflector only while it's in C4FM,
    /// like the Mac's VFODisplayBox call sites.
    private void UpdateC4fmDisplay()
    {
        var mainC4fm = _lastState.MainIsC4fm == true;
        var subC4fm = _lastState.SubIsC4fm == true;
        C4fmCallsignAText.Text = mainC4fm ? _lastState.C4fmCallsign ?? "" : "";
        C4fmReflectorAText.Text = mainC4fm ? _lastState.C4fmReflector ?? "" : "";
        C4fmCallsignBText.Text = subC4fm ? _lastState.C4fmCallsign ?? "" : "";
        C4fmReflectorBText.Text = subC4fm ? _lastState.C4fmReflector ?? "" : "";
    }

    private void WpsdEnabledCheckBox_Click(object sender, RoutedEventArgs e)
    {
        AppSettings.WpsdEnabled = WpsdEnabledCheckBox.IsChecked == true;
        UpdateWpsdMonitorState();
    }

    private void WpsdHostBox_LostFocus(object sender, RoutedEventArgs e) => SaveWpsdHost();

    private void WpsdHostBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            SaveWpsdHost();
        }
    }

    /// Stripped of a pasted "http://" and trailing "/", since the monitor
    /// builds the URL itself.
    private void SaveWpsdHost()
    {
        var host = WpsdHostBox.Text.Trim();
        if (host.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            host = host["http://".Length..];
        }
        host = host.TrimEnd('/');
        WpsdHostBox.Text = host;
        if (host == AppSettings.WpsdHost)
        {
            return;
        }
        AppSettings.WpsdHost = host;
        // A different hotspot: don't keep showing the old one's caller.
        _lastState.C4fmCallsign = null;
        _lastState.C4fmReflector = null;
        UpdateWpsdMonitorState();
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

    private static string FormatHz(long hz) => hz.ToString("N0") + " Hz";

    private async void SetFrequencyButton_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        if (!long.TryParse(FrequencyEntryBox.Text.Trim(), out var hz))
        {
            StatusText.Text = "Enter a frequency in Hz.";
            return;
        }
        await SetMainFrequencyAsync(hz);
    }

    /// Tunes the Main VFO: the Set button and the MENU grid's HOME. An app
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
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Swap VFO failed: {ex.Message}";
            AppLog.Write($"swap: SV failed: {ex.Message}");
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
        var memory = _lastState.InMemoryMode;
        MemoryChannelEntryPanel.Visibility = memory ? Visibility.Visible : Visibility.Collapsed;
        FrequencyEntryPanel.Visibility = memory ? Visibility.Collapsed : Visibility.Visible;
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

    private async void SetMemoryChannelButton_Click(object sender, RoutedEventArgs e)
    {
        if (_client is not { } client)
        {
            return;
        }
        if (!int.TryParse(MemoryChannelEntryBox.Text.Trim(), out var channel) || channel is < MinMemoryChannel or > MaxMemoryChannel)
        {
            StatusText.Text = $"Enter a memory channel from {MinMemoryChannel} to {MaxMemoryChannel}.";
            return;
        }
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        // No optimistic channel number: the rig ignores a set to a blank
        // channel, so the next poll's read-back is the only true value
        // (the Mac dropped its optimistic value for the same reason).
        try
        {
            await client.SetMemoryChannelAsync(channel);
            MemoryChannelEntryBox.Text = "";
            StatusText.Text = "";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set memory channel failed: {ex.Message}";
        }
    }

    private async void MemoryChannelUpButton_Click(object sender, RoutedEventArgs e) => await StepMemoryChannelAsync(up: true);

    private async void MemoryChannelDownButton_Click(object sender, RoutedEventArgs e) => await StepMemoryChannelAsync(up: false);

    /// The rig resolves what up/down means ("CH"; its wrap and blank-channel
    /// behavior aren't confirmed yet), so nothing is shown until the next
    /// poll reads the channel back — a guessed ±1 could be a blank channel
    /// the rig skipped.
    private async Task StepMemoryChannelAsync(bool up)
    {
        if (_client is not { } client)
        {
            return;
        }
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        try
        {
            await client.StepMemoryChannelAsync(up);
            StatusText.Text = "";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Memory channel step failed: {ex.Message}";
        }
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

    // Audio (Pi :8532)

    /// Starts the session's audio source and playback together: the Pi's
    /// :8532 stream in Remote mode, the chosen input device in Local mode.
    /// Runs only while the rig link is up — each source has its own retry
    /// loop, but its lifetime follows Connect/Disconnect, the Audio switch
    /// and (Local) the Audio in picker.
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
            _mainPlayer.Push(swapped ? right : left);
            _subPlayer.Push(swapped ? left : right);
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
                _audioSetupError = "Choose the radio's audio input under \"Audio in\".";
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
                _audioSetupError = $"\"{AppSettings.LocalAudioDeviceName}\" isn't available — is the radio plugged in and on? Pick it again under \"Audio in\" once it is.";
                UpdateAudioStatus();
                return;
            }
        }

        _audioSource = source;
        StartPlayback();
        source.Start();
        _audioStatusTimer.Start();
        UpdateAudioStatus();
    }

    /// (Re)starts playback for the running source on the device chosen under
    /// "Out". In Local mode, first applies the feedback guard: playing to
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
                ? "Windows' default output is the radio's own USB audio, which would feed its transmit input — pick your speakers under \"Out\" (or as Windows' default; Windows switches to the radio's audio when it's plugged in). Playback starts by itself once the default changes"
                : "the output chosen under \"Out\" is the radio's own USB audio, which would feed its transmit input — pick your speakers there";
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

    private void AudioOutputComboBox_DropDownOpened(object sender, object e) => RefreshAudioOutputs();

    /// "Windows default" first, then the active output devices. A saved
    /// device that isn't plugged in stays listed, marked, like Audio in.
    private void RefreshAudioOutputs()
    {
        _suppressAudioOutputEvents = true;
        var savedId = AppSettings.AudioOutputDeviceId;
        AudioOutputComboBox.Items.Clear();
        var defaultItem = new ComboBoxItem { Content = "Windows default", Tag = "" };
        AudioOutputComboBox.Items.Add(defaultItem);
        ComboBoxItem selected = defaultItem;
        foreach (var (id, name) in AudioPlayback.ListOutputDevices())
        {
            var item = new ComboBoxItem { Content = name, Tag = id };
            AudioOutputComboBox.Items.Add(item);
            if (id == savedId)
            {
                selected = item;
            }
        }
        if (savedId.Length > 0 && ReferenceEquals(selected, defaultItem))
        {
            selected = new ComboBoxItem { Content = $"{AppSettings.AudioOutputDeviceName} (not connected)", Tag = savedId };
            AudioOutputComboBox.Items.Add(selected);
        }
        AudioOutputComboBox.SelectedItem = selected;
        _suppressAudioOutputEvents = false;
    }

    /// Takes effect at once: only playback restarts, the audio source keeps
    /// running.
    private void AudioOutputComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressAudioOutputEvents || AudioOutputComboBox.SelectedItem is not ComboBoxItem { Tag: string id } item)
        {
            return;
        }
        if (id == AppSettings.AudioOutputDeviceId)
        {
            return;
        }
        AppSettings.SetAudioOutputDevice(id, id.Length == 0 ? "" : (string)item.Content);
        StartPlayback();
        UpdateAudioStatus();
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
        _playback.Stop();
        _playbackError = null;
        _playbackNote = null;
        _audioSetupError = null;
        UpdateAudioStatus();
    }

    private void AudioInputComboBox_DropDownOpened(object sender, object e) => RefreshAudioInputs();

    /// Lists the active recording devices. A saved device that isn't
    /// plugged in stays listed (marked) so the selection isn't silently
    /// lost. With nothing saved yet, pre-selects the only "USB Audio"
    /// input if there's exactly one — the FTX-1's codec's usual name.
    private void RefreshAudioInputs()
    {
        _suppressAudioInputEvents = true;
        var devices = LocalAudioCapture.ListDevices();
        var savedId = AppSettings.LocalAudioDeviceId;
        AudioInputComboBox.Items.Clear();
        ComboBoxItem? selected = null;
        foreach (var (id, name) in devices)
        {
            var item = new ComboBoxItem { Content = name, Tag = id };
            AudioInputComboBox.Items.Add(item);
            if (id == savedId)
            {
                selected = item;
            }
        }
        if (selected is null && savedId.Length > 0)
        {
            selected = new ComboBoxItem { Content = $"{AppSettings.LocalAudioDeviceName} (not connected)", Tag = savedId };
            AudioInputComboBox.Items.Add(selected);
        }
        if (selected is null && savedId.Length == 0)
        {
            var usb = devices.Where(d => d.Name.Contains("USB Audio", StringComparison.OrdinalIgnoreCase)).ToList();
            if (usb.Count == 1)
            {
                AppSettings.SetLocalAudioDevice(usb[0].Id, usb[0].Name);
                selected = AudioInputComboBox.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == usb[0].Id);
            }
        }
        AudioInputComboBox.SelectedItem = selected;
        _suppressAudioInputEvents = false;
    }

    private async void AudioInputComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressAudioInputEvents || AudioInputComboBox.SelectedItem is not ComboBoxItem { Tag: string id } item)
        {
            return;
        }
        if (id == AppSettings.LocalAudioDeviceId)
        {
            return;
        }
        AppSettings.SetLocalAudioDevice(id, (string)item.Content);
        if (IsConnected && _connectedMode == ConnectionMode.Local && AudioSwitch.IsOn)
        {
            await StopAudioAsync();
            StartAudio();
        }
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
}

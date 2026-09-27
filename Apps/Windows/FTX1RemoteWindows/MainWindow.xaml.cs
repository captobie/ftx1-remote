using System.Diagnostics;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.Storage.Pickers;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows;

/// v1 core-rig-control window: VFO A/B, mode, PTT, power, SWR, band — see
/// Apps/Windows/README.md's "v1 scope" — plus Main/Sub audio playback from
/// the Pi's :8532 stream. No MENU grid / Deep Settings / waterfall / APRS
/// here yet, all deliberately deferred.
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

    private RigState _lastState = new();

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
    private const int SlowPollEvery = 5;
    private bool _pollInFlight;

    public MainWindow()
    {
        InitializeComponent();

        PiHostBox.Text = AppSettings.PiHost;
        RigctldPathBox.Text = AppSettings.RigctldPath;
        ComPortComboBox.Text = AppSettings.ComPort;
        RefreshComPorts();
        RefreshAudioInputs();
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

        _pollTimer = DispatcherQueue.CreateTimer();
        _pollTimer.Interval = TimeSpan.FromSeconds(1);
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
            _audioChannelsSwapped = _swapTracker.Swapped;
            AppSettings.AudioChannelsSwapped = _swapTracker.Swapped;
            AudioSwapToggle.IsChecked = _swapTracker.Swapped;
            UpdateAudioSwapTooltip();
            Debug.WriteLine($"audio-routing: swapped={_swapTracker.Swapped} ({reason}) main {_lastState.FrequencyHz} sub {_lastState.SecondaryFrequencyHz}");
        };

        var mainAudio = AppSettings.MainAudio;
        var subAudio = AppSettings.SubAudio;
        _mainPlayer = new ChannelPlayer((float)mainAudio.Volume, (float)mainAudio.SquelchThreshold, mainAudio.Muted);
        _subPlayer = new ChannelPlayer((float)subAudio.Volume, (float)subAudio.SquelchThreshold, subAudio.Muted);
        _playback = new AudioPlayback(_mainPlayer, _subPlayer);

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
        _audioStatusTimer.Tick += (_, _) => UpdateAudioStatus();

        // Don't leave a rigctld we spawned running after the window closes
        // (an adopted one is left alone — see RigctldProcessController).
        Closed += (_, _) =>
        {
            _pollTimer.Stop();
            _audioStatusTimer.Stop();
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
        var typed = ComPortComboBox.Text;
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
            Debug.WriteLine($"COM port enumeration failed: {ex.Message}");
        }
        ports.Sort((a, b) => ComPortNumber(a).CompareTo(ComPortNumber(b)));

        ComPortComboBox.Items.Clear();
        foreach (var port in ports.Distinct())
        {
            ComPortComboBox.Items.Add(port);
        }
        ComPortComboBox.Text = typed;
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
            AppSettings.ComPort = ComPortComboBox.Text.Trim().ToUpperInvariant();
            if (BaudRateComboBox.SelectedItem is ComboBoxItem { Tag: int baud })
            {
                AppSettings.BaudRate = baud;
            }
            RigctldPathBox.Text = AppSettings.RigctldPath;
            ComPortComboBox.Text = AppSettings.ComPort;
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
            ConnectionStateText.Text = $"Connected to {description}";
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
        _pollTimer.Stop();
        await StopAudioAsync();
        var client = _client;
        _client = null;
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
        if (_client is not { } client || _pollInFlight)
        {
            return;
        }
        // Over Tailscale a poll can outlast the 1 s tick; overlapping polls
        // would interleave their reads and confuse swap tracking.
        _pollInFlight = true;
        try
        {
            await PollFieldsAsync(client);
        }
        finally
        {
            _pollInFlight = false;
        }
    }

    private async Task PollFieldsAsync(RigctldClient client)
    {
        var generationAtStart = _commandGeneration;
        long? polledMain = null;
        long? polledSub = null;
        int? vfoMemoryRaw = null;

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
            Debug.WriteLine($"poll: getFrequency failed: {ex.Message}");
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
            Debug.WriteLine($"poll: getSecondaryFrequency failed: {ex.Message}");
        }

        // "VM0": 0 = VFO mode, 11 = Memory mode (RigState.swift's
        // VFOMemoryMode). Only needed for swap tracking here.
        try
        {
            vfoMemoryRaw = await client.GetRawIntAsync("VM0");
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: VM0 failed: {ex.Message}");
        }

        if (_pollCount++ % SlowPollEvery == 0)
        {
            try
            {
                if (await client.GetRawIntAsync("FR") is { } fr)
                {
                    var single = fr == 1;
                    if (single != _singleReceive)
                    {
                        Debug.WriteLine($"audio-routing: FR reply {fr} — {(single ? "single" : "dual")} receive");
                    }
                    _singleReceive = single;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"poll: FR failed: {ex.Message}");
            }
        }

        if (polledMain is { } main && generationAtStart == _commandGeneration)
        {
            // A failed VM0 read counts as "not VFO mode" (drops the
            // baseline), same as the Mac.
            _swapTracker.OnPoll(main, polledSub, inVfoMode: vfoMemoryRaw == 0);
        }

        try
        {
            var mode = await client.GetModeAsync();
            _lastState.Mode = mode;
            SetComboSelection(ModeComboBox, mode?.DisplayName());
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getMode failed: {ex.Message}");
        }

        try
        {
            var ptt = await client.GetPttAsync();
            _lastState.Ptt = ptt;
            PttToggle.IsChecked = ptt;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getPtt failed: {ex.Message}");
        }

        try
        {
            var level = await client.GetLevelAsync("RFPOWER");
            if (level is { } l)
            {
                _lastState.PowerLevel = l;
                PowerSlider.Value = l * 100;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getLevel(RFPOWER) failed: {ex.Message}");
        }

        try
        {
            var watts = await client.GetLevelAsync("RFPOWER_METER_WATTS");
            if (watts is { } w)
            {
                _lastState.PowerWatts = w;
                PowerWattsText.Text = $"{w:F1} W";
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getLevel(RFPOWER_METER_WATTS) failed: {ex.Message}");
        }

        try
        {
            var swr = await client.GetLevelAsync("SWR");
            if (swr is { } s)
            {
                _lastState.Swr = s;
                SwrText.Text = $"{s:F2}";
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getLevel(SWR) failed: {ex.Message}");
        }
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
        _commandGeneration++;
        _swapTracker.ResetBaseline();
        try
        {
            await _client.SetFrequencyAsync(hz);
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
        try
        {
            await _client.SwapActiveVfoAsync();
            _swapTracker.OnAppSwap(_singleReceive, _lastState.FrequencyHz, _lastState.SecondaryFrequencyHz);
            if (_singleReceive == true)
            {
                Debug.WriteLine($"audio-routing: app swap in single-receive display — audio channels left as is (swapped={_swapTracker.Swapped})");
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
        }
    }

    private void AudioSwapToggle_Click(object sender, RoutedEventArgs e)
    {
        _swapTracker.Toggle();
        AudioSwapToggle.IsChecked = _swapTracker.Swapped;
    }

    private void UpdateAudioSwapTooltip()
    {
        ToolTipService.SetToolTip(AudioSwapToggle, _swapTracker.Swapped
            ? "Audio channels are swapped relative to the rig's default (L=Main, R=Sub). Click to swap back."
            : "Swap which audio channel plays as Main and Sub — use if the audio doesn't match the VFO it's under.");
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

    private async void PttToggle_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        try
        {
            await _client.SetPttAsync(PttToggle.IsChecked == true);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Set PTT failed: {ex.Message}";
        }
    }

    private async void PowerSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_client is null)
        {
            return;
        }
        try
        {
            await _client.SetPowerLevelAsync(e.NewValue / 100.0);
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
        var playbackAllowed = true;
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
                Debug.WriteLine($"local-audio: can't open {deviceId}: {ex.Message}");
                _audioSetupError = $"\"{AppSettings.LocalAudioDeviceName}\" isn't available — is the radio plugged in and on? Pick it again under \"Audio in\" once it is.";
                UpdateAudioStatus();
                return;
            }
            // Playing to the radio's own USB codec would feed its TX audio
            // input (and with VOX or DATA-mode keying, could transmit it).
            if (LocalAudioCapture.DefaultOutputIsSameAdapter(deviceId))
            {
                playbackAllowed = false;
                _playbackError = "Windows' default output is the radio's own USB audio, which would feed its transmit input — pick your speakers as the default output device";
            }
        }

        if (playbackAllowed)
        {
            _playbackError = _playback.Start(source.SampleRate);
        }
        _audioSource = source;
        source.Start();
        _audioStatusTimer.Start();
        UpdateAudioStatus();
    }

    private async Task StopAudioAsync()
    {
        var source = _audioSource;
        _audioSource = null;
        _audioStatusTimer.Stop();
        if (source is not null)
        {
            await source.StopAsync();
        }
        _playback.Stop();
        _playbackError = null;
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

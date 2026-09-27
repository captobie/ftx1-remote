using System.Diagnostics;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.Storage.Pickers;

namespace FTX1RemoteWindows;

/// v1 core-rig-control window: VFO A/B, mode, PTT, power, SWR, band — see
/// Apps/Windows/README.md's "v1 scope". No MENU grid / Deep Settings /
/// waterfall / APRS here yet, all deliberately deferred.
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

    public MainWindow()
    {
        InitializeComponent();

        PiHostBox.Text = AppSettings.PiHost;
        RigctldPathBox.Text = AppSettings.RigctldPath;
        ComPortComboBox.Text = AppSettings.ComPort;
        RefreshComPorts();
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

        // Don't leave a rigctld we spawned running after the window closes
        // (an adopted one is left alone — see RigctldProcessController).
        Closed += (_, _) =>
        {
            _pollTimer.Stop();
            _client?.Disconnect();
            _client = null;
            _rigctldProcess.Stop();
        };
    }

    private bool IsConnected => _client is not null;

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
            _pollTimer.Start();
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
        throw new RigctldError(WithStderr(connected
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
        if (_client is not { } client)
        {
            return;
        }

        try
        {
            var hz = await client.GetFrequencyAsync();
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
            _lastState.SecondaryFrequencyHz = hz;
            FrequencyBText.Text = FormatHz(hz);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"poll: getSecondaryFrequency failed: {ex.Message}");
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
        try
        {
            await _client.SwapActiveVfoAsync();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Swap VFO failed: {ex.Message}";
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
}

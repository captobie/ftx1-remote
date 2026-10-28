using System.Diagnostics;
using System.Globalization;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Hub;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace FTX1RemoteWindows;

/// Settings (parity plan step 7), the Mac's SettingsView tab layout: the
/// connection settings, audio devices and WPSD hotspot that used to sit in
/// the main window, plus the HOME frequencies, polling rates and
/// appearance that were fixed until now.
///
/// Nothing is written until Save; MainWindow then applies whatever
/// changed (see the *Changed properties). The rigctld tab is read-only
/// while connected, as the main-window fields were: a mode or port change
/// mid-session would describe a connection that isn't the one in use.
///
/// A window of its own, modal to the main window (as the ContentDialog it
/// used to be was) but resizable: a ContentDialog can't be resized and is
/// capped by its owner's size, which clipped the wider tabs.
public sealed partial class SettingsDialog : Window
{
    private static readonly int[] BaudRates = [4800, 9600, 19200, 38400, 57600, 115200];

    /// Wide enough for the whole tab bar and the logbook rows.
    private const int MinimumWidth = 860;
    private const int MinimumHeight = 560;

    private readonly Window _owner;
    private readonly TaskCompletionSource<bool> _result = new();
    private bool _saved;
    private readonly List<(HomeBand Band, TextBox Box)> _homeFields = [];

    public bool AudioInputChanged { get; private set; }
    public bool AudioOutputChanged { get; private set; }
    public bool WpsdHostChanged { get; private set; }
    /// Ticked "Clear History" on the APRS tab; applied on Save, like
    /// everything else here.
    public bool AprsClearHistory { get; private set; }

    /// `inUse`: what this session's last Local start launched
    /// (RigctldProcessController.LastResolution), shown when it differs
    /// from what the edited choice resolves to.
    /// `hubAudioRunning`: whether this app's audio is on, which the iPad's
    /// receive audio comes through (Settings → Mobile says so when it isn't).
    /// `wavelogReporter`/`wavelogTuner`: the running Wavelog CAT pieces,
    /// for the Logbook tab's live status lines.
    public SettingsDialog(Window owner, bool connected, RigctldBinary.Resolution? inUse = null, HubServer? hub = null,
        bool hubAudioRunning = true, WavelogRadioReporter? wavelogReporter = null, WavelogTuneListener? wavelogTuner = null,
        long transmitterHz = 0)
    {
        _owner = owner;
        _transmitterHz = transmitterHz;
        _inUse = inUse;
        _hub = hub;
        _hubAudioRunning = hubAudioRunning;
        _wavelogReporter = wavelogReporter;
        _wavelogTuner = wavelogTuner;
        InitializeComponent();
        ThemeEngine.ApplyTo(RootGrid);
        RootGrid.Background = ThemeEngine.WindowBackground;
        ConfigureWindow();

        // rigctld
        ConnectedNote.Visibility = connected ? Visibility.Visible : Visibility.Collapsed;
        foreach (var control in new Control[]
                 {
                     ConnectionModeComboBox, PiHostBox, RigctldChoiceComboBox,
                     ModelNumberBox, ComPortComboBox, BaudRateComboBox,
                 })
        {
            control.IsEnabled = !connected;
        }
        ConnectionModeComboBox.SelectedIndex = AppSettings.ConnectionMode == ConnectionMode.Local ? 1 : 0;
        PiHostBox.Text = AppSettings.PiHost;
        GridSquareBox.Text = AppSettings.GridSquare;
        CallsignBox.Text = AppSettings.Callsign;
        FillRigctldChoices(AppSettings.RigctldChoice);
        ModelNumberBox.Value = AppSettings.ModelNumber;
        RefreshComPorts();
        // Not directly: WinUI 3's editable ComboBox drops a selection's text
        // set before its template is applied (see ShowComPort).
        ComPortComboBox.Loaded += (_, _) => ShowComPort(AppSettings.ComPort);
        // A rate set by hand in settings.json stays listed, like the Mac's
        // baudRateOptionsIncludingCurrent.
        foreach (var rate in BaudRates.Append(AppSettings.BaudRate).Distinct().Order())
        {
            BaudRateComboBox.Items.Add(new ComboBoxItem { Content = rate.ToString(), Tag = rate });
        }
        BaudRateComboBox.SelectedItem = BaudRateComboBox.Items.OfType<ComboBoxItem>()
            .First(i => (int)i.Tag == AppSettings.BaudRate);
        UpdateModePanels();
        PiHostBox.TextChanged += (_, _) => RefreshVersions();
        // The choice box refreshes from its SelectionChanged handler.
        ModelNumberBox.ValueChanged += (_, _) => RefreshVersions();
        Opened += () =>
        {
            _isOpen = true;
            if (_hub is not null)
            {
                _hub.StatusChanged += OnHubStatusChanged;
            }
            RefreshHubStatus();
            StartHubProbe();
            RefreshVersions();
            RefreshHrdStatus();
            RefreshLog4OmStatus();
            if (_wavelogReporter is not null)
            {
                _wavelogReporter.Changed += OnWavelogStatusChanged;
            }
            if (_wavelogTuner is not null)
            {
                _wavelogTuner.Changed += OnWavelogStatusChanged;
            }
            UpdateWavelogPanels();
            AutoRefreshWavelogStations();
        };
        Closed += (_, _) =>
        {
            _isOpen = false;
            if (_hub is not null)
            {
                _hub.StatusChanged -= OnHubStatusChanged;
            }
            _hubProbeTimer?.Stop();
            _versionLookup?.Cancel();
            if (_wavelogReporter is not null)
            {
                _wavelogReporter.Changed -= OnWavelogStatusChanged;
            }
            if (_wavelogTuner is not null)
            {
                _wavelogTuner.Changed -= OnWavelogStatusChanged;
            }
            ReleaseOwner();
            _result.TrySetResult(_saved);
        };

        // Audio
        RefreshAudioInputs();
        RefreshAudioOutputs();
        RefreshTxAudioOutputs();

        // C4FM
        WpsdEnabledCheckBox.IsChecked = AppSettings.WpsdEnabled;
        WpsdHostBox.Text = AppSettings.WpsdHost;

        // APRS
        AprsEnabledCheckBox.IsChecked = AppSettings.AprsEnabled;
        AprsFrequencyBox.Text = FormatMHz(AppSettings.AprsFrequencyHz);
        ConfigureNumberBox(AprsToleranceBox, AppSettings.AprsToleranceHzSetting, AppSettings.AprsToleranceHz);
        ConfigureNumberBox(AprsMaxStationsBox, AppSettings.AprsMaxStationsSetting, AppSettings.AprsMaxStations);
        ConfigureNumberBox(AprsMaxMessagesBox, AppSettings.AprsMaxMessagesSetting, AppSettings.AprsMaxMessages);

        // Logbook
        LogbookComboBox.SelectedItem = LogbookComboBox.Items.OfType<ComboBoxItem>()
            .First(i => (string)i.Tag == AppSettings.Logbook.ToString());
        HrdLogPathBox.Text = AppSettings.HrdLogPath;
        InitWavelog();
        HrdHostBox.Text = AppSettings.HrdUdpHost;
        HrdPortBox.Value = AppSettings.HrdUdpPort > 0 ? AppSettings.HrdUdpPort : double.NaN;
        Log4OmLogPathBox.Text = AppSettings.Log4OmLogPath;
        Log4OmHostBox.Text = AppSettings.Log4OmUdpHost;
        Log4OmPortBox.Value = AppSettings.Log4OmUdpPort > 0 ? AppSettings.Log4OmUdpPort : double.NaN;
        UpdateLogbookPanel();

        // License
        InitLicense();

        // Home Freq
        foreach (var band in HomeBand.All)
        {
            var box = new TextBox
            {
                Header = $"{band.Name} (MHz)",
                Width = 200,
                HorizontalAlignment = HorizontalAlignment.Left,
                Text = FormatMHz(AppSettings.HomeFrequencyHz(band)),
                PlaceholderText = FormatMHz(band.FrequencyHz),
            };
            ToolTipService.SetToolTip(box, Loc.F("settings.xXMHzFactory", FormatMHz(band.LowHz), FormatMHz(band.HighHz), FormatMHz(band.FrequencyHz)));
            _homeFields.Add((band, box));
            HomeFieldsPanel.Children.Add(box);
        }

        // Polling
        ConfigureNumberBox(PollIntervalBox, AppSettings.PollIntervalMsSetting, AppSettings.PollIntervalMs);
        ConfigureNumberBox(SlowPollEveryBox, AppSettings.SlowPollEverySetting, AppSettings.SlowPollEvery);
        ConfigureNumberBox(WpsdCallerBox, AppSettings.WpsdCallerSecondsSetting, AppSettings.WpsdCallerSeconds);
        ConfigureNumberBox(WpsdReflectorBox, AppSettings.WpsdReflectorSecondsSetting, AppSettings.WpsdReflectorSeconds);

        // Appearance
        foreach (var name in ThemePresets.Names)
        {
            ThemeComboBox.Items.Add(new ComboBoxItem { Content = ThemePresets.DisplayName(name), Tag = name });
        }
        ThemeComboBox.SelectedIndex = Math.Max(0, ThemePresets.Names.ToList().IndexOf(AppSettings.ThemeName));
        VfoDigitFontComboBox.Items.Add(new ComboBoxItem { Content = Loc.S("settings.themeDefault"), Tag = null });
        foreach (var font in Enum.GetValues<VfoDigitFont>())
        {
            VfoDigitFontComboBox.Items.Add(new ComboBoxItem { Content = font.DisplayName(), Tag = font });
        }
        VfoDigitFontComboBox.SelectedIndex = AppSettings.VfoDigitFont is { } digitFont ? (int)digitFont + 1 : 0;
        VfoDigitColorComboBox.Items.Add(new ComboBoxItem { Content = Loc.S("settings.themeDefault"), Tag = null });
        foreach (var color in Enum.GetValues<ButtonValueColor>())
        {
            VfoDigitColorComboBox.Items.Add(new ComboBoxItem { Content = color.DisplayName(), Tag = color });
        }
        VfoDigitColorComboBox.SelectedIndex = AppSettings.VfoDigitColor is { } digitColor ? (int)digitColor + 1 : 0;
        foreach (var color in Enum.GetValues<ButtonValueColor>())
        {
            ButtonValueColorComboBox.Items.Add(new ComboBoxItem { Content = color.DisplayName(), Tag = color });
        }
        ButtonValueColorComboBox.SelectedIndex = (int)AppSettings.ButtonValueColor;

        // About
        VersionText.Text = Loc.F("settings.versionX", UpdateChecker.CurrentVersionText);
        CheckAtLaunchCheckBox.IsChecked = AppSettings.CheckForUpdatesAtLaunch;

        // Hub
        HubEnabledSwitch.IsOn = AppSettings.HubEnabled;
    }

    /// Raised once the window is shown (the ContentDialog's Opened).
    private event Action? Opened;

    /// Shows the window modal to the owner; true when it closed with Save.
    public Task<bool> ShowAsync()
    {
        Activate();
        // Modal the Win32 way: OverlappedPresenter.IsModal left the main
        // window usable (checked with IsWindowEnabled).
        EnableWindow(OwnerHandle, false);
        Opened?.Invoke();
        return _result.Task;
    }

    private IntPtr OwnerHandle => WinRT.Interop.WindowNative.GetWindowHandle(_owner);

    /// Re-enables the owner before this window goes away, so Windows hands
    /// the focus back to it rather than to some other app.
    private void ReleaseOwner() => EnableWindow(OwnerHandle, true);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool EnableWindow(IntPtr hwnd, bool enable);

    private const int GwlpHwndParent = -8;

    /// Owned by the main window (stays above it), resizable, centered on it.
    private void ConfigureWindow()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        SetWindowLongPtr(hwnd, GwlpHwndParent, OwnerHandle);
        // The title bar's close button: Window.Close() from Save/Cancel
        // doesn't raise this, so those release the owner themselves.
        AppWindow.Closing += (_, _) => ReleaseOwner();
        var scale = GetDpiForWindow(hwnd) / 96.0;
        var presenter = OverlappedPresenter.CreateForDialog();
        presenter.IsResizable = true;
        presenter.IsMaximizable = true;
        presenter.IsMinimizable = false;
        presenter.PreferredMinimumWidth = (int)(MinimumWidth * scale);
        presenter.PreferredMinimumHeight = (int)(MinimumHeight * scale);
        AppWindow.SetPresenter(presenter);

        var width = (int)(MinimumWidth * scale);
        var height = (int)(680 * scale);
        var owner = _owner.AppWindow;
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(
            owner.Position.X + Math.Max(0, (owner.Size.Width - width) / 2),
            owner.Position.Y + Math.Max(0, (owner.Size.Height - height) / 2),
            width,
            height));
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        ReleaseOwner();
        Close();
    }

    private void TabBar_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        ShowTab(sender.SelectedItem?.Tag as string ?? "Rigctld");
    }

    private void ShowTab(string tag)
    {
        var tabs = new (string Tag, UIElement Panel)[]
        {
            ("Rigctld", RigctldTab), ("Audio", AudioTab), ("C4fm", C4fmTab), ("Aprs", AprsTab),
            ("Station", StationTab), ("Logbook", LogbookTab), ("License", LicenseTab), ("Home", HomeTab), ("Polling", PollingTab), ("Appearance", AppearanceTab),
            ("Hub", HubTab), ("About", AboutTab),
        };
        foreach (var (t, panel) in tabs)
        {
            panel.Visibility = t == tag ? Visibility.Visible : Visibility.Collapsed;
        }
        var item = TabBar.Items.FirstOrDefault(i => (string)i.Tag == tag);
        if (item is not null && !ReferenceEquals(TabBar.SelectedItem, item))
        {
            TabBar.SelectedItem = item;
        }
        if (tag == "Hub")
        {
            ProbeHubNetwork();
        }
    }

    // Save.

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (Validate())
        {
            _saved = true;
            ReleaseOwner();
            Close();
        }
    }

    /// Checks every field and, only if all are valid, writes them; false
    /// leaves the window open with the error shown.
    private bool Validate()
    {
        // Validate everything before writing anything, so a bad field
        // leaves every setting as it was.
        var homeFrequencies = new List<(HomeBand, long)>();
        foreach (var (band, box) in _homeFields)
        {
            var text = box.Text.Trim();
            if (text.Length == 0)
            {
                homeFrequencies.Add((band, band.FrequencyHz));
                continue;
            }
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var mhz)
                && !double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out mhz))
            {
                Fail("Home", Loc.F("settings.homeXIsntAFrequency", band.Name, text));
                return false;
            }
            var hz = (long)Math.Round(mhz * 1_000_000);
            if (hz < band.LowHz || hz > band.HighHz)
            {
                Fail("Home", Loc.F("settings.homeXOutsideBandGroup", band.Name, FormatMHz(hz), FormatMHz(band.LowHz), FormatMHz(band.HighHz)));
                return false;
            }
            homeFrequencies.Add((band, hz));
        }

        var aprsFrequencyText = AprsFrequencyBox.Text.Trim();
        long aprsFrequencyHz = AppSettings.DefaultAprsFrequencyHz;
        if (aprsFrequencyText.Length > 0)
        {
            if (!double.TryParse(aprsFrequencyText, NumberStyles.Float, CultureInfo.InvariantCulture, out var aprsMhz)
                && !double.TryParse(aprsFrequencyText, NumberStyles.Float, CultureInfo.CurrentCulture, out aprsMhz))
            {
                Fail("Aprs", Loc.F("settings.aprsXIsntAFrequency", aprsFrequencyText));
                return false;
            }
            aprsFrequencyHz = (long)Math.Round(aprsMhz * 1_000_000);
            if (aprsFrequencyHz <= 0)
            {
                Fail("Aprs", Loc.S("settings.aprsFrequencyAboveZero"));
                return false;
            }
        }

        if (LicenseProblem() is { } licenseProblem)
        {
            Fail("License", licenseProblem);
            return false;
        }

        var gridSquare = GridSquareBox.Text.Trim();
        if (gridSquare.Length > 0 && Maidenhead.Coordinates(gridSquare) is null)
        {
            Fail("Station", Loc.F("settings.xIsntAMaidenheadGrid", gridSquare));
            return false;
        }

        var hrdHost = HrdHostBox.Text.Trim();
        var log4OmHost = Log4OmHostBox.Text.Trim();
        foreach (var host in new[] { hrdHost, log4OmHost })
        {
            if (host.Contains(' ') || host.Contains('/'))
            {
                Fail("Logbook", Loc.F("settings.xIsntAHostName", host));
                return false;
            }
        }

        var wavelogUrl = WavelogUrlBox.Text.Trim();
        if (wavelogUrl.Length > 0 && Wavelog.ApiUrl(wavelogUrl, "qso") is null)
        {
            Fail("Logbook", Loc.F("settings.xIsntAWavelogUrl", wavelogUrl));
            return false;
        }

        if (ConnectionModeComboBox.IsEnabled)
        {
            AppSettings.ConnectionMode = SelectedMode;
            AppSettings.PiHost = PiHostBox.Text.Trim();
            AppSettings.RigctldChoice = SelectedRigctldChoice;
            if (!double.IsNaN(ModelNumberBox.Value))
            {
                AppSettings.ModelNumber = (int)ModelNumberBox.Value;
            }
            AppSettings.ComPort = CurrentComPort().ToUpperInvariant();
            if (BaudRateComboBox.SelectedItem is ComboBoxItem { Tag: int baud })
            {
                AppSettings.BaudRate = baud;
            }
        }

        if (AudioInputComboBox.SelectedItem is ComboBoxItem { Tag: string inputId } input
            && inputId != AppSettings.LocalAudioDeviceId)
        {
            AppSettings.SetLocalAudioDevice(inputId, (string)input.Content);
            AudioInputChanged = true;
        }
        if (AudioOutputComboBox.SelectedItem is ComboBoxItem { Tag: string outputId } output
            && outputId != AppSettings.AudioOutputDeviceId)
        {
            AppSettings.SetAudioOutputDevice(outputId, outputId.Length == 0 ? "" : (string)output.Content);
            AudioOutputChanged = true;
        }
        if (TxAudioOutputComboBox.SelectedItem is ComboBoxItem { Tag: string txOutputId } txOutput
            && txOutputId != AppSettings.TxAudioOutputDeviceId)
        {
            // Read on each transmission's first frame, so no restart needed.
            AppSettings.SetTxAudioOutputDevice(txOutputId, txOutputId.Length == 0 ? "" : (string)txOutput.Content);
        }

        AppSettings.WpsdEnabled = WpsdEnabledCheckBox.IsChecked == true;
        var wpsdHost = NormalizeWpsdHost(WpsdHostBox.Text);
        if (wpsdHost != AppSettings.WpsdHost)
        {
            AppSettings.WpsdHost = wpsdHost;
            WpsdHostChanged = true;
        }

        // Stored as the operator writes it (FN31pr); Maidenhead parsing
        // ignores case.
        AppSettings.GridSquare = gridSquare;
        AppSettings.Callsign = CallsignBox.Text.Trim().ToUpperInvariant();

        AppSettings.Logbook = SelectedLogbook;
        AppSettings.HrdLogPath = HrdLogPathBox.Text.Trim().Trim('"');
        AppSettings.HrdUdpHost = hrdHost;
        AppSettings.HrdUdpPort = double.IsNaN(HrdPortBox.Value) ? 0 : (int)Math.Round(HrdPortBox.Value);
        AppSettings.Log4OmLogPath = Log4OmLogPathBox.Text.Trim().Trim('"');
        AppSettings.Log4OmUdpHost = log4OmHost;
        AppSettings.Log4OmUdpPort = double.IsNaN(Log4OmPortBox.Value) ? 0 : (int)Math.Round(Log4OmPortBox.Value);
        SaveWavelog(wavelogUrl);

        SaveLicense();

        AppSettings.AprsEnabled = AprsEnabledCheckBox.IsChecked == true;
        AppSettings.AprsFrequencyHz = aprsFrequencyHz;
        AppSettings.AprsToleranceHz = NumberBoxValue(AprsToleranceBox, AppSettings.AprsToleranceHzSetting);
        AppSettings.AprsMaxStations = NumberBoxValue(AprsMaxStationsBox, AppSettings.AprsMaxStationsSetting);
        AppSettings.AprsMaxMessages = NumberBoxValue(AprsMaxMessagesBox, AppSettings.AprsMaxMessagesSetting);

        foreach (var (band, hz) in homeFrequencies)
        {
            AppSettings.SetHomeFrequencyHz(band, hz);
        }

        AppSettings.PollIntervalMs = NumberBoxValue(PollIntervalBox, AppSettings.PollIntervalMsSetting);
        AppSettings.SlowPollEvery = NumberBoxValue(SlowPollEveryBox, AppSettings.SlowPollEverySetting);
        AppSettings.WpsdCallerSeconds = NumberBoxValue(WpsdCallerBox, AppSettings.WpsdCallerSecondsSetting);
        AppSettings.WpsdReflectorSeconds = NumberBoxValue(WpsdReflectorBox, AppSettings.WpsdReflectorSecondsSetting);

        AppSettings.CheckForUpdatesAtLaunch = CheckAtLaunchCheckBox.IsChecked == true;
        AppSettings.HubEnabled = HubEnabledSwitch.IsOn;

        if (ThemeComboBox.SelectedItem is ComboBoxItem { Tag: string themeName })
        {
            AppSettings.ThemeName = themeName;
        }
        if (VfoDigitFontComboBox.SelectedItem is ComboBoxItem digitFontItem)
        {
            AppSettings.VfoDigitFont = digitFontItem.Tag as VfoDigitFont?;
        }
        if (VfoDigitColorComboBox.SelectedItem is ComboBoxItem digitColorItem)
        {
            AppSettings.VfoDigitColor = digitColorItem.Tag as ButtonValueColor?;
        }
        if (ButtonValueColorComboBox.SelectedItem is ComboBoxItem { Tag: ButtonValueColor color })
        {
            AppSettings.ButtonValueColor = color;
        }
        return true;
    }

    private void Fail(string tab, string message)
    {
        ShowTab(tab);
        ErrorText.Text = message;
    }

    /// Stripped of a pasted "http://" and trailing "/", since the monitor
    /// builds the URL itself.
    private static string NormalizeWpsdHost(string text)
    {
        var host = text.Trim();
        if (host.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            host = host["http://".Length..];
        }
        return host.TrimEnd('/');
    }

    private static string FormatMHz(long hz) =>
        (hz / 1_000_000.0).ToString("0.000###", CultureInfo.InvariantCulture);

    // APRS tab.

    /// Instead of the Mac's confirmation dialog (from when Settings was a
    /// ContentDialog, and couldn't open another) the button arms the clear and Save carries it out
    /// (Cancel still backs out); a second click disarms it.
    private void AprsClearHistoryButton_Click(object sender, RoutedEventArgs e)
    {
        AprsClearHistory = !AprsClearHistory;
        AprsClearHistoryButton.Content = AprsClearHistory ? Loc.S("settings.dontClear") : Loc.S("settings.clearHistory");
        AprsClearNote.Text = AprsClearHistory
            ? Loc.S("settings.everyDecodedStationAnd")
            : "";
    }

    // Logbook tab.

    private LogbookKind SelectedLogbook =>
        LogbookComboBox.SelectedItem is ComboBoxItem { Tag: string tag } && Enum.TryParse<LogbookKind>(tag, out var kind)
            ? kind
            : LogbookKind.None;

    private void LogbookComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateLogbookPanel();
        RefreshHrdStatus();
        RefreshLog4OmStatus();
    }

    private void UpdateLogbookPanel()
    {
        HrdSettingsPanel.Visibility = SelectedLogbook == LogbookKind.HrdLogbook ? Visibility.Visible : Visibility.Collapsed;
        Log4OmSettingsPanel.Visibility = SelectedLogbook == LogbookKind.Log4Om ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void BrowseHrdLogButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".hrdsql");
        picker.FileTypeFilter.Add("*");
        var file = await picker.PickSingleFileAsync();
        if (file is not null)
        {
            HrdLogPathBox.Text = file.Path;
            RefreshHrdStatus();
        }
    }

    private void UseHrdLogButton_Click(object sender, RoutedEventArgs e)
    {
        HrdLogPathBox.Text = "";
        RefreshHrdStatus();
    }

    private void RefreshHrdButton_Click(object sender, RoutedEventArgs e) => RefreshHrdStatus();

    private int _hrdStatusGeneration;

    /// The Mac's "is MacLoggerDX running and listening" card, for HRD:
    /// whether it's running, its ADIF receiver (from its own settings, or
    /// the host/port typed here), and the log's QSO count. Read off the UI
    /// thread: the log can be large and is in (OneDrive) Documents. Shows
    /// HRD's own values as placeholders.
    private async void RefreshHrdStatus()
    {
        if (SelectedLogbook != LogbookKind.HrdLogbook)
        {
            return;
        }
        var generation = ++_hrdStatusGeneration;
        var typedPath = HrdLogPathBox.Text.Trim().Trim('"');
        var typedHost = HrdHostBox.Text.Trim();
        var typedPort = double.IsNaN(HrdPortBox.Value) ? 0 : (int)Math.Round(HrdPortBox.Value);
        HrdRunningText.Text = HrdReceiverText.Text = HrdLogText.Text = Loc.S("settings.checking");
        var status = await Task.Run(() =>
        {
            var receiver = HrdLogbook.Receiver();
            var detectedPath = HrdLogbook.DetectedLogPath();
            var host = typedHost.Length > 0 ? typedHost : receiver?.Address ?? "127.0.0.1";
            var port = typedPort > 0 ? typedPort : receiver?.Port ?? 0;
            string receiving;
            if (port == 0)
            {
                receiving = Loc.S("settings.hRDsADIFReceiverPort");
            }
            else if (typedPort == 0 && receiver is { Enabled: false })
            {
                receiving = Loc.F("settings.offInHRDUDP9", port);
            }
            else if (LogbookPrograms.IsLocalHost(host))
            {
                receiving = LogbookPrograms.IsListening(port)
                    ? Loc.F("settings.listeningOnUDPX", port, host, port)
                    : Loc.F("settings.nothingIsListeningOn", port);
            }
            else
            {
                receiving = Loc.F("settings.qSOsGoToX", host, port);
            }
            var path = typedPath.Length > 0 ? typedPath : detectedPath;
            string log;
            if (path is null)
            {
                log = HrdLogbook.UnreadableDatabaseReason() ?? Loc.S("settings.hRDsLogWasntFound2");
            }
            else
            {
                try
                {
                    var (qsos, stations) = LogbookDatabase.Summary(HrdLogbook.Program, path);
                    log = Loc.F("settings.xQSOsWithX", qsos, stations, path);
                }
                catch (LogbookDatabase.LogException ex)
                {
                    log = $"{ex.Message}\n{path}";
                }
            }
            var running = HrdLogbook.IsRunning ? Loc.S("settings.running") : Loc.S("settings.notRunning");
            return (running, receiving, log, receiver, detectedPath);
        });
        if (generation != _hrdStatusGeneration)
        {
            return;
        }
        HrdRunningText.Text = status.running;
        HrdReceiverText.Text = status.receiving;
        HrdLogText.Text = status.log;
        HrdLogPathBox.PlaceholderText = status.detectedPath ?? Loc.S("settings.hRDsLogWasntFound");
        HrdHostBox.PlaceholderText = status.receiver?.Address ?? "127.0.0.1";
        HrdPortBox.PlaceholderText = status.receiver is { Port: > 0 } r ? r.Port.ToString(CultureInfo.InvariantCulture) : "";
    }

    private async void BrowseLog4OmLogButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".sqlite");
        picker.FileTypeFilter.Add("*");
        var file = await picker.PickSingleFileAsync();
        if (file is not null)
        {
            Log4OmLogPathBox.Text = file.Path;
            RefreshLog4OmStatus();
        }
    }

    private void UseLog4OmLogButton_Click(object sender, RoutedEventArgs e)
    {
        Log4OmLogPathBox.Text = "";
        RefreshLog4OmStatus();
    }

    private void RefreshLog4OmButton_Click(object sender, RoutedEventArgs e) => RefreshLog4OmStatus();

    private int _log4OmStatusGeneration;

    /// HRD's card for Log4OM, plus whether its remote control (the Log
    /// pane's Lookup) answers. Follows the typed fields, unsaved; read off
    /// the UI thread.
    private async void RefreshLog4OmStatus()
    {
        if (SelectedLogbook != LogbookKind.Log4Om)
        {
            return;
        }
        var generation = ++_log4OmStatusGeneration;
        var typedPath = Log4OmLogPathBox.Text.Trim().Trim('"');
        var typedHost = Log4OmHostBox.Text.Trim();
        var typedPort = double.IsNaN(Log4OmPortBox.Value) ? 0 : (int)Math.Round(Log4OmPortBox.Value);
        Log4OmRunningText.Text = Log4OmReceiverText.Text = Log4OmRemoteText.Text = Log4OmLogText.Text = Loc.S("settings.checking");
        var status = await Task.Run(async () =>
        {
            var config = Log4OmLogbook.ReadConfig();
            var detectedPath = Log4OmLogbook.DetectedLogPath();
            var host = typedHost.Length > 0 ? typedHost : "127.0.0.1";
            var local = LogbookPrograms.IsLocalHost(host);
            var adif = config?.Adif;
            var port = typedPort > 0 ? typedPort : adif?.Port ?? 0;
            string receiving;
            if (port == 0)
            {
                receiving = Loc.S("settings.noADIFMESSAGEUDP");
            }
            else if (typedPort == 0 && adif is { Enabled: false })
            {
                receiving = Loc.F("settings.log4OMsXConnectionPort", adif.Name, port);
            }
            else if (local)
            {
                receiving = LogbookPrograms.IsListening(port)
                    ? Loc.F("settings.listeningOnUDPX", port, host, port)
                    : Loc.F("settings.nothingIsListeningOn", port);
            }
            else
            {
                receiving = Loc.F("settings.qSOsGoToX", host, port);
            }

            var remotePort = config?.RemoteControlPort ?? Log4OmLogbook.DefaultRemoteControlPort;
            string remote;
            if (local && config is { RemoteControlEnabled: false })
            {
                remote = Loc.S("settings.log4OMsRemoteControlIs");
            }
            else
            {
                remote = await Log4OmLogbook.AliveAsync(host, remotePort) is { Done: true }
                    ? Loc.F("settings.remoteControlAnsweringOn", host, remotePort)
                    : Loc.F("settings.noAnswerFromRemote", host, remotePort);
            }

            var path = typedPath.Length > 0 ? typedPath : detectedPath;
            string log;
            if (path is null)
            {
                log = Log4OmLogbook.UnreadableDatabaseReason();
            }
            else
            {
                try
                {
                    var (qsos, stations) = LogbookDatabase.Summary(Log4OmLogbook.Program, path);
                    log = Loc.F("settings.xQSOsWithX", qsos, stations, path);
                }
                catch (LogbookDatabase.LogException ex)
                {
                    log = $"{ex.Message}\n{path}";
                }
            }
            var running = Log4OmLogbook.IsRunning ? Loc.S("settings.running") : Loc.S("settings.notRunning");
            return (running, receiving, remote, log, adif, detectedPath);
        });
        if (generation != _log4OmStatusGeneration)
        {
            return;
        }
        Log4OmRunningText.Text = status.running;
        Log4OmReceiverText.Text = status.receiving;
        Log4OmRemoteText.Text = status.remote;
        Log4OmLogText.Text = status.log;
        Log4OmLogPathBox.PlaceholderText = status.detectedPath ?? Loc.S("settings.log4OMsLogWasntFound");
        Log4OmPortBox.PlaceholderText = status.adif is { Port: > 0 } a ? a.Port.ToString(CultureInfo.InvariantCulture) : "";
    }

    // Logbook tab: Wavelog.

    private readonly WavelogRadioReporter? _wavelogReporter;
    private readonly WavelogTuneListener? _wavelogTuner;
    /// The token as stored when the window opened: Save writes only a change.
    private string _storedWavelogToken = "";
    /// The fetched list; null until Refresh (the saved pick alone till then).
    private List<Wavelog.Station>? _wavelogStations;
    private Wavelog.Station? _wavelogStation;
    private bool _wavelogLoaded;
    private bool _wavelogBusy;
    private bool _fillingWavelogStations;

    private void InitWavelog()
    {
        WavelogEnabledCheckBox.IsChecked = AppSettings.WavelogEnabled;
        WavelogCatCheckBox.IsChecked = AppSettings.WavelogCatEnabled;
        WavelogTuneCheckBox.IsChecked = AppSettings.WavelogTuneEnabled;
        WavelogUrlBox.Text = AppSettings.WavelogUrl;
        _storedWavelogToken = WavelogToken.Read();
        WavelogTokenBox.Password = _storedWavelogToken;
        if (AppSettings.WavelogStationId.Length > 0)
        {
            _wavelogStation = new Wavelog.Station(AppSettings.WavelogStationId, AppSettings.WavelogStationName,
                AppSettings.WavelogStationCallsign, "", false);
        }
        FillWavelogStations();
        WavelogRadioNameBox.Text = AppSettings.WavelogRadioNameSetting;
        WavelogRadioNameBox.PlaceholderText = AppSettings.DefaultWavelogRadioName;
        WavelogTunePortBox.Value = AppSettings.WavelogTunePort;
        WavelogTunePortBox.ValueChanged += (_, _) => UpdateWavelogPanels();
        CallsignBox.TextChanged += (_, _) => UpdateWavelogPanels();
        _wavelogLoaded = true;
        UpdateWavelogPanels();
    }

    private void SaveWavelog(string url)
    {
        AppSettings.WavelogEnabled = WavelogEnabledCheckBox.IsChecked == true;
        AppSettings.WavelogCatEnabled = WavelogCatCheckBox.IsChecked == true;
        AppSettings.WavelogTuneEnabled = WavelogTuneCheckBox.IsChecked == true;
        AppSettings.WavelogUrl = url;
        AppSettings.SetWavelogStation(_wavelogStation?.Id ?? "", _wavelogStation?.Name ?? "", _wavelogStation?.Callsign ?? "");
        AppSettings.WavelogRadioName = WavelogRadioNameBox.Text.Trim();
        AppSettings.WavelogTunePort = double.IsNaN(WavelogTunePortBox.Value)
            ? AppSettings.DefaultWavelogTunePort
            : (int)Math.Round(WavelogTunePortBox.Value);
        if (TypedWavelogToken != _storedWavelogToken)
        {
            WavelogToken.Write(TypedWavelogToken);
        }
    }

    private string TypedWavelogToken => WavelogTokenBox.Password.Trim();

    private bool HasWavelogCredentials => WavelogUrlBox.Text.Trim().Length > 0 && TypedWavelogToken.Length > 0;

    /// v1 keys are "wl" + hex; v2 refuses them with a less helpful message.
    private bool IsWavelogV1Key => TypedWavelogToken.Length > 0 && !TypedWavelogToken.StartsWith(Wavelog.TokenPrefix, StringComparison.Ordinal);

    private void WavelogCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (!_wavelogLoaded)
        {
            return;
        }
        UpdateWavelogPanels();
        if (ReferenceEquals(sender, WavelogEnabledCheckBox))
        {
            AutoRefreshWavelogStations();
        }
    }

    private void WavelogCredentials_Changed(object sender, RoutedEventArgs e)
    {
        if (_wavelogLoaded)
        {
            UpdateWavelogPanels();
        }
    }

    private void OnWavelogStatusChanged() => DispatcherQueue.TryEnqueue(UpdateWavelogPanels);

    private void UpdateWavelogPanels()
    {
        if (!_wavelogLoaded)
        {
            return;
        }
        var logging = WavelogEnabledCheckBox.IsChecked == true;
        var cat = WavelogCatCheckBox.IsChecked == true;
        var tune = WavelogTuneCheckBox.IsChecked == true;
        WavelogCredentialsPanel.Visibility = logging || cat || tune ? Visibility.Visible : Visibility.Collapsed;
        WavelogLogPanel.Visibility = logging ? Visibility.Visible : Visibility.Collapsed;
        WavelogCatPanel.Visibility = cat ? Visibility.Visible : Visibility.Collapsed;
        WavelogTunePanel.Visibility = tune ? Visibility.Visible : Visibility.Collapsed;
        WavelogV1KeyText.Visibility = IsWavelogV1Key ? Visibility.Visible : Visibility.Collapsed;

        WavelogRefreshButton.IsEnabled = !_wavelogBusy && HasWavelogCredentials && !IsWavelogV1Key;
        WavelogTestButton.IsEnabled = !_wavelogBusy && HasWavelogCredentials && !IsWavelogV1Key && _wavelogStation is not null;
        WavelogProgress.IsActive = _wavelogBusy;
        WavelogProgress.Visibility = _wavelogBusy ? Visibility.Visible : Visibility.Collapsed;

        // API v2 doesn't refuse a record whose station callsign isn't the
        // location's (v1 did): it files it under the location's callsign.
        var mine = CallsignBox.Text.Trim().ToUpperInvariant();
        var theirs = _wavelogStation?.Callsign ?? "";
        var mismatch = mine.Length > 0 && theirs.Length > 0 && mine != theirs.ToUpperInvariant();
        WavelogMismatchText.Text = mismatch
            ? Loc.F("settings.settingsStationsCallsignX", mine, theirs, theirs, mine)
            : "";
        WavelogMismatchText.Visibility = mismatch ? Visibility.Visible : Visibility.Collapsed;

        UpdateWavelogCatStatus(cat);
        UpdateWavelogTuneStatus(tune);
    }

    private void UpdateWavelogCatStatus(bool checkedNow)
    {
        if (!checkedNow)
        {
            return;
        }
        if (!AppSettings.WavelogCatEnabled || _wavelogReporter is null)
        {
            SetStatusLine(WavelogCatStatusText, Loc.S("settings.startsWhenYouSave"), StatusTone.Secondary);
        }
        else if (_wavelogReporter.LastResult is { } result)
        {
            if (result.Error is { } error)
            {
                SetStatusLine(WavelogCatStatusText, error, StatusTone.Failure);
            }
            else
            {
                SetStatusLine(WavelogCatStatusText, Loc.F("settings.wavelogUpdatedX", result.At.ToLocalTime()), StatusTone.Success);
            }
        }
        else
        {
            SetStatusLine(WavelogCatStatusText, Loc.S("settings.sentOnceTheRig"), StatusTone.Secondary);
        }
    }

    private void UpdateWavelogTuneStatus(bool checkedNow)
    {
        if (!checkedNow)
        {
            return;
        }
        var typedPort = double.IsNaN(WavelogTunePortBox.Value) ? AppSettings.DefaultWavelogTunePort : (int)Math.Round(WavelogTunePortBox.Value);
        switch (_wavelogTuner?.State)
        {
            case WavelogTuneListener.ListenerState.Failed(var message) when AppSettings.WavelogTuneEnabled && typedPort == AppSettings.WavelogTunePort:
                SetStatusLine(WavelogTuneStatusText, message, StatusTone.Failure);
                break;
            case WavelogTuneListener.ListenerState.Listening(var port) when port == typedPort:
                if (WavelogTuneRequest.OriginOfWavelogUrl(WavelogUrlBox.Text) is null)
                {
                    SetStatusLine(WavelogTuneStatusText, Loc.S("settings.setTheWavelogURL"), StatusTone.Warning);
                }
                else if (_wavelogTuner.LastEvent is { } last)
                {
                    SetStatusLine(WavelogTuneStatusText, $"{last.Text} ({last.At.ToLocalTime():HH:mm:ss})", last.Ok ? StatusTone.Success : StatusTone.Warning);
                }
                else
                {
                    SetStatusLine(WavelogTuneStatusText, Loc.F("settings.listeningOn1270", port), StatusTone.Secondary);
                }
                break;
            default:
                SetStatusLine(WavelogTuneStatusText, Loc.F("settings.listensOn1270", typedPort), StatusTone.Secondary);
                break;
        }
    }

    private enum StatusTone { Secondary, Success, Warning, Failure }

    private static void SetStatusLine(TextBlock text, string message, StatusTone tone)
    {
        text.Text = message;
        text.Foreground = ToneBrush(tone);
    }

    private static Brush ToneBrush(StatusTone tone) =>
        tone switch
        {
            StatusTone.Success => (Brush)Application.Current.Resources["SystemFillColorSuccessBrush"],
            StatusTone.Warning => new SolidColorBrush(Microsoft.UI.Colors.DarkOrange),
            StatusTone.Failure => (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"],
            _ => new SolidColorBrush(Microsoft.UI.Colors.Gray),
        };

    /// The fetched list, or the saved pick alone until it's fetched; "None"
    /// while nothing is picked.
    private void FillWavelogStations()
    {
        _fillingWavelogStations = true;
        WavelogStationComboBox.Items.Clear();
        var choices = _wavelogStations ?? (_wavelogStation is { } pick ? [pick] : []);
        if (_wavelogStation is null)
        {
            WavelogStationComboBox.Items.Add(new ComboBoxItem { Content = Loc.S("settings.none"), Tag = null });
        }
        foreach (var station in choices)
        {
            var name = station.Name.Length == 0 ? Loc.F("settings.locationX", station.Id) : station.Name;
            WavelogStationComboBox.Items.Add(new ComboBoxItem
            {
                Content = station.Callsign.Length == 0 ? name : $"{name} ({station.Callsign})",
                Tag = station,
            });
        }
        WavelogStationComboBox.SelectedItem = WavelogStationComboBox.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(i => (i.Tag as Wavelog.Station)?.Id == _wavelogStation?.Id);
        _fillingWavelogStations = false;
    }

    private void WavelogStationComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_fillingWavelogStations || WavelogStationComboBox.SelectedItem is not ComboBoxItem { Tag: Wavelog.Station station })
        {
            return;
        }
        _wavelogStation = station;
        WavelogStatusText.Text = "";
        UpdateWavelogPanels();
    }

    /// The first time logging is on with a token and URL, as the Mac does.
    private void AutoRefreshWavelogStations()
    {
        if (_isOpen && WavelogEnabledCheckBox.IsChecked == true && _wavelogStations is null && !_wavelogBusy
            && HasWavelogCredentials && !IsWavelogV1Key)
        {
            WavelogRefreshButton_Click(this, new RoutedEventArgs());
        }
    }

    private async void WavelogRefreshButton_Click(object sender, RoutedEventArgs e)
    {
        var url = WavelogUrlBox.Text.Trim();
        var token = TypedWavelogToken;
        _wavelogBusy = true;
        WavelogStatusText.Text = "";
        UpdateWavelogPanels();
        try
        {
            var list = await Wavelog.StationsAsync(url, token);
            _wavelogStations = list;
            if (list.FirstOrDefault(s => s.Id == _wavelogStation?.Id) is { } current)
            {
                _wavelogStation = current;
            }
            else if ((list.FirstOrDefault(s => s.IsActive) ?? list.FirstOrDefault()) is { } pick)
            {
                _wavelogStation = pick;
            }
            FillWavelogStations();
            if (list.Count == 0)
            {
                SetStatusLine(WavelogStatusText, Loc.S("settings.thisWavelogAccountHas"), StatusTone.Failure);
            }
        }
        catch (Wavelog.ApiException ex)
        {
            SetStatusLine(WavelogStatusText, ex.Message, StatusTone.Failure);
        }
        finally
        {
            _wavelogBusy = false;
            UpdateWavelogPanels();
        }
    }

    /// The API's dry run with a made-up QSO: nothing is written.
    private async void WavelogTestButton_Click(object sender, RoutedEventArgs e)
    {
        if (_wavelogStation is not { } station)
        {
            return;
        }
        var url = WavelogUrlBox.Text.Trim();
        var token = TypedWavelogToken;
        var now = DateTimeOffset.UtcNow;
        var qso = new LoggedQso
        {
            Call = "TE5T",
            Start = now,
            End = now,
            FrequencyHz = 14_025_000,
            Mode = "CW",
            MyCall = CallsignBox.Text.Trim().ToUpperInvariant(),
        };
        _wavelogBusy = true;
        WavelogStatusText.Text = "";
        UpdateWavelogPanels();
        try
        {
            switch (await Wavelog.LogAsync(qso, url, token, station.Id, dryRun: true))
            {
                case Wavelog.LogResult.Rejected(var reason):
                    SetStatusLine(WavelogStatusText, reason, StatusTone.Failure);
                    break;
                default:
                    SetStatusLine(WavelogStatusText, Loc.S("settings.connectedTheTokenCan"), StatusTone.Success);
                    break;
            }
        }
        catch (Wavelog.ApiException ex)
        {
            SetStatusLine(WavelogStatusText, ex.Message, StatusTone.Failure);
        }
        finally
        {
            _wavelogBusy = false;
            UpdateWavelogPanels();
        }
    }

    // rigctld tab.

    private ConnectionMode SelectedMode =>
        ConnectionModeComboBox.SelectedItem is ComboBoxItem { Tag: "Local" } ? ConnectionMode.Local : ConnectionMode.Remote;

    private void ConnectionModeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateModePanels();
        RefreshVersions();
    }

    private void UpdateModePanels()
    {
        var local = SelectedMode == ConnectionMode.Local;
        LocalSettingsPanel.Visibility = local ? Visibility.Visible : Visibility.Collapsed;
        RemoteSettingsPanel.Visibility = local ? Visibility.Collapsed : Visibility.Visible;
        InstalledVersionLabel.Visibility = local ? Visibility.Visible : Visibility.Collapsed;
        InstalledVersionPanel.Visibility = local ? Visibility.Visible : Visibility.Collapsed;
        RunningVersionLabel.Text = local ? Loc.S("settings.running") : Loc.S("settings.runningOnPi");
    }

    // --- rigctld choice (the Mac's rigctld Picker) ---
    //
    // Automatic, Built-in, every installed copy Automatic would look at
    // (RigctldBinary.SearchPaths), an explicitly chosen path if it isn't one
    // of those, and Browse…, which opens a file picker and then selects
    // what was picked (or goes back to the previous choice).

    private const string BrowseTag = "browse";
    private readonly RigctldBinary.Resolution? _inUse;
    private RigctldBinary.Choice _rigctldChoice = RigctldBinary.Choice.Automatic;
    private bool _fillingRigctldChoices;

    private RigctldBinary.Choice SelectedRigctldChoice => _rigctldChoice;

    private void FillRigctldChoices(RigctldBinary.Choice selected)
    {
        _fillingRigctldChoices = true;
        _rigctldChoice = selected;
        var items = RigctldChoiceComboBox.Items;
        items.Clear();
        items.Add(new ComboBoxItem { Content = Loc.S("settings.automaticRecommended"), Tag = RigctldBinary.Choice.Automatic });
        var builtIn = new ComboBoxItem { Content = Loc.S("settings.builtInHamlib"), Tag = RigctldBinary.Choice.BuiltIn };
        items.Add(builtIn);
        var paths = RigctldBinary.SearchPaths().ToList();
        if (selected.ExplicitPath is { } chosen && !paths.Contains(chosen, StringComparer.OrdinalIgnoreCase))
        {
            paths.Add(chosen);
        }
        foreach (var path in paths)
        {
            items.Add(new ComboBoxItem { Content = path, Tag = RigctldBinary.Choice.ForPath(path) });
        }
        items.Add(new ComboBoxItem { Content = Loc.S("settings.browse"), Tag = BrowseTag });
        RigctldChoiceComboBox.SelectedItem = items.OfType<ComboBoxItem>().FirstOrDefault(i =>
            i.Tag is RigctldBinary.Choice c
            && string.Equals(c.StoredValue, selected.StoredValue, StringComparison.OrdinalIgnoreCase));
        _fillingRigctldChoices = false;
        _ = LabelBuiltInAsync(builtIn);
    }

    private static async Task LabelBuiltInAsync(ComboBoxItem item)
    {
        var version = await RigctldBinary.BuiltInVersionAsync();
        item.Content = version is { } v ? Loc.F("settings.builtInHamlibX", v) : Loc.S("settings.builtInMissingFrom");
    }

    private async void RigctldChoiceComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_fillingRigctldChoices || RigctldChoiceComboBox.SelectedItem is not ComboBoxItem { Tag: var tag })
        {
            return;
        }
        if (tag is RigctldBinary.Choice choice)
        {
            _rigctldChoice = choice;
            RefreshVersions();
            return;
        }
        // Browse…
        var picker = new FileOpenPicker();
        // Unpackaged WinUI 3 pickers need the owning window's HWND.
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".exe");
        var file = await picker.PickSingleFileAsync();
        FillRigctldChoices(file is null ? _rigctldChoice : RigctldBinary.Choice.ForPath(file.Path));
        RefreshVersions();
    }

    // --- rigctld version box (the Mac's RigctldVersionBox) ---
    //
    // Follows the tab's unsaved fields. "Uses" (Local only) resolves the
    // picked choice the way a start would (RigctldBinary.ResolveAsync: which
    // copy, its version, and why — with a warning when an explicitly chosen
    // copy is too old or lacks the model); "Running" asks whatever answers
    // on port 4532 (127.0.0.1, or the Pi) through its own short-lived
    // connection — the only way to see the Pi's version, and in Local mode
    // it can differ from the file when an already-running rigctld was
    // adopted.

    private bool _isOpen;

    // Mobile (Tag "Hub"): what to type into the iPad's Desktop hub host
    // field, whether the hub is reachable and who's connected — the Mac's
    // Settings → Mobile (MobileSettingsTab.swift). The switch itself applies
    // on Save; the rest is live.

    private readonly HubServer? _hub;
    private readonly bool _hubAudioRunning;
    private DispatcherQueueTimer? _hubProbeTimer;
    /// The addresses, Tailscale and firewall, re-read every 5 s while the
    /// tab shows (null until the first read).
    private HubNetworkProbe.Snapshot? _hubSnapshot;
    private bool _hubProbing;
    /// MagicDNS short names of connected tailnet clients, by IP; null while
    /// looking up or when there's none. Tailnet clients only: a LAN address
    /// rarely has a reverse name, and looking one up can stall.
    private readonly Dictionary<string, string?> _hubClientNames = [];
    /// What each panel last showed, so a refresh that changes nothing
    /// doesn't rebuild it (and drop a text selection).
    private readonly Dictionary<Panel, string> _hubShown = [];

    private const string TailscaleDownload = "https://tailscale.com/download";

    private enum HubLineKind { Status, Address, Note, OpenTailscale, GetTailscale, TailscaleLink }

    private sealed record HubLine(HubLineKind Kind, string Label, string Value, StatusTone Tone = StatusTone.Secondary);

    private void OnHubStatusChanged() => DispatcherQueue.TryEnqueue(RefreshHubStatus);

    /// From Opened; stopped on Closed.
    private void StartHubProbe()
    {
        _hubProbeTimer = DispatcherQueue.CreateTimer();
        _hubProbeTimer.Interval = TimeSpan.FromSeconds(5);
        _hubProbeTimer.Tick += (_, _) => ProbeHubNetwork();
        _hubProbeTimer.Start();
        ProbeHubNetwork();
    }

    /// Only while the tab shows, one read at a time (it blocks for up to a
    /// few seconds: tailscale.exe, the firewall's COM API, reverse DNS).
    private async void ProbeHubNetwork()
    {
        if (_hubProbing || !_isOpen || HubTab.Visibility != Visibility.Visible)
        {
            return;
        }
        _hubProbing = true;
        try
        {
            var appPath = Environment.ProcessPath;
            _hubSnapshot = await Task.Run(() => HubNetworkProbe.Read(appPath, HubServer.Port));
        }
        finally
        {
            _hubProbing = false;
        }
        if (_isOpen)
        {
            RefreshHubStatus();
        }
    }

    private void RefreshHubStatus()
    {
        HubAudioOffText.Visibility = _hubAudioRunning ? Visibility.Collapsed : Visibility.Visible;
        var clients = _hub?.Clients ?? [];
        ResolveHubClientNames(clients);
        ShowHubLines(HubStatusPanel, HubStatusLines(clients));
        ShowHubLines(HubLanPanel, HubLanLines());
        ShowHubLines(HubTailscalePanel, HubTailscaleLines());
    }

    private List<HubLine> HubStatusLines(IReadOnlyList<HubServer.ClientInfo> clients)
    {
        var lines = new List<HubLine>();
        var server = Loc.S("settings.mobile.hubServer");
        if (_hub is { IsListening: true })
        {
            lines.Add(new(HubLineKind.Status, server, Loc.F("settings.listeningOnPortX", HubServer.Port), StatusTone.Success));
        }
        else if (!AppSettings.HubEnabled)
        {
            lines.Add(new(HubLineKind.Status, server, Loc.S("settings.mobile.hubOff")));
        }
        else
        {
            lines.Add(new(HubLineKind.Status, server, _hub?.LastError is { } error
                ? Loc.F("settings.notListeningX", error)
                : Loc.S("settings.notListening"), StatusTone.Warning));
        }

        var firewall = Loc.S("settings.mobile.firewall");
        lines.Add(_hubSnapshot switch
        {
            null => new(HubLineKind.Status, firewall, Loc.S("common.checking")),
            { Firewall: null } => new(HubLineKind.Status, firewall, "—"),
            { Firewall: { } verdict } => FirewallLine(firewall, verdict),
        });

        var devices = Loc.S("settings.mobile.connectedDevices");
        if (clients.Count == 0)
        {
            lines.Add(new(HubLineKind.Status, devices, Loc.S("settings.mobile.noDevicesConnected")));
        }
        foreach (var (client, index) in clients.Select((c, i) => (c, i)))
        {
            var text = _hubClientNames.GetValueOrDefault(client.Address) is { } name
                ? Loc.F("settings.mobile.clientNamed", name, client.Address, client.ConnectedAt.ToString("t"))
                : Loc.F("settings.mobile.client", client.Address, client.ConnectedAt.ToString("t"));
            lines.Add(new(HubLineKind.Status, index == 0 ? devices : "", text, StatusTone.Success));
        }
        return lines;
    }

    private static HubLine FirewallLine(string label, FirewallVerdict verdict)
    {
        var networks = string.Join(", ", new[] { FirewallProfiles.Domain, FirewallProfiles.Private, FirewallProfiles.Public }
            .Where(p => verdict.Profiles.HasFlag(p))
            .Select(p => Loc.S($"settings.mobile.network{p}")));
        return verdict.Kind switch
        {
            FirewallVerdictKind.Off => new(HubLineKind.Status, label, Loc.S("settings.mobile.firewallOff"), StatusTone.Success),
            FirewallVerdictKind.AllowsApp => new(HubLineKind.Status, label, Loc.S("settings.mobile.firewallAllows"), StatusTone.Success),
            FirewallVerdictKind.NoRule => new(HubLineKind.Status, label, Loc.F("settings.mobile.firewallNoRule", networks), StatusTone.Warning),
            FirewallVerdictKind.BlocksApp => new(HubLineKind.Status, label, Loc.F("settings.mobile.firewallBlocksApp", networks), StatusTone.Failure),
            _ => new(HubLineKind.Status, label, Loc.F("settings.mobile.firewallBlocksAll", networks), StatusTone.Failure),
        };
    }

    private List<HubLine> HubLanLines()
    {
        if (_hubSnapshot is not { } snapshot)
        {
            return [new(HubLineKind.Note, "", Loc.S("common.checking"))];
        }
        if (snapshot.Lan.Count == 0)
        {
            return [new(HubLineKind.Status, "", Loc.S("settings.mobile.noLocalNetwork"), StatusTone.Warning)];
        }
        var lines = snapshot.Lan.Select(a => new HubLine(HubLineKind.Address, a.InterfaceName, a.Ip)).ToList();
        if (snapshot.LocalHostName is { } host)
        {
            lines.Add(new(HubLineKind.Address, Loc.S("settings.mobile.localHostName"), host));
        }
        return lines;
    }

    private List<HubLine> HubTailscaleLines()
    {
        var tailscale = "Tailscale";
        if (_hubSnapshot is not { } snapshot)
        {
            return [new(HubLineKind.Note, "", Loc.S("common.checking"))];
        }
        if (snapshot.TailnetIp is { } ip)
        {
            var lines = new List<HubLine>
            {
                new(HubLineKind.Status, tailscale, Loc.S("settings.mobile.tailscaleConnected"), StatusTone.Success),
            };
            if (snapshot.TailnetName is { } name)
            {
                lines.Add(new(HubLineKind.Address, Loc.S("settings.mobile.magicDNSName"), name));
                // The short name works on the iPad too while MagicDNS is on.
                var shortName = HubConnectionInfo.ShortName(name);
                if (shortName != name)
                {
                    lines.Add(new(HubLineKind.Address, Loc.S("settings.mobile.shortName"), shortName));
                }
            }
            lines.Add(new(HubLineKind.Address, Loc.S("settings.mobile.tailscaleIP"), ip));
            lines.Add(new(HubLineKind.TailscaleLink, "", Loc.S("settings.mobile.getTailscaleForIPad")));
            return lines;
        }
        return snapshot.TailscaleInstalled
            ?
            [
                new(HubLineKind.Status, tailscale, Loc.S("settings.mobile.tailscaleNotConnected"), StatusTone.Warning),
                new(HubLineKind.Note, "", Loc.S("settings.mobile.tailscaleExplanation")),
                new(HubLineKind.OpenTailscale, "", Loc.S("settings.mobile.openTailscale")),
            ]
            :
            [
                new(HubLineKind.Status, tailscale, Loc.S("settings.mobile.tailscaleNotInstalled")),
                new(HubLineKind.Note, "", Loc.S("settings.mobile.tailscaleExplanation")),
                new(HubLineKind.GetTailscale, "", Loc.S("settings.mobile.getTailscale")),
            ];
    }

    /// Looks up the MagicDNS names of tailnet clients not looked up yet; a
    /// found name refreshes the list.
    private void ResolveHubClientNames(IReadOnlyList<HubServer.ClientInfo> clients)
    {
        foreach (var ip in clients.Select(c => c.Address).Distinct()
                     .Where(ip => HubConnectionInfo.IsTailnet(ip) && !_hubClientNames.ContainsKey(ip)))
        {
            _hubClientNames[ip] = null;
            _ = Task.Run(() => HubNetworkProbe.ReverseTailnetName(ip)).ContinueWith(lookup =>
            {
                if (lookup.Result is { } name)
                {
                    DispatcherQueue.TryEnqueue(() =>
                    {
                        _hubClientNames[ip] = HubConnectionInfo.ShortName(name);
                        if (_isOpen)
                        {
                            RefreshHubStatus();
                        }
                    });
                }
            }, TaskContinuationOptions.OnlyOnRanToCompletion);
        }
    }

    private void ShowHubLines(Panel panel, List<HubLine> lines)
    {
        var shown = string.Join("\n", lines.Select(l => $"{l.Kind}\t{l.Label}\t{l.Value}\t{l.Tone}"));
        if (_hubShown.TryGetValue(panel, out var last) && last == shown)
        {
            return;
        }
        _hubShown[panel] = shown;
        panel.Children.Clear();
        foreach (var line in lines)
        {
            panel.Children.Add(HubElement(line));
        }
    }

    private static UIElement HubElement(HubLine line)
    {
        switch (line.Kind)
        {
            case HubLineKind.Status:
                return HubLabeled(line.Label, HubStatusLine(line.Value, line.Tone));
            case HubLineKind.Address:
                return HubLabeled(line.Label, HubAddress(line.Value));
            case HubLineKind.Note:
                return new TextBlock { Text = line.Value, Foreground = ToneBrush(StatusTone.Secondary), TextWrapping = TextWrapping.Wrap };
            case HubLineKind.TailscaleLink:
                return new HyperlinkButton { Content = line.Value, NavigateUri = new Uri(TailscaleDownload), Padding = new Thickness(0) };
            default:
                var button = new Button { Content = line.Value };
                if (line.Kind == HubLineKind.GetTailscale)
                {
                    button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
                }
                var target = line.Kind == HubLineKind.GetTailscale ? TailscaleDownload : HubNetworkProbe.TailscaleGuiPath;
                button.Click += (_, _) =>
                {
                    try
                    {
                        Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
                    }
                    catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
                    {
                        AppLog.Write($"settings: couldn't open {target}: {ex.Message}");
                    }
                };
                return button;
        }
    }

    /// A label column and its value, like the Mac's LabeledContent.
    private static Grid HubLabeled(string label, UIElement value)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var text = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(text);
        Grid.SetColumn((FrameworkElement)value, 1);
        grid.Children.Add(value);
        return grid;
    }

    /// A coloured dot and a line of text.
    private static Grid HubStatusLine(string text, StatusTone tone)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Width = 8,
            Height = 8,
            Fill = ToneBrush(tone),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 6, 0, 0),
        });
        var line = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        Grid.SetColumn(line, 1);
        grid.Children.Add(line);
        return grid;
    }

    /// An address to type into the iPad, selectable, with a copy button.
    private static StackPanel HubAddress(string value)
    {
        var copy = new Button
        {
            Content = new FontIcon { Glyph = "\uE8C8", FontSize = 14 },
            Padding = new Thickness(6, 4, 6, 4),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(copy, Loc.S("common.copy"));
        AutomationProperties.SetName(copy, Loc.S("common.copy"));
        copy.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(value);
            Clipboard.SetContent(package);
        };
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        panel.Children.Add(new TextBlock
        {
            Text = value,
            FontFamily = new FontFamily("Consolas"),
            IsTextSelectionEnabled = true,
            VerticalAlignment = VerticalAlignment.Center,
        });
        panel.Children.Add(copy);
        return panel;
    }

    private CancellationTokenSource? _versionLookup;

    private void RefreshVersionButton_Click(object sender, RoutedEventArgs e) => RefreshVersions();

    private async void RefreshVersions()
    {
        if (!_isOpen)
        {
            return;
        }
        _versionLookup?.Cancel();
        var cts = new CancellationTokenSource();
        _versionLookup = cts;
        var token = cts.Token;

        var local = SelectedMode == ConnectionMode.Local;
        var choice = SelectedRigctldChoice;
        var model = double.IsNaN(ModelNumberBox.Value) ? AppSettings.ModelNumber : (int)ModelNumberBox.Value;
        var host = local ? "127.0.0.1" : PiHostBox.Text.Trim();
        InstalledVersionText.Text = Loc.S("settings.checking");
        ResolutionSummaryText.Visibility = Visibility.Collapsed;
        ResolutionWarningText.Visibility = Visibility.Collapsed;
        InUseText.Visibility = Visibility.Collapsed;
        RunningVersionText.Text = Loc.S("settings.checking");
        RefreshVersionButton.IsEnabled = false;
        try
        {
            // Typing restarts this per keystroke; wait until it settles
            // before connecting anywhere.
            await Task.Delay(400, token);
            if (local)
            {
                var resolution = await Task.Run(() => RigctldBinary.ResolveAsync(choice, model), token);
                var installed = resolution.Path is { } path
                    ? await Task.Run(() => BinaryVersionAsync(path), token)
                    : Loc.S("settings.noUsableRigctld");
                if (token.IsCancellationRequested) return;
                InstalledVersionText.Text = installed;
                ResolutionSummaryText.Text = resolution.Summary;
                ResolutionSummaryText.Visibility = Visibility.Visible;
                ResolutionWarningText.Text = resolution.Warning is { } warning ? $"⚠ {warning}" : "";
                ResolutionWarningText.Visibility = resolution.Warning is null ? Visibility.Collapsed : Visibility.Visible;
                if (_inUse is { } inUse && inUse != resolution)
                {
                    InUseText.Text = Loc.F("settings.startedThisSessionX", inUse.Summary);
                    InUseText.Visibility = Visibility.Visible;
                }
            }
            var running = host.Length == 0 ? Loc.S("settings.noPiHostnameSet") : await RunningVersionAsync(host, local, token);
            if (token.IsCancellationRequested) return;
            RunningVersionText.Text = running;
        }
        catch (OperationCanceledException)
        {
            return;
        }
        finally
        {
            if (_versionLookup == cts)
            {
                RefreshVersionButton.IsEnabled = true;
            }
        }
    }

    /// "rigctld --version" prints e.g. "rigctld Hamlib 4.7.2 …"; the program
    /// name is dropped to match what "\dump_caps" reports.
    private static async Task<string> BinaryVersionAsync(string path)
    {
        if (!File.Exists(path))
        {
            return Loc.S("settings.noRigctldExeAt");
        }
        var output = await RigctldBinary.RunAsync(path, "--version", TimeSpan.FromSeconds(3));
        if (output is null)
        {
            return Loc.S("settings.couldntRunRigctldExe");
        }
        var line = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault() ?? "";
        if (line.StartsWith("rigctld ", StringComparison.Ordinal))
        {
            line = line["rigctld ".Length..];
        }
        return line.Length == 0 ? Loc.S("settings.noVersionReported") : line;
    }

    private static async Task<string> RunningVersionAsync(string host, bool local, CancellationToken token)
    {
        await using var client = new RigctldClient(host);
        try
        {
            // Windows retries a refused connection for ~2 s before failing,
            // so localhost's "nothing there" takes that long; the Pi gets
            // the usual 5 s.
            await client.ConnectAsync(TimeSpan.FromSeconds(local ? 3 : 5), token);
        }
        catch (RigctldError)
        {
            return local ? Loc.S("settings.notRunning") : Loc.S("settings.unreachable");
        }
        try
        {
            return await client.ReadHamlibVersionAsync(token) ?? Loc.S("settings.noVersionReported");
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            return Loc.S("settings.noReplyFromRigctld");
        }
        catch (Exception ex) when (ex is RigctldError or IOException)
        {
            return Loc.S("settings.noReplyFromRigctld");
        }
    }

    private void ComPortComboBox_DropDownOpened(object sender, object e) => RefreshComPorts();

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

    // Audio tab.

    private void AudioInputComboBox_DropDownOpened(object sender, object e) => RefreshAudioInputs();

    /// Lists the active recording devices. A saved device that isn't
    /// plugged in stays listed (marked) so the selection isn't silently
    /// lost. With nothing saved yet, pre-selects the only "USB Audio"
    /// input if there's exactly one — the FTX-1's codec's usual name.
    private void RefreshAudioInputs()
    {
        var devices = LocalAudioCapture.ListDevices();
        var keepId = AudioInputComboBox.SelectedItem is ComboBoxItem { Tag: string current }
            ? current
            : AppSettings.LocalAudioDeviceId;
        AudioInputComboBox.Items.Clear();
        ComboBoxItem? selected = null;
        foreach (var (id, name) in devices)
        {
            var item = new ComboBoxItem { Content = name, Tag = id };
            AudioInputComboBox.Items.Add(item);
            if (id == keepId)
            {
                selected = item;
            }
        }
        if (selected is null && keepId.Length > 0)
        {
            var name = keepId == AppSettings.LocalAudioDeviceId ? AppSettings.LocalAudioDeviceName : keepId;
            selected = new ComboBoxItem { Content = Loc.F("settings.xNotConnected", name), Tag = keepId };
            AudioInputComboBox.Items.Add(selected);
        }
        if (selected is null)
        {
            var usb = devices.Where(d => d.Name.Contains("USB Audio", StringComparison.OrdinalIgnoreCase)).ToList();
            if (usb.Count == 1)
            {
                selected = AudioInputComboBox.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == usb[0].Id);
            }
        }
        AudioInputComboBox.SelectedItem = selected;
    }

    private void AudioOutputComboBox_DropDownOpened(object sender, object e) => RefreshAudioOutputs();

    /// "Windows default" first, then the active output devices. A saved
    /// device that isn't plugged in stays listed, marked, like the input.
    private void RefreshAudioOutputs()
    {
        var keepId = AudioOutputComboBox.SelectedItem is ComboBoxItem { Tag: string current }
            ? current
            : AppSettings.AudioOutputDeviceId;
        AudioOutputComboBox.Items.Clear();
        var defaultItem = new ComboBoxItem { Content = Loc.S("settings.windowsDefault"), Tag = "" };
        AudioOutputComboBox.Items.Add(defaultItem);
        var selected = defaultItem;
        foreach (var (id, name) in AudioPlayback.ListOutputDevices())
        {
            var item = new ComboBoxItem { Content = name, Tag = id };
            AudioOutputComboBox.Items.Add(item);
            if (id == keepId)
            {
                selected = item;
            }
        }
        if (keepId.Length > 0 && ReferenceEquals(selected, defaultItem))
        {
            var name = keepId == AppSettings.AudioOutputDeviceId ? AppSettings.AudioOutputDeviceName : keepId;
            selected = new ComboBoxItem { Content = Loc.F("settings.xNotConnected", name), Tag = keepId };
            AudioOutputComboBox.Items.Add(selected);
        }
        AudioOutputComboBox.SelectedItem = selected;
    }

    private void TxAudioOutputComboBox_DropDownOpened(object sender, object e) => RefreshTxAudioOutputs();

    /// "None" first (never Windows' default: the iPad's microphone mustn't
    /// end up on the speakers, or on the rig by accident), then the active
    /// output devices; a saved device that isn't plugged in stays listed,
    /// marked.
    private void RefreshTxAudioOutputs()
    {
        var keepId = TxAudioOutputComboBox.SelectedItem is ComboBoxItem { Tag: string current }
            ? current
            : AppSettings.TxAudioOutputDeviceId;
        TxAudioOutputComboBox.Items.Clear();
        var noneItem = new ComboBoxItem { Content = Loc.S("settings.none"), Tag = "" };
        TxAudioOutputComboBox.Items.Add(noneItem);
        var selected = noneItem;
        foreach (var (id, name) in AudioPlayback.ListOutputDevices())
        {
            var item = new ComboBoxItem { Content = name, Tag = id };
            TxAudioOutputComboBox.Items.Add(item);
            if (id == keepId)
            {
                selected = item;
            }
        }
        if (keepId.Length > 0 && ReferenceEquals(selected, noneItem))
        {
            var name = keepId == AppSettings.TxAudioOutputDeviceId ? AppSettings.TxAudioOutputDeviceName : keepId;
            selected = new ComboBoxItem { Content = Loc.F("settings.xNotConnected", name), Tag = keepId };
            TxAudioOutputComboBox.Items.Add(selected);
        }
        TxAudioOutputComboBox.SelectedItem = selected;
    }

    // Polling tab.

    private static void ConfigureNumberBox(NumberBox box, AppSettings.IntSetting setting, int value)
    {
        box.Minimum = setting.Min;
        box.Maximum = setting.Max;
        box.Value = value;
        box.ValidationMode = NumberBoxValidationMode.InvalidInputOverwritten;
        box.Description = Loc.F("settings.xXDefaultX", setting.Min, setting.Max, setting.Default);
    }

    /// An emptied box (NaN) saves the default.
    private static int NumberBoxValue(NumberBox box, AppSettings.IntSetting setting) =>
        double.IsNaN(box.Value) ? setting.Default : setting.Clamp((int)Math.Round(box.Value));

    private void RestorePollingDefaults_Click(object sender, RoutedEventArgs e)
    {
        PollIntervalBox.Value = AppSettings.PollIntervalMsSetting.Default;
        SlowPollEveryBox.Value = AppSettings.SlowPollEverySetting.Default;
        WpsdCallerBox.Value = AppSettings.WpsdCallerSecondsSetting.Default;
        WpsdReflectorBox.Value = AppSettings.WpsdReflectorSecondsSetting.Default;
    }

    // About tab.

    private string _updatePageUrl = UpdateChecker.ReleasesPageUrl;

    private async void CheckForUpdatesButton_Click(object sender, RoutedEventArgs e)
    {
        CheckForUpdatesButton.IsEnabled = false;
        UpdateProgress.IsActive = true;
        DownloadUpdateButton.Visibility = Visibility.Collapsed;
        ReleaseNotesBox.Visibility = Visibility.Collapsed;
        UpdateStatusText.Text = Loc.S("settings.checking");
        try
        {
            var update = await UpdateChecker.CheckAsync();
            if (update is null)
            {
                UpdateStatusText.Text = Loc.F("settings.youreUpToDate", UpdateChecker.CurrentVersionText);
            }
            else
            {
                _updatePageUrl = update.PageUrl;
                UpdateStatusText.Text = Loc.F("settings.versionXIsAvailable", UpdateChecker.Display(update.Version));
                DownloadUpdateButton.Content = Loc.F("settings.downloadX", UpdateChecker.Display(update.Version));
                DownloadUpdateButton.Visibility = Visibility.Visible;
                if (update.Notes.Length > 0)
                {
                    ReleaseNotesBox.Text = update.Notes;
                    ReleaseNotesBox.Visibility = Visibility.Visible;
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"update check failed: {ex.Message}");
            UpdateStatusText.Text = Loc.F("settings.couldntCheckForUpdates", ex.Message);
        }
        finally
        {
            UpdateProgress.IsActive = false;
            CheckForUpdatesButton.IsEnabled = true;
        }
    }

    private async void DownloadUpdateButton_Click(object sender, RoutedEventArgs e) =>
        await Windows.System.Launcher.LaunchUriAsync(new Uri(_updatePageUrl));
}

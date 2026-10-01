using System.Globalization;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
public sealed partial class SettingsDialog : ContentDialog
{
    private static readonly int[] BaudRates = [4800, 9600, 19200, 38400, 57600, 115200];

    private readonly Window _owner;
    private readonly List<(HomeBand Band, TextBox Box)> _homeFields = [];

    public bool AudioInputChanged { get; private set; }
    public bool AudioOutputChanged { get; private set; }
    public bool WpsdHostChanged { get; private set; }
    /// Ticked "Clear History" on the APRS tab; applied on Save, like
    /// everything else here.
    public bool AprsClearHistory { get; private set; }

    public SettingsDialog(Window owner, bool connected)
    {
        _owner = owner;
        InitializeComponent();
        XamlRoot = owner.Content.XamlRoot;
        RequestedTheme = (owner.Content as FrameworkElement)?.RequestedTheme ?? ElementTheme.Default;
        // ContentDialog caps its width at 548 by default — too narrow for
        // the tab bar and the rigctld path.
        Resources["ContentDialogMaxWidth"] = 720.0;

        // rigctld
        ConnectedNote.Visibility = connected ? Visibility.Visible : Visibility.Collapsed;
        foreach (var control in new Control[]
                 {
                     ConnectionModeComboBox, PiHostBox, RigctldPathBox, BrowseRigctldButton,
                     ModelNumberBox, ComPortComboBox, BaudRateComboBox,
                 })
        {
            control.IsEnabled = !connected;
        }
        ConnectionModeComboBox.SelectedIndex = AppSettings.ConnectionMode == ConnectionMode.Local ? 1 : 0;
        PiHostBox.Text = AppSettings.PiHost;
        RigctldPathBox.Text = AppSettings.RigctldPath;
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

        // Audio
        RefreshAudioInputs();
        RefreshAudioOutputs();

        // C4FM
        WpsdEnabledCheckBox.IsChecked = AppSettings.WpsdEnabled;
        WpsdHostBox.Text = AppSettings.WpsdHost;

        // APRS
        AprsEnabledCheckBox.IsChecked = AppSettings.AprsEnabled;
        AprsFrequencyBox.Text = FormatMHz(AppSettings.AprsFrequencyHz);
        ConfigureNumberBox(AprsToleranceBox, AppSettings.AprsToleranceHzSetting, AppSettings.AprsToleranceHz);
        ConfigureNumberBox(AprsMaxStationsBox, AppSettings.AprsMaxStationsSetting, AppSettings.AprsMaxStations);
        ConfigureNumberBox(AprsMaxMessagesBox, AppSettings.AprsMaxMessagesSetting, AppSettings.AprsMaxMessages);

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
            ToolTipService.SetToolTip(box, $"{FormatMHz(band.LowHz)}–{FormatMHz(band.HighHz)} MHz; factory {FormatMHz(band.FrequencyHz)}");
            _homeFields.Add((band, box));
            HomeFieldsPanel.Children.Add(box);
        }

        // Polling
        ConfigureNumberBox(PollIntervalBox, AppSettings.PollIntervalMsSetting, AppSettings.PollIntervalMs);
        ConfigureNumberBox(SlowPollEveryBox, AppSettings.SlowPollEverySetting, AppSettings.SlowPollEvery);
        ConfigureNumberBox(WpsdCallerBox, AppSettings.WpsdCallerSecondsSetting, AppSettings.WpsdCallerSeconds);
        ConfigureNumberBox(WpsdReflectorBox, AppSettings.WpsdReflectorSecondsSetting, AppSettings.WpsdReflectorSeconds);

        // Appearance
        foreach (var theme in Enum.GetValues<AppTheme>())
        {
            ThemeRadioButtons.Items.Add(new RadioButton { Content = theme.DisplayName(), Tag = theme });
        }
        ThemeRadioButtons.SelectedIndex = (int)AppSettings.Theme;
        foreach (var color in Enum.GetValues<ButtonValueColor>())
        {
            ButtonValueColorComboBox.Items.Add(new ComboBoxItem { Content = color.DisplayName(), Tag = color });
        }
        ButtonValueColorComboBox.SelectedIndex = (int)AppSettings.ButtonValueColor;
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
            ("Home", HomeTab), ("Polling", PollingTab), ("Appearance", AppearanceTab),
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
    }

    // Save.

    private void SaveButton_Click(ContentDialog sender, ContentDialogButtonClickEventArgs args)
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
                Fail("Home", $"{band.Name}: \"{text}\" isn't a frequency in MHz.");
                args.Cancel = true;
                return;
            }
            var hz = (long)Math.Round(mhz * 1_000_000);
            if (hz < band.LowHz || hz > band.HighHz)
            {
                Fail("Home", $"{band.Name}: {FormatMHz(hz)} MHz is outside the band group ({FormatMHz(band.LowHz)}–{FormatMHz(band.HighHz)} MHz).");
                args.Cancel = true;
                return;
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
                Fail("Aprs", $"\"{aprsFrequencyText}\" isn't a frequency in MHz.");
                args.Cancel = true;
                return;
            }
            aprsFrequencyHz = (long)Math.Round(aprsMhz * 1_000_000);
            if (aprsFrequencyHz <= 0)
            {
                Fail("Aprs", "The APRS frequency has to be above 0 MHz.");
                args.Cancel = true;
                return;
            }
        }

        if (ConnectionModeComboBox.IsEnabled)
        {
            AppSettings.ConnectionMode = SelectedMode;
            AppSettings.PiHost = PiHostBox.Text.Trim();
            AppSettings.RigctldPath = RigctldPathBox.Text.Trim().Trim('"');
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

        AppSettings.WpsdEnabled = WpsdEnabledCheckBox.IsChecked == true;
        var wpsdHost = NormalizeWpsdHost(WpsdHostBox.Text);
        if (wpsdHost != AppSettings.WpsdHost)
        {
            AppSettings.WpsdHost = wpsdHost;
            WpsdHostChanged = true;
        }

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

        if (ThemeRadioButtons.SelectedItem is RadioButton { Tag: AppTheme theme })
        {
            AppSettings.Theme = theme;
        }
        if (ButtonValueColorComboBox.SelectedItem is ComboBoxItem { Tag: ButtonValueColor color })
        {
            AppSettings.ButtonValueColor = color;
        }
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

    /// Only one ContentDialog can be open at a time, so instead of the Mac's
    /// confirmation dialog the button arms the clear and Save carries it out
    /// (Cancel still backs out); a second click disarms it.
    private void AprsClearHistoryButton_Click(object sender, RoutedEventArgs e)
    {
        AprsClearHistory = !AprsClearHistory;
        AprsClearHistoryButton.Content = AprsClearHistory ? "Don't Clear" : "Clear History…";
        AprsClearNote.Text = AprsClearHistory
            ? "Every decoded station and message will be deleted when you Save."
            : "";
    }

    // rigctld tab.

    private ConnectionMode SelectedMode =>
        ConnectionModeComboBox.SelectedItem is ComboBoxItem { Tag: "Local" } ? ConnectionMode.Local : ConnectionMode.Remote;

    private void ConnectionModeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateModePanels();

    private void UpdateModePanels()
    {
        var local = SelectedMode == ConnectionMode.Local;
        LocalSettingsPanel.Visibility = local ? Visibility.Visible : Visibility.Collapsed;
        RemoteSettingsPanel.Visibility = local ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void BrowseRigctldButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        // Unpackaged WinUI 3 pickers need the owning window's HWND.
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(_owner));
        picker.FileTypeFilter.Add(".exe");
        var file = await picker.PickSingleFileAsync();
        if (file is not null)
        {
            RigctldPathBox.Text = file.Path;
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
            selected = new ComboBoxItem { Content = $"{name} (not connected)", Tag = keepId };
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
        var defaultItem = new ComboBoxItem { Content = "Windows default", Tag = "" };
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
            selected = new ComboBoxItem { Content = $"{name} (not connected)", Tag = keepId };
            AudioOutputComboBox.Items.Add(selected);
        }
        AudioOutputComboBox.SelectedItem = selected;
    }

    // Polling tab.

    private static void ConfigureNumberBox(NumberBox box, AppSettings.IntSetting setting, int value)
    {
        box.Minimum = setting.Min;
        box.Maximum = setting.Max;
        box.Value = value;
        box.ValidationMode = NumberBoxValidationMode.InvalidInputOverwritten;
        box.Description = $"{setting.Min}–{setting.Max}, default {setting.Default}";
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
}

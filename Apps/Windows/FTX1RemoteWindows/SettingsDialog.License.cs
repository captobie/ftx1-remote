using System.Globalization;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;

namespace FTX1RemoteWindows;

/// Settings → License: the license-class guardrail (TransmitGate's
/// privileges), the Mac's LicenseSettingsTab. Unlike the Mac, where it
/// applies at once, it applies on Save like every other tab here; the
/// custom table is edited as a draft until then.
public sealed partial class SettingsDialog
{
    /// The transmitting side's frequency when the window opened, for Add
    /// Segment's starting band.
    private readonly long _transmitterHz;
    private PrivilegeProfile _customDraft = new("Custom", []);
    /// Each custom row's From/To boxes, parsed on Save (and on leaving a
    /// box, so the error shows early).
    private readonly List<(PrivilegeSegment Segment, TextBox From, TextBox To)> _customRows = [];

    private void InitLicense()
    {
        LicenseChoiceComboBox.Items.Add(new ComboBoxItem { Content = Loc.S("settings.license.offAmateurBandsOnly"), Tag = PrivilegeChoice.Off });
        foreach (var preset in PrivilegePresets.All.Where(p => p.IsUS).Concat(PrivilegePresets.All.Where(p => !p.IsUS)))
        {
            LicenseChoiceComboBox.Items.Add(new ComboBoxItem { Content = preset.DisplayName, Tag = preset.RawValue });
            var item = new MenuFlyoutItem { Text = preset.DisplayName };
            item.Click += async (_, _) => await CopyToCustomAsync(preset);
            LicenseStartFromMenu.Items.Add(item);
        }
        LicenseChoiceComboBox.Items.Add(new ComboBoxItem { Content = Loc.S("settings.license.custom"), Tag = PrivilegeChoice.Custom });

        _customDraft = AppSettings.LicenseCustomProfile.Copy();
        LicenseCustomNameBox.Text = _customDraft.Name;
        BuildCustomTable();
        SelectLicenseChoice(AppSettings.LicensePrivileges);
    }

    private string SelectedLicenseChoice =>
        LicenseChoiceComboBox.SelectedItem is ComboBoxItem { Tag: string tag } ? tag : PrivilegeChoice.Off;

    private void SelectLicenseChoice(string choice) =>
        LicenseChoiceComboBox.SelectedItem = LicenseChoiceComboBox.Items.OfType<ComboBoxItem>()
            .First(i => (string)i.Tag == PrivilegeChoice.Normalize(choice));

    private void LicenseChoiceComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateLicensePanels();

    private void UpdateLicensePanels()
    {
        var choice = SelectedLicenseChoice;
        var preset = PrivilegePresets.ByRawValue(choice);
        LicensePresetPanel.Visibility = preset is null ? Visibility.Collapsed : Visibility.Visible;
        LicenseCustomPanel.Visibility = choice == PrivilegeChoice.Custom ? Visibility.Visible : Visibility.Collapsed;
        if (preset is null)
        {
            return;
        }
        LicensePresetTitle.Text = preset.DisplayName;
        if (preset.IsUS)
        {
            LicensePresetNote.Text = Loc.S("settings.license.47CFR97301");
            LicensePresetNote.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray);
        }
        else
        {
            LicensePresetNote.Text = Loc.S("settings.license.theRegionsAmateurAllocations");
            LicensePresetNote.Foreground = new SolidColorBrush(Microsoft.UI.Colors.DarkOrange);
        }
        BuildPresetTable(preset);
    }

    // Presets.

    private void BuildPresetTable(PrivilegePreset preset)
    {
        var table = LicensePresetTable;
        table.Children.Clear();
        table.RowDefinitions.Clear();
        table.ColumnDefinitions.Clear();
        for (var c = 0; c < 3; c++)
        {
            table.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }
        AddRow(table, 0, Header(Loc.S("settings.license.fromMHz")), Header(Loc.S("settings.license.toMHz")), Header(Loc.S("settings.license.modes")));
        var row = 1;
        foreach (var segment in preset.Segments)
        {
            AddRow(table, row++, Cell(Mhz(segment.LowerHz)), Cell(Mhz(segment.UpperHz)), Cell(ModesLabel(segment)));
        }
    }

    private async void LicenseCopyToCustom_Click(object sender, RoutedEventArgs e)
    {
        if (PrivilegePresets.ByRawValue(SelectedLicenseChoice) is { } preset)
        {
            await CopyToCustomAsync(preset);
        }
    }

    private async Task CopyToCustomAsync(PrivilegePreset preset)
    {
        if (_customDraft.Segments.Count > 0
            && !await ConfirmReplaceAsync(Loc.F("settings.license.yourCustomTableX", _customDraft.Segments.Count, preset.DisplayName)))
        {
            return;
        }
        _customDraft = preset.Profile.Copy(Loc.F("settings.license.customFromX", preset.DisplayName));
        LicenseCustomNameBox.Text = _customDraft.Name;
        BuildCustomTable();
        SelectLicenseChoice(PrivilegeChoice.Custom);
    }

    private async Task<bool> ConfirmReplaceAsync(string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            RequestedTheme = RootGrid.RequestedTheme,
            Title = Loc.S("settings.license.replaceYourCustomPrivileges"),
            Content = message,
            PrimaryButtonText = Loc.S("settings.license.replace"),
            CloseButtonText = Loc.S("common.cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    // Custom.

    private void BuildCustomTable()
    {
        var table = LicenseCustomTable;
        table.Children.Clear();
        table.RowDefinitions.Clear();
        table.ColumnDefinitions.Clear();
        _customRows.Clear();
        for (var c = 0; c < 6; c++)
        {
            table.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }
        var empty = _customDraft.Segments.Count == 0;
        LicenseCustomEmptyText.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        LicenseExportButton.IsEnabled = !empty;
        if (empty)
        {
            return;
        }
        AddRow(table, 0, Header(Loc.S("settings.license.fromMHz")), Header(Loc.S("settings.license.toMHz")), Header("CW"), Header(Loc.S("common.phone")), Header(Loc.S("common.data")), Header(""));
        var row = 1;
        foreach (var segment in _customDraft.Segments)
        {
            var from = new TextBox { Text = Mhz(segment.LowerHz), Width = 110 };
            var to = new TextBox { Text = Mhz(segment.UpperHz), Width = 110 };
            var note = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 260 };
            void Commit()
            {
                if (ParseMhz(from.Text) is { } lower)
                {
                    segment.LowerHz = lower;
                }
                if (ParseMhz(to.Text) is { } upper)
                {
                    segment.UpperHz = upper;
                }
                UpdateRowNote(segment, from, to, note);
            }
            from.LostFocus += (_, _) => Commit();
            to.LostFocus += (_, _) => Commit();

            var checks = TransmitEmissionExtensions.All.Select(emission =>
            {
                var box = new CheckBox { IsChecked = segment.Emissions.Contains(emission), MinWidth = 0 };
                ToolTipService.SetToolTip(box, emission.DisplayName());
                box.Checked += (_, _) => segment.Emissions.Add(emission);
                box.Unchecked += (_, _) => segment.Emissions.Remove(emission);
                return (UIElement)box;
            }).ToArray();

            var remove = new Button { Content = new SymbolIcon(Symbol.Remove), Padding = new Thickness(6, 4, 6, 4) };
            ToolTipService.SetToolTip(remove, Loc.S("settings.license.removeThisSegment"));
            remove.Click += (_, _) =>
            {
                CommitCustomEdits();
                _customDraft.Segments.Remove(segment);
                BuildCustomTable();
            };
            var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            trailing.Children.Add(remove);
            trailing.Children.Add(note);
            UpdateRowNote(segment, from, to, note);

            AddRow(table, row++, from, to, checks[0], checks[1], checks[2], trailing);
            _customRows.Add((segment, from, to));
        }
    }

    private static void UpdateRowNote(PrivilegeSegment segment, TextBox from, TextBox to, TextBlock note)
    {
        if (ParseMhz(from.Text) is null || ParseMhz(to.Text) is null)
        {
            note.Text = Loc.S("settings.license.notAFrequencyIn");
            note.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Firebrick);
        }
        else if (segment.LowerHz > segment.UpperHz)
        {
            note.Text = Loc.S("settings.license.fromIsAboveTo");
            note.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Firebrick);
        }
        else if (segment.OnlyModes is { } only)
        {
            note.Text = $"only {ModeList(only)}";
            note.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray);
            ToolTipService.SetToolTip(note, Loc.S("settings.license.fromThePresetThis"));
        }
        else
        {
            note.Text = "";
        }
    }

    /// Takes the typed name and every valid frequency into the draft.
    private void CommitCustomEdits()
    {
        _customDraft.Name = LicenseCustomNameBox.Text.Trim();
        foreach (var (segment, from, to) in _customRows)
        {
            if (ParseMhz(from.Text) is { } lower)
            {
                segment.LowerHz = lower;
            }
            if (ParseMhz(to.Text) is { } upper)
            {
                segment.UpperHz = upper;
            }
        }
    }

    private void LicenseAddSegment_Click(object sender, RoutedEventArgs e)
    {
        CommitCustomEdits();
        // Start where the rig is, if that's in an amateur band.
        var band = BandPlan.BandContaining(_transmitterHz);
        _customDraft.Segments.Add(new PrivilegeSegment(band?.LowHz ?? 14_000_000, band?.HighHz ?? 14_350_000, [TransmitEmission.Cw]));
        BuildCustomTable();
    }

    private async void LicenseImport_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".json");
        var file = await picker.PickSingleFileAsync();
        if (file is null)
        {
            return;
        }
        PrivilegeProfile? profile;
        try
        {
            profile = PrivilegeProfile.FromJson(await File.ReadAllTextAsync(file.Path));
        }
        catch (Exception ex)
        {
            ErrorText.Text = Loc.F("settings.license.couldntReadXX", file.Name, ex.Message);
            return;
        }
        if (profile is null)
        {
            ErrorText.Text = Loc.F("settings.license.xIsntAPrivileges", file.Name);
            return;
        }
        if (_customDraft.Segments.Count > 0
            && !await ConfirmReplaceAsync(Loc.F("settings.license.yourCustomTableIs", profile.Name, profile.Segments.Count, file.Name)))
        {
            return;
        }
        ErrorText.Text = "";
        _customDraft = profile;
        LicenseCustomNameBox.Text = profile.Name;
        BuildCustomTable();
    }

    private async void LicenseExport_Click(object sender, RoutedEventArgs e)
    {
        CommitCustomEdits();
        var picker = new FileSavePicker { SuggestedFileName = _customDraft.Name.Length > 0 ? _customDraft.Name : "Custom" };
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeChoices.Add("JSON", [".json"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null)
        {
            return;
        }
        try
        {
            await File.WriteAllTextAsync(file.Path, _customDraft.ToJson());
        }
        catch (Exception ex)
        {
            ErrorText.Text = Loc.F("settings.license.couldntWriteXX", file.Name, ex.Message);
        }
    }

    // Save.

    /// A frequency box that doesn't parse, or null. Only Custom's table is
    /// checked, and only while Custom is chosen.
    private string? LicenseProblem()
    {
        if (SelectedLicenseChoice != PrivilegeChoice.Custom)
        {
            return null;
        }
        foreach (var (_, from, to) in _customRows)
        {
            foreach (var box in new[] { from, to })
            {
                if (ParseMhz(box.Text) is null)
                {
                    return Loc.F("settings.license.customPrivilegesXIsnt", box.Text);
                }
            }
        }
        return null;
    }

    private void SaveLicense()
    {
        CommitCustomEdits();
        if (_customDraft.Name.Length == 0)
        {
            _customDraft.Name = "Custom";
        }
        AppSettings.LicenseCustomProfile = _customDraft;
        AppSettings.LicensePrivileges = SelectedLicenseChoice;
    }

    // Formatting.

    private static TextBlock Header(string text) =>
        new() { Text = text, FontWeight = FontWeights.SemiBold, FontSize = 12 };

    private static TextBlock Cell(string text) =>
        new() { Text = text, FontSize = 12, FontFamily = new FontFamily("Consolas") };

    private static void AddRow(Grid table, int row, params UIElement[] cells)
    {
        table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var c = 0; c < cells.Length; c++)
        {
            if (cells[c] is FrameworkElement element)
            {
                element.VerticalAlignment = VerticalAlignment.Center;
            }
            Grid.SetRow((FrameworkElement)cells[c], row);
            Grid.SetColumn((FrameworkElement)cells[c], c);
            table.Children.Add(cells[c]);
        }
    }

    private static string Mhz(long hz) => (hz / 1_000_000.0).ToString("0.000######", CultureInfo.InvariantCulture);

    private static long? ParseMhz(string text)
    {
        text = text.Trim();
        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var mhz)
            && !double.TryParse(text, NumberStyles.Float, Loc.OsCulture, out mhz))
        {
            return null;
        }
        return mhz >= 0 ? (long)Math.Round(mhz * 1_000_000) : null;
    }

    private static string ModesLabel(PrivilegeSegment segment) => segment.OnlyModes is { } only
        ? ModeList(only)
        : string.Join(", ", TransmitEmissionExtensions.All.Where(segment.Emissions.Contains).Select(e => e.DisplayName()));

    /// Swift raw values in the Mac's RigMode order, shown by display name.
    private static string ModeList(IEnumerable<string> modes)
    {
        string[] order = ["USB", "LSB", "CW", "FM", "AM", "RTTY", "PKTUSB", "FM-D", "C4FM"];
        return string.Join(", ", modes.OrderBy(m => Array.IndexOf(order, m) is var i and >= 0 ? i : order.Length)
            .Select(m => m == "C4FM" ? "C4FM" : RigModeExtensions.FromRawValue(m)?.DisplayName() ?? m));
    }
}

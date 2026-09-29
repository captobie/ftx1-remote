using System.Globalization;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using static FTX1RemoteWindows.Models.DeepSettingValueType;

namespace FTX1RemoteWindows.Controls;

/// Port of the Mac's DeepSettingsView (Apps/Mac/FTX1RemoteMac/
/// DeepSettingsView.swift): one of the rig's page-3 SET-mode screens,
/// opened from the MENU grid's FM/C4FM page. Rendered generically from
/// DeepSettingsCatalog — the tabs (P2) down the side, the selected tab's
/// items (P3) as rows, each row's editor picked from its value type.
/// <c>p1s</c> is one category, except APRS SETTING, whose button spans
/// Table 3's categories 6-8 like the rig's.
///
/// Only the visible tab is read, one "EX" read per item when the tab is
/// shown (the Mac's loadValues; here in order, so the rows fill in top to
/// bottom — the client serializes round trips either way). A row shows
/// "—" until its read lands, or if the rig didn't answer it. Changes are
/// sent at once, like the Mac, except text fields: the Mac writes one on
/// every keystroke, here it's sent on Enter or when the field loses focus,
/// so the rig doesn't get every partial string. Momentary items (resets,
/// SD card load/save, calibration, ...) are shown disabled and never read
/// or sent, as on the Mac.
public sealed class DeepSettingsDialog : ContentDialog
{
    private static readonly SolidColorBrush Secondary = new(Microsoft.UI.Colors.Gray);

    private readonly RigctldClient _client;
    private readonly List<(int P1, int P2, string Name)> _tabs;
    private readonly ListView _tabList = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly StackPanel _rows = new() { Spacing = 2 };
    private readonly ProgressRing _progress = new() { IsActive = false, Width = 32, Height = 32 };
    private readonly TextBlock _status = new() { Foreground = Secondary, FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private readonly Dictionary<string, Border> _editorSlots = [];
    /// Bumped on every tab switch, so a read still running for the old tab
    /// stops instead of filling rows that are gone.
    private int _loadGeneration;

    public DeepSettingsDialog(XamlRoot root, ElementTheme theme, string title, int[] p1s, RigctldClient client)
    {
        _client = client;
        _tabs = DeepSettingsCatalog.Tabs(p1s);
        XamlRoot = root;
        RequestedTheme = theme;
        Title = title;
        CloseButtonText = "Done";
        DefaultButton = ContentDialogButton.Close;
        Resources["ContentDialogMaxWidth"] = 900.0;
        Resources["ContentDialogMaxHeight"] = 800.0;

        foreach (var tab in _tabs)
        {
            _tabList.Items.Add(tab.Name);
        }
        _tabList.SelectionChanged += (_, _) => ShowTab(_tabList.SelectedIndex);

        var detail = new Grid
        {
            Children =
            {
                new ScrollViewer { Content = _rows, Padding = new Thickness(0, 0, 16, 0) },
                _progress,
            },
        };
        _progress.HorizontalAlignment = HorizontalAlignment.Center;
        _progress.VerticalAlignment = VerticalAlignment.Center;

        var layout = new Grid { Width = 760, Height = 480, ColumnSpacing = 16, RowSpacing = 8 };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.Children.Add(_tabList);
        Grid.SetColumn(detail, 1);
        layout.Children.Add(detail);
        Grid.SetRow(_status, 1);
        Grid.SetColumnSpan(_status, 2);
        layout.Children.Add(_status);
        Content = layout;

        if (_tabs.Count > 0)
        {
            _tabList.SelectedIndex = 0;
        }
        else
        {
            _rows.Children.Add(new TextBlock { Text = $"{title} items haven't been added to the Deep Settings catalog.", Foreground = Secondary });
        }
    }

    private void ShowTab(int index)
    {
        _loadGeneration++;
        _rows.Children.Clear();
        _editorSlots.Clear();
        _status.Text = "";
        if (index < 0 || index >= _tabs.Count)
        {
            return;
        }
        var (p1, p2, _) = _tabs[index];
        var items = DeepSettingsCatalog.ItemsForTab(p1, p2).ToList();
        foreach (var item in items)
        {
            _rows.Children.Add(BuildRow(item));
        }
        _ = LoadAsync(items, _loadGeneration);
    }

    private Grid BuildRow(DeepSettingItem item)
    {
        var row = new Grid { MinHeight = 40, ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new TextBlock { Text = item.Label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap });
        var slot = new Border { VerticalAlignment = VerticalAlignment.Center, Child = Placeholder("—") };
        if (item.ValueType is Momentary)
        {
            ToolTipService.SetToolTip(slot, "Momentary or irreversible — not sent from this app");
        }
        Grid.SetColumn(slot, 1);
        row.Children.Add(slot);
        _editorSlots[item.Id] = slot;
        return row;
    }

    private async Task LoadAsync(List<DeepSettingItem> items, int generation)
    {
        _progress.IsActive = true;
        var unanswered = 0;
        try
        {
            foreach (var item in items)
            {
                if (item.ValueType is Momentary)
                {
                    continue;
                }
                string? raw;
                try
                {
                    raw = await _client.GetMenuItemAsync(item.P1, item.P2, item.P3);
                }
                catch (Exception ex)
                {
                    AppLog.Write($"deep settings: read EX{item.P1:00}{item.P2:00}{item.P3:00} failed: {ex.Message}");
                    raw = null;
                }
                if (generation != _loadGeneration)
                {
                    return;
                }
                if (raw is null)
                {
                    unanswered++;
                }
                else if (_editorSlots.TryGetValue(item.Id, out var slot))
                {
                    slot.Child = BuildEditor(item, raw);
                }
            }
            if (unanswered > 0)
            {
                _status.Text = unanswered == 1 ? "1 item didn't answer." : $"{unanswered} items didn't answer.";
            }
        }
        finally
        {
            if (generation == _loadGeneration)
            {
                _progress.IsActive = false;
            }
        }
    }

    /// The editor for a value that was read — the Mac's DeepSettingRow.
    /// A raw value that doesn't decode (or a read-only item) is shown as
    /// text.
    private FrameworkElement BuildEditor(DeepSettingItem item, string raw)
    {
        switch (item.ValueType, item.Decode(raw))
        {
            case (Toggle t, bool on):
            {
                var toggle = new ToggleSwitch { IsOn = on, OnContent = t.OnLabel, OffContent = t.OffLabel, MinWidth = 0 };
                toggle.Toggled += (_, _) => Send(item, item.Encode(toggle.IsOn));
                return toggle;
            }
            case (Enumeration e, int index):
            {
                var combo = new ComboBox { Width = 220 };
                foreach (var option in e.Cases)
                {
                    combo.Items.Add(option.Label);
                }
                var selected = e.Cases.ToList().FindIndex(c => c.Index == index);
                if (selected >= 0)
                {
                    combo.SelectedIndex = selected;
                }
                else
                {
                    // A value the catalog doesn't list: show it rather than
                    // a blank box, and let a pick overwrite it.
                    combo.PlaceholderText = $"({raw})";
                }
                combo.SelectionChanged += (_, _) =>
                {
                    if (combo.SelectedIndex >= 0)
                    {
                        Send(item, item.Encode(e.Cases[combo.SelectedIndex].Index));
                    }
                };
                return combo;
            }
            case (IntRange r, int value):
                return NumberEditor(item, value, r.Min, r.Max, r.Step, r.Unit);
            case (SignedRange r, int value):
                return NumberEditor(item, value, r.Min, r.Max, r.Step, r.Unit);
            case (Text t, string text):
            {
                var box = new TextBox { Text = text, MaxLength = t.MaxLength, Width = 260 };
                var sent = text;
                void Commit()
                {
                    if (box.Text != sent)
                    {
                        sent = box.Text;
                        Send(item, item.Encode(box.Text));
                    }
                }
                box.KeyDown += (_, e) =>
                {
                    if (e.Key == Windows.System.VirtualKey.Enter)
                    {
                        Commit();
                        e.Handled = true;
                    }
                };
                box.LostFocus += (_, _) => Commit();
                return box;
            }
            default:
                return Placeholder(raw.Length > 0 ? raw : "—");
        }
    }

    /// The Mac's Stepper: a spin box that sends each committed value
    /// (spin click, arrow key, or a typed value on Enter/focus loss),
    /// clamped to the range and snapped to the item's step.
    private FrameworkElement NumberEditor(DeepSettingItem item, int value, int min, int max, int step, string? unit)
    {
        var box = new NumberBox
        {
            Value = value,
            Minimum = min,
            Maximum = max,
            SmallChange = step,
            LargeChange = step * 10,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            Width = 150,
        };
        var last = value;
        box.ValueChanged += (_, args) =>
        {
            if (double.IsNaN(args.NewValue))
            {
                box.Value = last;
                return;
            }
            var snapped = Math.Clamp(min + (int)Math.Round((args.NewValue - min) / step) * step, min, max);
            if (snapped != args.NewValue)
            {
                box.Value = snapped; // re-enters with the snapped value
                return;
            }
            if (snapped != last)
            {
                last = snapped;
                Send(item, item.Encode(snapped));
            }
        };
        if (unit is null)
        {
            return box;
        }
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children = { box, new TextBlock { Text = unit, VerticalAlignment = VerticalAlignment.Center, Foreground = Secondary } },
        };
    }

    private async void Send(DeepSettingItem item, string? raw)
    {
        if (raw is null)
        {
            return;
        }
        try
        {
            await _client.SetMenuItemAsync(item.P1, item.P2, item.P3, raw);
            AppLog.Write($"deep settings: EX{item.P1:00}{item.P2:00}{item.P3:00}{raw} ({item.Label})");
            _status.Text = "";
        }
        catch (Exception ex)
        {
            _status.Text = $"{item.Label}: not sent ({ex.Message})";
        }
    }

    private static TextBlock Placeholder(string text) =>
        new() { Text = text, Foreground = Secondary, FontFamily = new FontFamily("Consolas"), MaxWidth = 320, TextTrimming = TextTrimming.CharacterEllipsis };
}

using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace FTX1RemoteWindows.Controls;

/// Port of the Mac's two Filter rows (Sources/FTX1Core/UI/
/// FilterWidthControl, IFShiftControl, ContourAPFControl, NarrowControl,
/// IFNotchControl, FilterSideSelector and FilterDisplayView), with the CAT
/// side of HubService/CommandQueue that drives them:
///
///   WIDTH (picker + narrower/wider)   SHIFT (slider + center)   MAIN   ┌display┐
///   CONTOUR or APF   N/W   NOTCH                                 SUB    └───────┘
///
/// Every command carries the selected receiver as P1 ("SH0"/"SH1", "IS00"/
/// "IS10", "BP0x"/"BP1x", "CO0x"/"CO1x", "NA0"/"NA1"), and the filter fields
/// in RigState hold that receiver's values. Picking MAIN/SUB clears them
/// and reads the new side at once; the slow poll tier re-reads the selected
/// side. SUB is disabled in single-receive display (the Mac's UX choice —
/// the rig still answers), and the panel falls back to MAIN if the rig goes
/// single-receive while SUB is selected.
///
/// Sliders send once, on release (or at once for keyboard changes), like
/// the main window's power slider and the Mac's onEditingChanged — a drag
/// across SHIFT's range would otherwise queue ~120 writes. Placing the
/// notch or contour/APF while it's off also turns it on (frequency first).
///
/// The display draws the passband shape only: the Mac overlays a live
/// audio spectrum from its FFT, which this app doesn't have yet (the
/// waterfall is deferred — see Apps/Windows/README.md).
///
/// Built in code like MenuGrid.
public sealed class FilterPanel : UserControl
{
    private readonly RigState _state;
    private RigctldClient? _client;

    /// Bumped around every command and on a side switch; a read that saw it
    /// change is dropped rather than overwriting newer values — the Mac's
    /// commandGeneration, as in MenuGrid.
    private int _generation;
    private bool _refreshInFlight;
    private bool _refreshPending;

    private bool _suppressWidthEvents;
    /// The width picker's items are rebuilt only when this changes.
    private string? _widthItemsKey;

    private readonly StackPanel _widthGroup = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly ComboBox _widthBox = new() { Width = 150, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _narrowerButton = IconButton("", "Narrower");
    private readonly Button _widerButton = IconButton("", "Wider");

    private readonly StackPanel _shiftGroup = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly CommitSlider _shiftSlider;
    private readonly TextBlock _shiftLabel = ValueLabel(64);
    private readonly Button _shiftCenterButton = IconButton("", "Center");

    private readonly ToggleSliderRow _contourRow;
    private readonly ToggleSliderRow _apfRow;
    private readonly ToggleButton _narrowToggle = new() { Content = "N/W", VerticalAlignment = VerticalAlignment.Center };
    private readonly ToggleSliderRow _notchRow;

    private readonly ToggleButton _mainSideButton = SideButton(FilterSide.Main);
    private readonly ToggleButton _subSideButton = SideButton(FilterSide.Sub);

    private readonly FilterDisplay _display = new();

    /// "FR" single-receive display, from MainWindow's slow tier; null
    /// until read (treated as dual, like the Mac).
    private bool? _singleReceive;

    /// A command or read failed; MainWindow shows it on its status line.
    public event Action<string>? StatusMessage;

    public FilterPanel(RigState state)
    {
        _state = state;

        AutomationProperties.SetName(_widthBox, "Filter width");
        _widthBox.SelectionChanged += (_, _) => OnWidthPicked();
        _narrowerButton.Click += (_, _) => StepWidth(narrower: true);
        _widerButton.Click += (_, _) => StepWidth(narrower: false);
        _widthGroup.Children.Add(Caption("Width"));
        _widthGroup.Children.Add(_widthBox);
        _widthGroup.Children.Add(_narrowerButton);
        _widthGroup.Children.Add(_widerButton);

        _shiftSlider = new CommitSlider(IFShift.Min, IFShift.Max, IFShift.StepHz, 180, "IF shift",
            rigValue: () => _state.IfShiftHz is { } hz ? IFShift.Snapped(hz) : null,
            onChanging: hz => _shiftLabel.Text = IFShift.Label(IFShift.Snapped(hz)),
            onCommit: hz => _ = SendShiftAsync(IFShift.Snapped(hz)));
        _shiftCenterButton.Click += (_, _) => _ = SendShiftAsync(0);
        _shiftGroup.Children.Add(Caption("Shift"));
        _shiftGroup.Children.Add(_shiftSlider.Slider);
        _shiftGroup.Children.Add(_shiftLabel);
        _shiftGroup.Children.Add(_shiftCenterButton);

        _contourRow = new ToggleSliderRow("Contour", "Contour on/off", IFContour.ContourMinHz, IFContour.ContourMaxHz,
            IFContour.StepHz, idleHz: IFContour.ContourMinHz,
            isOn: () => _state.ContourEnabled,
            valueHz: () => _state.ContourHz,
            label: IFContour.ContourLabel,
            snap: IFContour.SnappedContourHz,
            onToggle: on => _ = SendAsync("Contour", () => _state.ContourEnabled = on,
                (c, p1) => c.SetRawIntAsync($"CO{p1}0", on ? 1 : 0, 4)),
            onCommit: hz => _ = CommitToggleSliderAsync(IFContour.Face.Contour, "Contour",
                () => _state.ContourHz = hz, (c, p1) => c.SetRawIntAsync($"CO{p1}1", hz, 4),
                () => _state.ContourEnabled, () => _state.ContourEnabled = true,
                (c, p1) => c.SetRawIntAsync($"CO{p1}0", 1, 4)));
        _apfRow = new ToggleSliderRow("APF", "Audio peak filter on/off", IFContour.ApfMinHz, IFContour.ApfMaxHz,
            IFContour.StepHz, idleHz: 0,
            isOn: () => _state.ApfEnabled,
            valueHz: () => _state.ApfHz,
            label: IFContour.ApfLabel,
            snap: IFContour.SnappedApfHz,
            onToggle: on => _ = SendAsync("APF", () => _state.ApfEnabled = on,
                (c, p1) => c.SetRawIntAsync($"CO{p1}2", on ? 1 : 0, 4)),
            onCommit: hz => _ = CommitToggleSliderAsync(IFContour.Face.Apf, "APF",
                () => _state.ApfHz = hz, (c, p1) => c.SetRawIntAsync($"CO{p1}3", IFContour.ApfCode(hz), 4),
                () => _state.ApfEnabled, () => _state.ApfEnabled = true,
                (c, p1) => c.SetRawIntAsync($"CO{p1}2", 1, 4)));
        _notchRow = new ToggleSliderRow("Notch", "Manual notch on/off", IFNotch.MinHz, IFNotch.MaxHz,
            IFNotch.StepHz, idleHz: IFNotch.MinHz,
            isOn: () => _state.NotchEnabled,
            valueHz: () => _state.NotchHz,
            label: IFNotch.Label,
            snap: IFNotch.SnappedHz,
            onToggle: on => _ = SendAsync("Notch", () => _state.NotchEnabled = on,
                (c, p1) => c.SetRawIntAsync($"BP{p1}0", on ? 1 : 0, 3)),
            onCommit: hz => _ = CommitToggleSliderAsync(null, "Notch",
                () => _state.NotchHz = hz, (c, p1) => c.SetRawIntAsync($"BP{p1}1", IFNotch.Code(hz), 3),
                () => _state.NotchEnabled, () => _state.NotchEnabled = true,
                (c, p1) => c.SetRawIntAsync($"BP{p1}0", 1, 3)));

        ToolTipService.SetToolTip(_narrowToggle, "Narrow filter on/off");
        _narrowToggle.Click += (_, _) => _ = ToggleNarrowAsync();

        _mainSideButton.Click += (_, _) => SelectSide(FilterSide.Main);
        _subSideButton.Click += (_, _) => SelectSide(FilterSide.Sub);

        var row1 = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 20, Children = { _widthGroup, _shiftGroup } };
        var row2 = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 20,
            Children = { _contourRow.Panel, _apfRow.Panel, _narrowToggle, _notchRow.Panel },
        };
        var rows = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center, Children = { row1, row2 } };
        var sides = new StackPanel
        {
            Spacing = 4,
            Width = 58,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _mainSideButton, _subSideButton },
        };

        var layout = new Grid { ColumnSpacing = 16 };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(sides, 1);
        Grid.SetColumn(_display, 2);
        layout.Children.Add(rows);
        layout.Children.Add(sides);
        layout.Children.Add(_display);
        Content = layout;

        IsEnabled = false;
        RefreshUI();
    }

    /// Set on connect, null on disconnect; the panel is disabled without one.
    public RigctldClient? Client
    {
        get => _client;
        set
        {
            _client = value;
            IsEnabled = value is not null;
            RefreshUI();
        }
    }

    /// From MainWindow's "FR" read. Going single-receive while SUB is
    /// selected falls back to MAIN.
    public bool? SingleReceive
    {
        get => _singleReceive;
        set
        {
            _singleReceive = value;
            if (value == true && _state.FilterSide == FilterSide.Sub)
            {
                AppLog.Write("filter: single-receive display while SUB selected — falling back to MAIN");
                SelectSide(FilterSide.Main);
            }
            RefreshUI();
        }
    }

    /// A new session starts from unread values; the selected side is kept.
    public void ClearState()
    {
        ClearFilterFields();
        _state.SubMode = null;
        _singleReceive = null;
        RefreshUI();
    }

    private void ClearFilterFields()
    {
        _state.FilterWidthIndex = null;
        _state.IfShiftHz = null;
        _state.NotchEnabled = null;
        _state.NotchHz = null;
        _state.ContourEnabled = null;
        _state.ContourHz = null;
        _state.ApfEnabled = null;
        _state.ApfHz = null;
        _state.NarrowEnabled = null;
        _state.NarrowWidthHz = null;
    }

    // Reads

    /// Reads the selected side's filter state — the slow poll tier, and the
    /// fast paths below. Same in-flight/pending shape as MenuGrid's: a
    /// request mid-read runs again when that one finishes.
    public async Task RefreshFromRigAsync(RigctldClient client)
    {
        if (_refreshInFlight)
        {
            _refreshPending = true;
            return;
        }
        _refreshInFlight = true;
        try
        {
            do
            {
                _refreshPending = false;
                var generationAtStart = _generation;
                var side = _state.FilterSide;
                var apply = await ReadFilterStateAsync(client, side);
                if (generationAtStart == _generation && side == _state.FilterSide && ReferenceEquals(client, _client))
                {
                    apply();
                    RefreshUI();
                }
            }
            while (_refreshPending && ReferenceEquals(client, _client));
        }
        finally
        {
            _refreshInFlight = false;
        }
    }

    /// Re-reads the selected side soon, rather than at the next slow tier:
    /// after a MAIN/SUB switch, or a VFO swap (whether a receiver's filter
    /// travels with the VFO or stays put, the read shows what's there now).
    public void RequestRefresh(TimeSpan delay)
    {
        if (_client is not { } client)
        {
            return;
        }
        _ = RefreshAfterDelayAsync(client, delay);
    }

    private async Task RefreshAfterDelayAsync(RigctldClient client, TimeSpan delay)
    {
        await Task.Delay(delay);
        if (ReferenceEquals(client, _client))
        {
            await RefreshFromRigAsync(client);
        }
    }

    /// One read of <paramref name="side"/>'s filter fields (HubService.
    /// readFilterState), each best-effort: a failed read keeps the last
    /// known value when applied. For SUB, "MD1" comes first — the NAR WIDTH
    /// preset is per mode, and the slow tier's Sub mode can be ~5 s old.
    private async Task<Action> ReadFilterStateAsync(RigctldClient client, FilterSide side)
    {
        var p1 = side.P1();
        char? subModeCode = null;
        var mode = _state.FilterModeFor(side);
        if (side == FilterSide.Sub)
        {
            subModeCode = await ReadOrNull(() => client.GetModeCodeAsync(sub: true));
            if (subModeCode is { } code)
            {
                mode = code is 'H' or 'I' ? null : RigModeExtensions.FromCatModeCode(code) ?? _state.SubMode;
            }
        }

        // "SH<p1>": the reply's P2 ("0") lands as the value's leading digit,
        // dropped for free by the int parse.
        var width = await ReadOrNull(() => client.GetRawIntAsync($"SH{p1}"));
        var shift = await ReadOrNull(() => client.GetIFShiftHzAsync((int)side));
        // 3- and 4-digit on/off fields, so ints (!= 0), never GetRawBoolAsync.
        var notchRaw = await ReadOrNull(() => client.GetRawIntAsync($"BP{p1}0"));
        var notchCode = await ReadOrNull(() => client.GetRawIntAsync($"BP{p1}1"));
        var contourRaw = await ReadOrNull(() => client.GetRawIntAsync($"CO{p1}0"));
        var contourHz = await ReadOrNull(() => client.GetRawIntAsync($"CO{p1}1"));
        var apfRaw = await ReadOrNull(() => client.GetRawIntAsync($"CO{p1}2"));
        var apfCode = await ReadOrNull(() => client.GetRawIntAsync($"CO{p1}3"));
        var narrow = await ReadOrNull(() => client.GetRawBoolAsync($"NA{p1}"));
        int? narrowWidth = null;
        if (NarrowWidthPreset.Item(mode) is { } item
            && await ReadStringOrNull(() => client.GetMenuItemAsync(item.P1, item.P2, item.P3)) is { } raw)
        {
            narrowWidth = NarrowWidthPreset.Hz(raw, mode);
        }
        // The CW pitch places the passband and the APF peak. The MENU grid
        // reads it too, but only while its CW page is showing.
        var pitchCode = mode == RigMode.Cw ? await ReadOrNull(() => client.GetRawIntAsync("KP")) : null;

        return () =>
        {
            if (subModeCode is { } code)
            {
                _state.SubIsC4fm = code is 'H' or 'I';
                _state.SubMode = RigModeExtensions.FromCatModeCode(code) ?? _state.SubMode;
            }
            _state.FilterWidthIndex = width ?? _state.FilterWidthIndex;
            _state.IfShiftHz = shift ?? _state.IfShiftHz;
            _state.NotchEnabled = notchRaw is { } n ? n != 0 : _state.NotchEnabled;
            _state.NotchHz = notchCode is { } nc ? IFNotch.HzForCode(nc) ?? _state.NotchHz : _state.NotchHz;
            _state.ContourEnabled = contourRaw is { } c ? c != 0 : _state.ContourEnabled;
            _state.ContourHz = contourHz is { } ch and >= IFContour.ContourMinHz and <= IFContour.ContourMaxHz ? ch : _state.ContourHz;
            _state.ApfEnabled = apfRaw is { } a ? a != 0 : _state.ApfEnabled;
            _state.ApfHz = apfCode is { } ac ? IFContour.ApfHzForCode(ac) ?? _state.ApfHz : _state.ApfHz;
            _state.NarrowEnabled = narrow ?? _state.NarrowEnabled;
            // Cleared (not held over) in a mode without a preset, so AM/FM
            // never inherit an SSB value.
            _state.NarrowWidthHz = NarrowWidthPreset.Item(mode) is null ? null : narrowWidth ?? _state.NarrowWidthHz;
            _state.CwPitchHz = pitchCode is { } p ? 300 + p * 10 : _state.CwPitchHz;
        };
    }

    private static async Task<T?> ReadOrNull<T>(Func<Task<T?>> read) where T : struct
    {
        try
        {
            return await read();
        }
        catch (Exception ex)
        {
            AppLog.Write($"filter: read failed: {ex.Message}");
            return null;
        }
    }

    private static async Task<string?> ReadStringOrNull(Func<Task<string?>> read)
    {
        try
        {
            return await read();
        }
        catch (Exception ex)
        {
            AppLog.Write($"filter: read failed: {ex.Message}");
            return null;
        }
    }

    // Commands

    /// Applies <paramref name="applyOptimistic"/> and sends <paramref
    /// name="command"/> to the selected side (its P1 digit is passed in).
    /// The side is read here, on the UI thread, so a MAIN/SUB switch just
    /// before can't be overtaken.
    private async Task SendAsync(string what, Action applyOptimistic, Func<RigctldClient, string, Task> command)
    {
        if (_client is not { } client)
        {
            RefreshUI();
            return;
        }
        var p1 = _state.FilterSide.P1();
        _generation++;
        applyOptimistic();
        RefreshUI();
        try
        {
            await command(client, p1);
        }
        catch (Exception ex)
        {
            StatusMessage?.Invoke($"{what} failed: {ex.Message}");
        }
        _generation++;
    }

    private void OnWidthPicked()
    {
        if (_suppressWidthEvents || _widthBox.SelectedItem is not ComboBoxItem { Tag: int index })
        {
            return;
        }
        // Re-picking the current value or the stale-value fallback entry
        // sends nothing.
        var mode = _state.FilterMode;
        if (index == (_state.FilterWidthIndex ?? 0) || FilterWidthTable.Entries(mode).All(e => e.Index != index))
        {
            return;
        }
        _ = SendWidthAsync(index);
    }

    private void StepWidth(bool narrower)
    {
        if (FilterWidthTable.NeighborIndex(_state.FilterWidthIndex ?? 0, _state.FilterMode, narrower) is { } target)
        {
            _ = SendWidthAsync(target);
        }
    }

    /// 3 digits: P2 ("0") + the 2-digit index, e.g. "SH0017".
    private Task SendWidthAsync(int index) =>
        SendAsync("Filter width", () => _state.FilterWidthIndex = index, (c, p1) => c.SetRawIntAsync($"SH{p1}", index, 3));

    private Task SendShiftAsync(int hz) =>
        SendAsync("IF shift", () => _state.IfShiftHz = hz, (c, p1) => c.SetIFShiftHzAsync(int.Parse(p1), hz));

    /// A slider released on notch/contour/APF: the frequency, then "on" if
    /// it was off, so it appears where it was dropped. Dropped if a mode
    /// change switched CONTOUR ↔ APF mid-drag, so a contour frequency is
    /// never sent as an APF offset.
    private async Task CommitToggleSliderAsync(IFContour.Face? face, string what,
        Action applyValue, Func<RigctldClient, string, Task> sendValue,
        Func<bool?> isOn, Action applyOn, Func<RigctldClient, string, Task> sendOn)
    {
        if (face is { } f && IFContour.FaceFor(_state.FilterMode) != f)
        {
            RefreshUI();
            return;
        }
        await SendAsync(what, applyValue, sendValue);
        if (isOn() != true)
        {
            await SendAsync(what, applyOn, sendOn);
        }
    }

    /// NARROW moves the passband to the mode's narrow preset, so re-read
    /// the width right behind the write instead of waiting for the slow
    /// tier (HubService.refreshWidthAfterNarrow).
    private async Task ToggleNarrowAsync()
    {
        var on = _state.NarrowEnabled != true;
        await SendAsync("Narrow", () => _state.NarrowEnabled = on, (c, p1) => c.SetRawBoolAsync($"NA{p1}", on));
        if (_client is not { } client)
        {
            return;
        }
        var side = _state.FilterSide;
        var mode = _state.FilterMode;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            await Task.Delay(300);
            if (await ReadOrNull(() => client.GetRawIntAsync($"SH{side.P1()}")) is not { } width)
            {
                continue;
            }
            // In SSB/CW/RTTY/DATA "SH" doesn't move with NARROW — the
            // narrowed bandwidth is the mode's NAR WIDTH preset.
            int? presetHz = null;
            if (NarrowWidthPreset.Item(mode) is { } item
                && await ReadStringOrNull(() => client.GetMenuItemAsync(item.P1, item.P2, item.P3)) is { } raw)
            {
                presetHz = NarrowWidthPreset.Hz(raw, mode);
            }
            if (_state.FilterSide != side || !ReferenceEquals(client, _client))
            {
                return;
            }
            _generation++;
            _state.FilterWidthIndex = width;
            if (presetHz is { } hz)
            {
                _state.NarrowWidthHz = hz;
            }
            RefreshUI();
            return;
        }
    }

    private void SelectSide(FilterSide side)
    {
        if (side == FilterSide.Sub && _singleReceive == true)
        {
            RefreshUI();
            return;
        }
        if (side != _state.FilterSide)
        {
            AppLog.Write($"filter: {side.DisplayName()} selected");
            _generation++;
            _state.FilterSide = side;
            ClearFilterFields();
            RequestRefresh(TimeSpan.FromMilliseconds(200));
        }
        RefreshUI();
    }

    // UI

    /// Re-renders every control and the display from RigState. Called after
    /// each poll, read and command.
    public void RefreshUI()
    {
        var mode = _state.FilterMode;
        var hasFilter = mode is not null;

        // WIDTH
        var entries = FilterWidthTable.Entries(mode);
        _widthGroup.Visibility = entries.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var current = _state.FilterWidthIndex ?? 0;
        var inColumn = entries.Any(e => e.Index == current);
        // Right after a mode change (or before any read) the value may not be
        // in this mode's column; it gets its own "—"/"Default" entry rather
        // than a blank picker.
        var key = $"{mode}|{(inColumn ? "" : FilterWidthTable.Label(_state.FilterWidthIndex, mode))}";
        _suppressWidthEvents = true;
        if (key != _widthItemsKey)
        {
            _widthItemsKey = key;
            _widthBox.Items.Clear();
            if (!inColumn)
            {
                _widthBox.Items.Add(new ComboBoxItem { Content = FilterWidthTable.Label(_state.FilterWidthIndex, mode), Tag = current });
            }
            foreach (var entry in entries)
            {
                _widthBox.Items.Add(new ComboBoxItem { Content = $"{entry.Hz} Hz", Tag = entry.Index });
            }
        }
        _widthBox.SelectedItem = _widthBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag is int t && t == current);
        _suppressWidthEvents = false;
        var adjustable = FilterWidthTable.IsAdjustable(mode);
        _widthBox.IsEnabled = adjustable;
        _narrowerButton.IsEnabled = adjustable && FilterWidthTable.NeighborIndex(current, mode, narrower: true) is not null;
        _widerButton.IsEnabled = adjustable && FilterWidthTable.NeighborIndex(current, mode, narrower: false) is not null;

        // SHIFT. Snapped for display: in AM the rig answers an off-grid
        // "IS00-0001;" (Mac, 2026-09-13).
        _shiftGroup.Visibility = hasFilter ? Visibility.Visible : Visibility.Collapsed;
        var shiftSupported = IFShift.IsSupported(mode);
        _shiftSlider.Slider.IsEnabled = shiftSupported;
        var shift = _state.IfShiftHz is { } s ? IFShift.Snapped(s) : (int?)null;
        _shiftSlider.SetFromRig(shift, idle: 0);
        if (!_shiftSlider.IsDragging)
        {
            _shiftLabel.Text = IFShift.Label(shift);
        }
        _shiftCenterButton.IsEnabled = shiftSupported && shift is { } sh && sh != 0;

        // CONTOUR or APF
        var face = IFContour.FaceFor(mode);
        _contourRow.Update(visible: face == IFContour.Face.Contour, enabled: IFContour.ContourSupported(mode));
        _apfRow.Update(visible: face == IFContour.Face.Apf, enabled: IFContour.ApfSupported(mode));

        // N/W — enabled in AM/FM too: NARROW is the only width change there.
        _narrowToggle.Visibility = hasFilter ? Visibility.Visible : Visibility.Collapsed;
        _narrowToggle.IsChecked = _state.NarrowEnabled == true;
        _narrowToggle.IsEnabled = _state.NarrowEnabled is not null;

        // NOTCH
        _notchRow.Update(visible: hasFilter, enabled: IFNotch.IsSupported(mode));

        // MAIN / SUB
        _mainSideButton.IsChecked = _state.FilterSide == FilterSide.Main;
        _subSideButton.IsChecked = _state.FilterSide == FilterSide.Sub;
        _subSideButton.IsEnabled = _singleReceive != true;
        ToolTipService.SetToolTip(_subSideButton, _singleReceive == true
            ? "SUB receiver isn't shown in single-receive display"
            : "Apply the filter controls to the SUB receiver");

        _display.Update(new FilterPassbandModel(_state), isActive: _client is not null);
    }

    private static TextBlock Caption(string text) => new() { Text = text, VerticalAlignment = VerticalAlignment.Center };

    private static TextBlock ValueLabel(double minWidth) => new()
    {
        MinWidth = minWidth,
        TextAlignment = TextAlignment.Right,
        FontFamily = new FontFamily("Consolas"),
        VerticalAlignment = VerticalAlignment.Center,
        Text = "—",
    };

    private static Button IconButton(string glyph, string help)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 12 },
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(button, help);
        AutomationProperties.SetName(button, help);
        return button;
    }

    private static ToggleButton SideButton(FilterSide side)
    {
        var button = new ToggleButton
        {
            Content = new TextBlock { Text = side.DisplayName(), FontSize = 11, FontWeight = FontWeights.SemiBold },
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
        };
        AutomationProperties.SetName(button, $"Filter {side.DisplayName()}");
        if (side == FilterSide.Main)
        {
            ToolTipService.SetToolTip(button, "Apply the filter controls to the MAIN receiver");
        }
        return button;
    }

    /// A slider that reports a value once per drag (on release) or at once
    /// for keyboard changes, and that the poll leaves alone mid-drag. The
    /// Thumb marks its pointer events handled, hence handledEventsToo — the
    /// same approach as MainWindow's power slider.
    private sealed class CommitSlider
    {
        public Slider Slider { get; }
        public bool IsDragging { get; private set; }

        private readonly Func<int?> _rigValue;
        private readonly Action<int> _onChanging;
        private readonly Action<int> _onCommit;
        private bool _suppress;

        public CommitSlider(int min, int max, int step, double width, string name,
            Func<int?> rigValue, Action<int> onChanging, Action<int> onCommit)
        {
            _rigValue = rigValue;
            _onChanging = onChanging;
            _onCommit = onCommit;
            Slider = new Slider
            {
                Minimum = min,
                Maximum = max,
                StepFrequency = step,
                SmallChange = step,
                LargeChange = step * 10,
                Width = width,
                VerticalAlignment = VerticalAlignment.Center,
                IsThumbToolTipEnabled = false,
            };
            AutomationProperties.SetName(Slider, name);
            Slider.ValueChanged += (_, e) =>
            {
                if (_suppress)
                {
                    return;
                }
                _onChanging((int)e.NewValue);
                if (!IsDragging)
                {
                    _onCommit((int)e.NewValue);
                }
            };
            Slider.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => IsDragging = true), true);
            Slider.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => Done()), true);
            Slider.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler((_, _) => Done()), true);
        }

        private void Done()
        {
            if (!IsDragging)
            {
                return;
            }
            IsDragging = false;
            var value = (int)Slider.Value;
            // A click that didn't move the thumb sends nothing.
            if (_rigValue() == value)
            {
                return;
            }
            _onCommit(value);
        }

        /// Moves the thumb to the rig's value (<paramref name="idle"/> before
        /// the first read) without sending it back; skipped mid-drag.
        public void SetFromRig(int? value, int idle)
        {
            if (IsDragging)
            {
                return;
            }
            _suppress = true;
            Slider.Value = value ?? idle;
            _suppress = false;
        }
    }

    /// Toggle button (checked = on) + slider + label for one on/off-plus-
    /// frequency function: CONTOUR, APF, NOTCH (the Mac's
    /// FilterToggleSlider/IFNotchControl). Before the first read the button
    /// is disabled, the slider parked at idleHz, the label "—".
    private sealed class ToggleSliderRow
    {
        public StackPanel Panel { get; } = new() { Orientation = Orientation.Horizontal, Spacing = 6 };

        private readonly ToggleButton _toggle;
        private readonly CommitSlider _slider;
        private readonly TextBlock _label = ValueLabel(58);
        private readonly Func<bool?> _isOn;
        private readonly Func<int?> _valueHz;
        private readonly Func<int?, string> _labelFor;
        private readonly int _idleHz;

        public ToggleSliderRow(string title, string help, int min, int max, int step, int idleHz,
            Func<bool?> isOn, Func<int?> valueHz, Func<int?, string> label, Func<int, int> snap,
            Action<bool> onToggle, Action<int> onCommit)
        {
            _isOn = isOn;
            _valueHz = valueHz;
            _labelFor = label;
            _idleHz = idleHz;
            // Fixed width so CONTOUR ↔ APF doesn't shift the rest of the row
            // (and the selector and display after it).
            _toggle = new ToggleButton { Content = title, MinWidth = 84, VerticalAlignment = VerticalAlignment.Center };
            ToolTipService.SetToolTip(_toggle, help);
            _toggle.Click += (_, _) => onToggle(_isOn() != true);
            _slider = new CommitSlider(min, max, step, 160, $"{title} frequency",
                rigValue: valueHz,
                onChanging: hz => _label.Text = label(snap(hz)),
                onCommit: hz => onCommit(snap(hz)));
            Panel.Children.Add(_toggle);
            Panel.Children.Add(_slider.Slider);
            Panel.Children.Add(_label);
        }

        public void Update(bool visible, bool enabled)
        {
            Panel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            var on = _isOn();
            _toggle.IsChecked = on == true;
            _toggle.IsEnabled = enabled && on is not null;
            _slider.Slider.IsEnabled = enabled;
            _slider.SetFromRig(_valueHz(), _idleHz);
            if (!_slider.IsDragging)
            {
                _label.Text = _labelFor(_valueHz());
            }
            Panel.Opacity = on == true ? 1 : 0.7;
        }
    }
}

/// The Filter Function Display (the Mac's FilterDisplayView): passband
/// trapezoid (WIDTH/SHIFT), the notch as a narrow cut, contour as a rounded
/// dip, APF as a peak, the per-mode top markers (P / M S / C / the SSB
/// bandwidth dot) and mode/width captions, on a fixed 0-4000 Hz span. Plain
/// XAML shapes in the Mac's 240×64 box, redrawn from a FilterPassbandModel
/// on every update (a few shapes, only when the state is refreshed). Dims
/// while disconnected, like the Mac's isActive.
internal sealed class FilterDisplay : UserControl
{
    private const double W = 240;
    private const double H = 64;
    private const double Baseline = H - 14; // room for the captions
    private const double Top = 12;          // room for the top markers

    private static readonly Color Orange = Color.FromArgb(255, 255, 149, 0);
    private static readonly FontFamily CaptionFont = new("Consolas");

    private readonly Canvas _canvas = new() { Width = W, Height = H };

    public FilterDisplay()
    {
        Content = new Border
        {
            Width = W,
            Height = H,
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Colors.Black),
            BorderBrush = new SolidColorBrush(Color.FromArgb(102, 128, 128, 128)),
            BorderThickness = new Thickness(1.5),
            VerticalAlignment = VerticalAlignment.Center,
            Child = _canvas,
        };
        _canvas.Clip = new RectangleGeometry { Rect = new Rect(0, 0, W, H) };
        ToolTipService.SetToolTip(this, "Filter function display: passband (WIDTH/SHIFT), notch, contour/APF");
        AutomationProperties.SetName(this, "Filter function display");
    }

    public void Update(FilterPassbandModel model, bool isActive)
    {
        Opacity = isActive ? 1 : 0.4;
        var children = _canvas.Children;
        children.Clear();

        if (model.Passband is { } band)
        {
            var lo = FilterPassbandModel.X(band.Low, W);
            var hi = FilterPassbandModel.X(band.High, W);
            var skirt = W * 0.04;
            children.Add(new Polygon
            {
                Points =
                {
                    new Point(Math.Max(lo - skirt, 0), Baseline),
                    new Point(lo, Top),
                    new Point(hi, Top),
                    new Point(Math.Min(hi + skirt, W), Baseline),
                },
                Fill = Tint(Colors.White, 0.18),
                Stroke = Tint(Colors.White, 0.85),
                StrokeThickness = 1,
            });
        }

        if (model.ContourHz is { } contour)
        {
            var x = FilterPassbandModel.X(contour, W);
            const double halfWidth = 14;
            var depth = (Baseline - Top) * 0.45;
            children.Add(QuadPath(new Point(x - halfWidth, Top - 1), new Point(x, Top + depth * 2), new Point(x + halfWidth, Top - 1),
                closed: true, fill: Tint(Colors.Black, 1), stroke: null));
            children.Add(QuadPath(new Point(x - halfWidth, Top), new Point(x, Top + depth * 2), new Point(x + halfWidth, Top),
                closed: false, fill: null, stroke: Tint(Orange, 1)));
        }
        if (model.NotchHz is { } notch)
        {
            var x = FilterPassbandModel.X(notch, W);
            children.Add(new Polygon
            {
                Points = { new Point(x - 4, Top - 1), new Point(x + 4, Top - 1), new Point(x, Baseline) },
                Fill = Tint(Colors.Black, 1),
            });
            children.Add(new Line { X1 = x, Y1 = Top, X2 = x, Y2 = Baseline, Stroke = Tint(Colors.Red, 0.9), StrokeThickness = 1 });
        }
        if (model.ApfHz is { } apf)
        {
            var x = FilterPassbandModel.X(apf, W);
            children.Add(QuadPath(new Point(x - 5, Top), new Point(x, Top - 12), new Point(x + 5, Top),
                closed: true, fill: Tint(Orange, 0.7), stroke: Tint(Orange, 1)));
        }

        foreach (var marker in model.Markers)
        {
            var x = FilterPassbandModel.X(marker.Hz, W);
            if (marker.Label is { } label)
            {
                children.Add(new Line { X1 = x, Y1 = Top, X2 = x, Y2 = Baseline, Stroke = Tint(Colors.White, 0.5), StrokeThickness = 1 });
                var box = new Border
                {
                    Width = 10,
                    Height = 10,
                    CornerRadius = new CornerRadius(2),
                    Background = Tint(Colors.White, 0.85),
                    Child = new TextBlock
                    {
                        Text = label,
                        FontSize = 8,
                        FontWeight = FontWeights.Bold,
                        Foreground = Tint(Colors.Black, 1),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                };
                Canvas.SetLeft(box, x - 5);
                Canvas.SetTop(box, 1);
                children.Add(box);
            }
            else
            {
                var dot = new Ellipse { Width = 6, Height = 6, Fill = Tint(Colors.White, 0.9) };
                Canvas.SetLeft(dot, x - 3);
                Canvas.SetTop(dot, Top - 3);
                children.Add(dot);
            }
        }

        children.Add(Caption(model.ModeName, TextAlignment.Left));
        children.Add(Caption(model.WidthLabel, TextAlignment.Right));
    }

    private static TextBlock Caption(string text, TextAlignment alignment)
    {
        var caption = new TextBlock
        {
            Text = text,
            Width = W - 12,
            TextAlignment = alignment,
            FontSize = 9,
            FontFamily = CaptionFont,
            FontWeight = FontWeights.Medium,
            Foreground = new SolidColorBrush(Colors.Gray),
        };
        Canvas.SetLeft(caption, 6);
        Canvas.SetTop(caption, H - 13);
        return caption;
    }

    private static Microsoft.UI.Xaml.Shapes.Path QuadPath(Point start, Point control, Point end, bool closed, Brush? fill, Brush? stroke)
    {
        var figure = new PathFigure { StartPoint = start, IsClosed = closed, IsFilled = fill is not null };
        figure.Segments.Add(new QuadraticBezierSegment { Point1 = control, Point2 = end });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Fill = fill, Stroke = stroke, StrokeThickness = 1 };
    }

    private static SolidColorBrush Tint(Color color, double opacity) =>
        new(Color.FromArgb((byte)Math.Round(opacity * 255), color.R, color.G, color.B));
}

using System.Globalization;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace FTX1RemoteWindows.Controls;

/// What a VFO box's flyout needs to know when it opens.
internal readonly record struct VfoEntryState(bool CanEdit, bool Memory, long Hz, int? Channel);

/// Port of the Mac's tap-the-frequency popovers (FrequencyEntryView and
/// MemoryChannelEntryView, presented by VFODisplayBox): clicking a VFO's
/// frequency opens a flyout with a text field + Set and up/down arrows —
/// MHz plus a 100 Hz / 1 kHz / 10 kHz step in VFO mode, a channel number
/// plus channel up/down in Memory mode. One instance per VFO box; the
/// callbacks are the main window's, so Main and Sub share this code.
///
/// Frequency steps are computed here and applied at once (pure arithmetic,
/// like the Mac's); channel steps are left to the rig, which resolves what
/// up/down means (blank channels, wrap).
internal sealed class VfoEntryFlyout
{
    /// Memory channels 1-999 (RigState.swift's memoryChannelRange): the CAT
    /// manual's "MC" entry says 99, but its MR/MW/MZ entries say 999, and
    /// the user's rig has 278 programmed.
    private const int MinChannel = 1;
    private const int MaxChannel = 999;

    private readonly FrameworkElement _anchor;
    private readonly Func<VfoEntryState> _getState;
    private readonly Func<long, Task> _setFrequency;
    private readonly Func<int, Task> _setChannel;
    private readonly Func<bool, Task> _stepChannel;
    private readonly Action<string> _showError;

    public VfoEntryFlyout(
        FrameworkElement anchor,
        Func<VfoEntryState> getState,
        Func<long, Task> setFrequency,
        Func<int, Task> setChannel,
        Func<bool, Task> stepChannel,
        Action<string> showError)
    {
        _anchor = anchor;
        _getState = getState;
        _setFrequency = setFrequency;
        _setChannel = setChannel;
        _stepChannel = stepChannel;
        _showError = showError;
        anchor.Tapped += (_, _) => Open();
        ToolTipService.SetToolTip(anchor, "Click to enter a frequency or memory channel");
    }

    private void Open()
    {
        var state = _getState();
        if (!state.CanEdit)
        {
            return;
        }
        var flyout = new Flyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Bottom };
        flyout.Content = state.Memory ? BuildChannelContent(flyout, state) : BuildFrequencyContent(flyout, state);
        flyout.ShowAt(_anchor);
    }

    private UIElement BuildFrequencyContent(Flyout flyout, VfoEntryState state)
    {
        var currentHz = state.Hz;
        var box = new TextBox
        {
            Width = 140,
            PlaceholderText = "MHz",
            Text = FormatMHz(currentHz),
        };
        async Task CommitAsync()
        {
            if (ParseMHz(box.Text) is not { } hz)
            {
                _showError("Enter a frequency in MHz.");
                return;
            }
            flyout.Hide();
            await RunAsync(() => _setFrequency(hz), "Set frequency failed");
        }
        box.KeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                await CommitAsync();
            }
        };
        var set = new Button { Content = "Set" };
        set.Click += async (_, _) => await CommitAsync();

        var step = new ComboBox { Width = 220, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var (label, hz) in new[] { ("10 Hz", 10), ("100 Hz", 100), ("1 kHz", 1_000), ("10 kHz", 10_000) })
        {
            step.Items.Add(new ComboBoxItem { Content = label, Tag = hz });
        }
        step.SelectedIndex = AppSettings.FrequencyStepHz switch { 10 => 0, 100 => 1, 10_000 => 3, _ => 2 };
        step.SelectionChanged += (_, _) =>
        {
            if (step.SelectedItem is ComboBoxItem { Tag: int hz })
            {
                AppSettings.FrequencyStepHz = hz;
            }
        };

        async Task StepAsync(int direction)
        {
            var stepHz = step.SelectedItem is ComboBoxItem { Tag: int hz } ? hz : 1_000;
            currentHz = Math.Max(0, currentHz + direction * stepHz);
            box.Text = FormatMHz(currentHz);
            await RunAsync(() => _setFrequency(currentHz), "Set frequency failed");
        }

        return Layout(
            Row(box, set),
            step,
            UpDown(() => StepAsync(-1), () => StepAsync(1), "Step down", "Step up"));
    }

    private UIElement BuildChannelContent(Flyout flyout, VfoEntryState state)
    {
        var box = new TextBox
        {
            Width = 100,
            PlaceholderText = $"Ch {MinChannel}-{MaxChannel}",
            Text = state.Channel?.ToString(CultureInfo.InvariantCulture) ?? "",
        };
        async Task CommitAsync()
        {
            if (!int.TryParse(box.Text.Trim(), out var channel) || channel is < MinChannel or > MaxChannel)
            {
                _showError($"Enter a memory channel from {MinChannel} to {MaxChannel}.");
                return;
            }
            flyout.Hide();
            await RunAsync(() => _setChannel(channel), "Set memory channel failed");
        }
        box.KeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                await CommitAsync();
            }
        };
        var set = new Button { Content = "Set" };
        set.Click += async (_, _) => await CommitAsync();

        // The channel isn't read back here: the rig resolves the step (and
        // ignores a set to a blank channel), so the box shows nothing new
        // until the flyout is reopened after the next poll.
        return Layout(
            Row(box, set),
            UpDown(() => RunAsync(() => _stepChannel(false), "Memory channel step failed"),
                   () => RunAsync(() => _stepChannel(true), "Memory channel step failed"),
                   "Previous channel", "Next channel"));
    }

    private async Task RunAsync(Func<Task> action, string failure)
    {
        try
        {
            await action();
        }
        catch (Exception ex)
        {
            _showError($"{failure}: {ex.Message}");
        }
    }

    private static StackPanel Layout(params UIElement[] rows)
    {
        var panel = new StackPanel { Spacing = 12 };
        foreach (var row in rows)
        {
            panel.Children.Add(row);
        }
        return panel;
    }

    private static StackPanel Row(params UIElement[] items)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var item in items)
        {
            row.Children.Add(item);
        }
        return row;
    }

    private static StackPanel UpDown(Func<Task> down, Func<Task> up, string downName, string upName)
    {
        Button Arrow(string glyph, string name, Func<Task> action)
        {
            var button = new Button
            {
                Width = 48,
                Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            };
            AutomationProperties.SetName(button, name);
            ToolTipService.SetToolTip(button, name);
            button.Click += async (_, _) => await action();
            return button;
        }
        var row = Row(Arrow("", downName, down), Arrow("", upName, up));
        row.HorizontalAlignment = HorizontalAlignment.Center;
        row.Spacing = 20;
        return row;
    }

    private static string FormatMHz(long hz) =>
        (hz / 1_000_000.0).ToString("0.000000", CultureInfo.InvariantCulture);

    /// MHz as typed ("14.074"), or in the display's own grouping
    /// ("14.074.000" = MHz.kHz.Hz).
    private static long? ParseMHz(string text)
    {
        text = text.Trim();
        var parts = text.Split('.');
        if (parts.Length == 3
            && long.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var mhz)
            && parts[1].Length == 3 && parts[2].Length == 3
            && long.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var khz)
            && long.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var hz))
        {
            return mhz * 1_000_000 + khz * 1_000 + hz;
        }
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            && double.IsFinite(value) && value > 0)
        {
            return (long)Math.Round(value * 1_000_000);
        }
        return null;
    }
}

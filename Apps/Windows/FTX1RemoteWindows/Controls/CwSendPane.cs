using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace FTX1RemoteWindows.Controls;

/// What the CW window needs from MainWindow beyond the receiver and sender.
public sealed class CwWindowLink
{
    /// Single-receive display ("FR"); null if not read or disconnected.
    public required Func<bool?> SingleReceive { get; init; }
    /// Break-in ("BI"); null if not read or disconnected.
    public required Func<bool?> BreakIn { get; init; }
    public required Action<bool> SetBreakIn { get; init; }
    public required Action<int> SetSpeed { get; init; }
    /// The side the rig transmits on (SUB's with TX:SUB or split), for the
    /// Log QSO pane; null while disconnected.
    public required Func<CwTransmitter?> Transmitter { get; init; }
}

/// The CW window's send pane — the Mac's CWSendPane (Apps/Mac/
/// FTX1RemoteMac/CWSendPane.swift): keyer speed, BK-IN and memory slot in
/// the header with Macros… / Clear / Stop, the macro buttons, a log of
/// what's queued, keying and sent, a status line, and the line to type into
/// (Enter queues it). A macro fills the line rather than sending, so it can
/// be edited first. Their call ({CALL}) is in the Log QSO pane below, as on
/// the Mac. Driven by <see cref="CwSender"/>.
public sealed class CwSendPane : UserControl
{
    private readonly CwSender _sender;
    private readonly CwWindowLink _link;

    private readonly TextBlock _speedText = new() { MinWidth = 56, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _slowerButton = new() { Content = "−", MinWidth = 32, Padding = new Thickness(6, 2, 6, 4) };
    private readonly Button _fasterButton = new() { Content = "+", MinWidth = 32, Padding = new Thickness(6, 2, 6, 4) };
    private readonly ToggleButton _breakInButton = new() { Content = "BK-IN" };
    private readonly ComboBox _slotBox = new();
    private readonly Button _clearButton = new();
    private readonly Button _stopButton = new();

    private readonly StackPanel _macroRow = new() { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(16, 8, 16, 8) };
    private readonly ScrollViewer _logScroller = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(16, 10, 16, 10) };
    private readonly StackPanel _log = new() { Spacing = 4 };

    private readonly StackPanel _status = new() { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(16, 6, 16, 6) };
    private readonly FontIcon _statusIcon = new() { Glyph = "", FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _statusRing = new() { Width = 14, Height = 14, IsActive = false };
    private readonly TextBlock _statusText = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Button _breakInOnButton = new() { Content = "Turn On BK-IN", Padding = new Thickness(8, 2, 8, 3) };

    private readonly TextBox _lineBox = new() { PlaceholderText = "Type a line and press Enter to send", FontFamily = new FontFamily("Consolas") };
    private readonly Button _sendButton = new() { Content = "Send" };

    private readonly DispatcherQueueTimer _rigTimer;
    /// The last problem queueing something or filling a macro; cleared when
    /// the line changes.
    private string? _note;
    private bool _updating;

    public CwSendPane(CwSender sender, CwWindowLink link)
    {
        _sender = sender;
        _link = link;

        var root = new Grid();
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
        {
            root.RowDefinitions.Add(new RowDefinition { Height = height });
        }
        Add(root, BuildHeader(), 0, divider: true);
        Add(root, _macroRow, 1, divider: true);
        _logScroller.Content = _log;
        Add(root, _logScroller, 2, divider: true);
        BuildStatus();
        Add(root, _status, 3, divider: false);
        Add(root, BuildInputRow(), 4, divider: false);
        Content = root;

        _sender.Changed += Refresh;
        _rigTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        // Speed, BK-IN and the block reason come from the rig's polled state.
        _rigTimer.Interval = TimeSpan.FromMilliseconds(250);
        _rigTimer.Tick += (_, _) => RefreshRig();
        _rigTimer.Start();
        Unloaded += (_, _) =>
        {
            _rigTimer.Stop();
            _sender.Changed -= Refresh;
        };
        RebuildMacros();
        Refresh();
        RefreshRig();
    }

    /// Theme-dependent brushes, called by the window after a theme change.
    public void ApplyTheme()
    {
        _logScroller.Background = (Brush)Application.Current.Resources["TextControlBackground"];
        _statusText.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        RebuildLog();
    }

    private static void Add(Grid root, FrameworkElement element, int row, bool divider)
    {
        Grid.SetRow(element, row);
        root.Children.Add(element);
        if (divider)
        {
            var line = new Microsoft.UI.Xaml.Shapes.Rectangle
            {
                Height = 1,
                Fill = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
                VerticalAlignment = VerticalAlignment.Bottom,
            };
            Grid.SetRow(line, row);
            root.Children.Add(line);
        }
    }

    private Grid BuildHeader()
    {
        var header = new Grid { Padding = new Thickness(16, 6, 12, 6), ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new TextBlock { Text = "Send", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var speed = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        speed.Children.Add(_speedText);
        speed.Children.Add(_slowerButton);
        speed.Children.Add(_fasterButton);
        ToolTipService.SetToolTip(speed, "The rig's keyer speed (KS), 4–60 WPM");
        AutomationProperties.SetName(_slowerButton, "Slower");
        AutomationProperties.SetName(_fasterButton, "Faster");
        _slowerButton.Click += (_, _) => StepSpeed(-1);
        _fasterButton.Click += (_, _) => StepSpeed(+1);
        left.Children.Add(speed);

        ToolTipService.SetToolTip(_breakInButton, "Break-in. The rig only transmits its keyer memory with BK-IN on.");
        _breakInButton.Click += (_, _) =>
        {
            if (_link.BreakIn() is { } on)
            {
                _link.SetBreakIn(!on);
            }
            RefreshRig();
        };
        left.Children.Add(_breakInButton);

        for (var slot = 1; slot <= 5; slot++)
        {
            _slotBox.Items.Add(new ComboBoxItem { Content = $"Memory {slot}", Tag = slot });
        }
        _slotBox.SelectedIndex = _sender.Slot - 1;
        _slotBox.SelectionChanged += (_, _) =>
        {
            if (!_updating && _slotBox.SelectedItem is ComboBoxItem { Tag: int slot })
            {
                _sender.Slot = slot;
            }
        };
        ToolTipService.SetToolTip(_slotBox, "The rig's CW TEXT keyer memory the send pane writes to. Whatever is stored there gets overwritten.");
        AutomationProperties.SetName(_slotBox, "Keyer memory");
        left.Children.Add(_slotBox);
        header.Children.Add(left);

        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var macrosButton = new Button();
        SetContent(macrosButton, "", "Macros…");
        ToolTipService.SetToolTip(macrosButton, "Edit the macro buttons");
        macrosButton.Click += async (_, _) => await EditMacrosAsync();
        SetContent(_clearButton, "", "Clear");
        ToolTipService.SetToolTip(_clearButton, "Clear what's been sent from the log");
        _clearButton.Click += (_, _) => _sender.ClearLog();
        SetContent(_stopButton, "", "Stop");
        ToolTipService.SetToolTip(_stopButton, "Stop keying now and drop everything queued (Esc)");
        _stopButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.Escape });
        _stopButton.Click += (_, _) => _sender.Stop();
        right.Children.Add(macrosButton);
        right.Children.Add(_clearButton);
        right.Children.Add(_stopButton);
        Grid.SetColumn(right, 2);
        header.Children.Add(right);
        return header;
    }

    private void BuildStatus()
    {
        _statusRing.Visibility = Visibility.Collapsed;
        _breakInOnButton.Click += (_, _) =>
        {
            _link.SetBreakIn(true);
            RefreshRig();
        };
        _status.Children.Add(_statusIcon);
        _status.Children.Add(_statusRing);
        _status.Children.Add(_statusText);
        _status.Children.Add(_breakInOnButton);
    }

    private Grid BuildInputRow()
    {
        var row = new Grid { Padding = new Thickness(16, 0, 16, 10), ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        AutomationProperties.SetName(_lineBox, "Send line");
        _lineBox.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter)
            {
                e.Handled = true;
                Submit();
            }
        };
        _lineBox.TextChanged += (_, _) =>
        {
            if (_lineBox.Text.Length > 0 && _note is not null)
            {
                _note = null;
                RefreshStatus();
            }
            _sendButton.IsEnabled = _lineBox.Text.Trim().Length > 0;
        };
        row.Children.Add(_lineBox);

        _sendButton.IsEnabled = false;
        _sendButton.Click += (_, _) => Submit();
        Grid.SetColumn(_sendButton, 1);
        row.Children.Add(_sendButton);
        return row;
    }

    private static void SetContent(Button button, string glyph, string text)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        panel.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        panel.Children.Add(new TextBlock { Text = text });
        button.Content = panel;
        AutomationProperties.SetName(button, text);
    }

    private void StepSpeed(int delta)
    {
        var wpm = _sender.SpeedWpm ?? 20;
        _link.SetSpeed(Math.Clamp(wpm + delta, 4, 60));
        RefreshRig();
    }

    private void Submit()
    {
        if (_lineBox.Text.Trim().Length == 0)
        {
            return;
        }
        _note = _sender.Enqueue(_lineBox.Text);
        if (_note is null)
        {
            _lineBox.Text = "";
        }
        _lineBox.Focus(FocusState.Programmatic);
        RefreshStatus();
    }

    /// Adds a macro's text to the send line (after a space if there's
    /// already something there) and leaves the cursor at the end.
    private void Insert(CwMacro macro)
    {
        var (text, problem) = _sender.TextFor(macro);
        if (text is null)
        {
            _note = problem;
            RefreshStatus();
            return;
        }
        var current = _lineBox.Text.Trim();
        _lineBox.Text = current.Length == 0 ? text : current + " " + text;
        _note = null;
        _lineBox.Focus(FocusState.Programmatic);
        _lineBox.Select(_lineBox.Text.Length, 0);
        RefreshStatus();
    }

    private void RebuildMacros()
    {
        _macroRow.Children.Clear();
        var macros = _sender.Macros;
        for (var i = 0; i < macros.Count; i++)
        {
            var macro = macros[i];
            var button = new Button { Content = macro.Label.Length > 0 ? macro.Label : "—" };
            button.Click += (_, _) => Insert(macro);
            var tip = $"Put “{macro.Text}” in the send line";
            if (i < 9)
            {
                button.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.Number1 + i, Modifiers = VirtualKeyModifiers.Control });
                tip += $"  (Ctrl+{i + 1})";
            }
            ToolTipService.SetToolTip(button, tip);
            _macroRow.Children.Add(button);
        }
    }

    /// Items, activity or settings changed.
    private void Refresh()
    {
        _updating = true;
        try
        {
            if (_slotBox.SelectedIndex != _sender.Slot - 1)
            {
                _slotBox.SelectedIndex = _sender.Slot - 1;
            }
        }
        finally
        {
            _updating = false;
        }
        _slotBox.IsEnabled = !_sender.IsSending;
        _clearButton.IsEnabled = _sender.HasFinished;
        _stopButton.IsEnabled = _sender.IsSending || _sender.HasWaiting;
        RebuildLog();
        RefreshStatus();
    }

    private void RefreshRig()
    {
        var wpm = _sender.SpeedWpm;
        _speedText.Text = wpm is { } w ? $"{w} WPM" : "– WPM";
        _slowerButton.IsEnabled = _fasterButton.IsEnabled = wpm is not null;
        var breakIn = _link.BreakIn();
        _breakInButton.IsChecked = breakIn == true;
        _breakInButton.IsEnabled = breakIn is not null;
        RefreshStatus();
    }

    /// One line under the log: the last problem queueing something, what
    /// the rig is doing, what's blocking sending, or ready.
    private void RefreshStatus()
    {
        var showRing = false;
        var showIcon = false;
        var showBreakInButton = false;
        string text;
        if (_note is { } note)
        {
            showIcon = true;
            text = note;
        }
        else if (_sender.Activity is { } activity)
        {
            showRing = true;
            text = activity;
        }
        else if (_sender.BlockReason is { } block)
        {
            showIcon = true;
            text = $"Can't send: {block.Message}";
            showBreakInButton = block.Kind == CwSendBlockKind.BreakInOff;
        }
        else
        {
            text = $"Ready — {(_sender.SpeedWpm is { } wpm ? $"{wpm} WPM" : "rig keyer")}, memory {_sender.Slot}";
        }
        _statusText.Text = text;
        ToolTipService.SetToolTip(_statusText, text);
        _statusIcon.Visibility = showIcon ? Visibility.Visible : Visibility.Collapsed;
        _statusRing.IsActive = showRing;
        _statusRing.Visibility = showRing ? Visibility.Visible : Visibility.Collapsed;
        _breakInOnButton.Visibility = showBreakInButton ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Queued, keying and sent lines, newest at the bottom. At most 200, so
    /// a rebuild per change is cheap.
    private void RebuildLog()
    {
        var atBottom = _logScroller.VerticalOffset >= _logScroller.ScrollableHeight - 4;
        _log.Children.Clear();
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        if (_sender.Items.Count == 0)
        {
            _log.Children.Add(new TextBlock { Text = "Lines you send appear here. Type below, or use a macro.", Foreground = secondary });
        }
        foreach (var item in _sender.Items)
        {
            var row = new StackPanel { Spacing = 2 };
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var (glyph, color) = item.State switch
            {
                CwSendState.Queued => ("", secondary),
                CwSendState.Sending => ("", new SolidColorBrush(Microsoft.UI.Colors.Orange)),
                CwSendState.Sent => ("", new SolidColorBrush(Microsoft.UI.Colors.LimeGreen)),
                CwSendState.Stopped => ("", secondary),
                _ => ("", new SolidColorBrush(Microsoft.UI.Colors.Red)),
            };
            line.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Foreground = color, Width = 16, VerticalAlignment = VerticalAlignment.Center });
            var text = new TextBlock
            {
                Text = item.Text,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 16,
                IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap,
            };
            if (item.State is CwSendState.Queued or CwSendState.Stopped)
            {
                text.Foreground = secondary;
            }
            line.Children.Add(text);
            if (item.State == CwSendState.Sending && item.Chunks.Count > 1)
            {
                line.Children.Add(new TextBlock { Text = $"{item.SentChunks + 1}/{item.Chunks.Count}", FontSize = 12, Foreground = secondary, VerticalAlignment = VerticalAlignment.Center });
            }
            row.Children.Add(line);
            if (item.State == CwSendState.Failed && item.FailureReason is { } reason)
            {
                row.Children.Add(new TextBlock { Text = reason, FontSize = 12, Foreground = new SolidColorBrush(Microsoft.UI.Colors.Red), Margin = new Thickness(24, 0, 0, 0), TextWrapping = TextWrapping.Wrap });
            }
            if (item.Dropped.Length > 0)
            {
                row.Children.Add(new TextBlock { Text = $"Left out (the keyer can't send them): {item.Dropped}", FontSize = 12, Foreground = secondary, Margin = new Thickness(24, 0, 0, 0) });
            }
            _log.Children.Add(row);
        }
        if (atBottom)
        {
            _logScroller.UpdateLayout();
            _logScroller.ChangeView(null, _logScroller.ScrollableHeight, null, disableAnimation: true);
        }
    }

    /// The Mac's CWMacroEditor: label and text per macro, reorder, remove,
    /// add, restore defaults. Save applies, Cancel discards.
    private async Task EditMacrosAsync()
    {
        var working = _sender.Macros.Select(m => new CwMacro { Label = m.Label, Text = m.Text }).ToList();
        var rows = new StackPanel { Spacing = 6 };
        void Rebuild()
        {
            rows.Children.Clear();
            for (var i = 0; i < working.Count; i++)
            {
                var index = i;
                var macro = working[i];
                var grid = new Grid { ColumnSpacing = 6 };
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100) });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                for (var c = 0; c < 3; c++)
                {
                    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                }
                var label = new TextBox { Text = macro.Label, PlaceholderText = "Label" };
                label.TextChanged += (_, _) => macro.Label = label.Text;
                AutomationProperties.SetName(label, $"Macro {index + 1} label");
                var text = new TextBox { Text = macro.Text, PlaceholderText = "Text", FontFamily = new FontFamily("Consolas") };
                text.TextChanged += (_, _) => macro.Text = text.Text;
                AutomationProperties.SetName(text, $"Macro {index + 1} text");
                Grid.SetColumn(text, 1);
                grid.Children.Add(label);
                grid.Children.Add(text);
                var buttons = new (string Glyph, string Name, Action Act, bool Enabled)[]
                {
                    ("", "Move up", () => { (working[index - 1], working[index]) = (working[index], working[index - 1]); Rebuild(); }, index > 0),
                    ("", "Move down", () => { (working[index + 1], working[index]) = (working[index], working[index + 1]); Rebuild(); }, index < working.Count - 1),
                    ("", "Remove", () => { working.RemoveAt(index); Rebuild(); }, true),
                };
                for (var b = 0; b < buttons.Length; b++)
                {
                    var (glyph, name, act, enabled) = buttons[b];
                    var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 12 }, IsEnabled = enabled, Padding = new Thickness(8, 6, 8, 6) };
                    AutomationProperties.SetName(button, name);
                    ToolTipService.SetToolTip(button, name);
                    button.Click += (_, _) => act();
                    Grid.SetColumn(button, 2 + b);
                    grid.Children.Add(button);
                }
                rows.Children.Add(grid);
            }
        }
        Rebuild();

        var add = new Button { Content = "Add" };
        add.Click += (_, _) =>
        {
            working.Add(new CwMacro { Label = "New", Text = "" });
            Rebuild();
        };
        var restore = new Button { Content = "Restore Defaults" };
        restore.Click += (_, _) =>
        {
            working = CwMacro.Defaults();
            Rebuild();
        };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(add);
        actions.Children.Add(restore);

        var body = new StackPanel { Spacing = 12, Width = 620 };
        body.Children.Add(new TextBlock
        {
            Text = "Placeholders: {MYCALL} and {MYGRID} (Settings → Station), {CALL} (Their call — click a callsign in the decoded text to fill it in). Prosigns: <BT>, <AR>, <KN>.",
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        body.Children.Add(new ScrollViewer { Content = rows, MaxHeight = 360 });
        body.Children.Add(actions);

        var dialog = new ContentDialog
        {
            Title = "CW Macros",
            Content = body,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
            RequestedTheme = AppSettings.Theme.ElementTheme(),
        };
        // ContentDialog caps its width well below 620 by default.
        dialog.Resources["ContentDialogMaxWidth"] = 720.0;
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                _sender.SetMacros(working);
                RebuildMacros();
            }
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Another dialog is already open in this window.
        }
    }
}

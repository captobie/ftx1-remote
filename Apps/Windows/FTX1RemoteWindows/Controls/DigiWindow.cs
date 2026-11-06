using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Digi;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.ApplicationModel.DataTransfer;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace FTX1RemoteWindows.Controls;

/// What the RTTY/PSK window needs from MainWindow beyond the receiver and
/// sender.
public sealed class DigiWindowLink
{
    /// Single-receive display ("FR"); null if not read or disconnected.
    public required Func<bool?> SingleReceive { get; init; }
    public required Func<bool> IsConnected { get; init; }
    /// A menu item's value ("EX" P1 P2 P3), null if unreadable.
    public required Func<int, int, int, Task<string?>> ReadMenuItemAsync { get; init; }
    /// The transmitting mode's MOD SOURCE warning, null when fine or unknown.
    public required Func<Task<string?>> ModSourceWarningAsync { get; init; }
}

/// Tools → RTTY/PSK — the Mac's DigiWindowView (+ DigiTuningStrip,
/// DigiSendPane): decodes one RTTY, BPSK31 or BPSK63 signal at a time from
/// MAIN, SUB or the WebSDR window's audio, or from a file. A click on the
/// tuning strip picks the signal; AFC follows it from there. Below it the
/// send pane: live typeahead, TX/RX/Stop, macros (<see cref="DigiSender"/>).
///
/// Decodes only while open; the text lives in <see cref="DigiReceiver"/> and
/// the transmission in <see cref="DigiSender"/> (both owned by MainWindow).
/// Closing the window acts as RX: what's typed goes out, then the tail and
/// unkey. Built in code, like the CW window.
public sealed class DigiWindow : Window
{
    private readonly DigiReceiver _receiver;
    private readonly DigiSender _sender;
    private readonly DigiWindowLink _link;

    private readonly Grid _root = new();

    // Header
    private readonly SelectorBar _modeBar = new();
    private readonly SelectorBar _channelBar = new();
    private readonly SelectorBarItem _mainItem = new() { Text = "MAIN", Tag = CwAudioChannel.Main };
    private readonly SelectorBarItem _subItem = new() { Text = "SUB", Tag = CwAudioChannel.Sub };
    private readonly SelectorBarItem _webSdrItem = new() { Text = "WebSDR", Tag = CwAudioChannel.WebSdr };
    private readonly Button _openButton = new();
    private readonly Button _copyButton = new();
    private readonly Button _clearButton = new();

    // Settings row
    private readonly StackPanel _rttyPanel = new() { Orientation = Orientation.Horizontal, Spacing = 14 };
    private readonly ComboBox _shiftBox = new();
    private readonly ComboBox _baudBox = new();
    private readonly CheckBox _reverseBox = new() { Content = Loc.S("digiWindow.reverse"), MinWidth = 0 };
    private readonly CheckBox _usosBox = new() { Content = "USOS", MinWidth = 0 };
    private readonly CheckBox _afcBox = new() { Content = "AFC", MinWidth = 0 };
    private readonly Slider _squelchSlider = new() { Minimum = 0, Maximum = 0.9, StepFrequency = 0.01, Width = 110, VerticalAlignment = VerticalAlignment.Center, IsThumbToolTipEnabled = false };
    private readonly Button _rigTonesButton = new();

    // Tuning strip
    private const int StripRows = 64;
    private readonly WriteableBitmap _stripBitmap;
    private readonly byte[] _stripPixels;
    private readonly int _stripColumns;
    private readonly Image _stripImage = new() { Stretch = Stretch.Fill };
    private readonly Canvas _markers = new();
    private readonly Canvas _scale = new() { Height = 16 };
    private readonly Grid _stripHost = new();
    private float[] _lastRow = [];
    private int _shownRowSerial;

    // Status
    private readonly TextBlock _trackedText = new() { FontFamily = new FontFamily("Consolas"), MinWidth = 70, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressBar _qualityBar = new() { Width = 90, Minimum = 0, Maximum = 1, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _fileRing = new() { Width = 16, Height = 16, IsActive = false };
    private readonly TextBlock _noteText = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };

    // Decoded text
    private readonly ScrollViewer _textScroller = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(16, 12, 16, 12) };
    private readonly TextBlock _decodedText = new() { FontFamily = new FontFamily("Consolas"), FontSize = 17, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private readonly TextBlock _placeholder = new() { Text = Loc.S("digiWindow.placeholder"), FontSize = 17, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(16, 12, 16, 12) };
    private List<DigiTextRun> _shownRuns = [];
    private int _stableInLast;
    private int _tailInlineCount;
    private bool _textDirty;

    // Send pane
    private readonly TextBlock _stateLabel = new() { FontFamily = new FontFamily("Consolas"), FontWeight = Microsoft.UI.Text.FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(6, 2, 6, 2) };
    private readonly Border _stateBadge = new() { CornerRadius = new CornerRadius(4), VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _txButton = new() { Content = "TX", MinWidth = 52 };
    private readonly Button _rxButton = new() { Content = "RX", MinWidth = 52 };
    private readonly Button _stopButton = new();
    private readonly Slider _levelSlider = new() { Minimum = DigiSender.MinLevelDb, Maximum = DigiSender.MaxLevelDb, StepFrequency = 1, Width = 110, VerticalAlignment = VerticalAlignment.Center, IsThumbToolTipEnabled = false };
    private readonly TextBlock _levelValue = new() { FontFamily = new FontFamily("Consolas"), Width = 52, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _macrosButton = new();
    private readonly StackPanel _macroRow = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly Button _lookupButton = new();
    private readonly TextBox _theirCallBox = new() { Width = 120, PlaceholderText = Loc.S("common.theirCall"), CharacterCasing = CharacterCasing.Upper, FontFamily = new FontFamily("Consolas") };
    private readonly TextBlock _sentText = new() { FontFamily = new FontFamily("Consolas"), FontSize = 15, TextWrapping = TextWrapping.Wrap };
    private readonly TextBox _typeBox = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        FontFamily = new FontFamily("Consolas"),
        FontSize = 15,
        BorderThickness = new Thickness(0),
        PlaceholderText = Loc.S("digiSendPane.typeHere"),
        MinHeight = 60,
    };
    private readonly StackPanel _statusPanel = new() { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(16, 6, 16, 6) };
    private readonly FontIcon _statusIcon = new() { Glyph = "", FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _statusText = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private string? _lookupNote;
    private bool _lookupNoteIsProblem;
    private string? _modSourceWarning;
    private string _modSourceKey = "";
    private List<DigiMacro> _macros;

    private readonly DispatcherQueueTimer _timer;
    private bool _updating;

    public DigiWindow(DigiReceiver receiver, DigiSender sender, DigiWindowLink link)
    {
        _receiver = receiver;
        _sender = sender;
        _link = link;
        _macros = AppSettings.Digi.Macros ?? DigiMacro.Defaults();
        Title = "RTTY/PSK";
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(900 * scale), (int)(980 * scale)));

        _stripColumns = (int)(DigiDecoder.StripSpanHz / (DigiDecoder.SampleRate / 2048));
        _stripPixels = new byte[_stripColumns * StripRows * 4];
        _stripBitmap = new WriteableBitmap(_stripColumns, StripRows);
        _stripImage.Source = _stripBitmap;
        ClearStrip();

        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1.3, GridUnitType.Star), MinHeight = 380 });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 240 });
        var top = BuildTop();
        _root.Children.Add(top);
        var send = BuildSendPane();
        Grid.SetRow(send, 1);
        _root.Children.Add(send);
        var divider = new Rectangle
        {
            Height = 2,
            Fill = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        _root.Children.Add(divider);

        Content = _root;
        ApplyTheme();

        _receiver.Changed += OnReceiverChanged;
        _receiver.Error += ShowError;
        _sender.Changed += RefreshSend;
        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(100);
        _timer.Tick += (_, _) => OnTick();
        _timer.Start();
        _receiver.Start();
        Closed += (_, _) =>
        {
            _timer.Stop();
            _receiver.Changed -= OnReceiverChanged;
            _receiver.Error -= ShowError;
            _sender.Changed -= RefreshSend;
            // Not left keyed with nobody watching: closing acts as RX
            // (what's typed goes out, then the tail and unkey).
            _sender.Finish();
            _receiver.Stop();
        };
        Refresh();
        RefreshSend();
        UpdateStrip();
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        ThemeEngine.ApplyTo(_root);
        _root.Background = ThemeEngine.WindowBackground;
        _textScroller.Background = (Brush)Application.Current.Resources["TextControlBackground"];
        _placeholder.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        _noteText.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        _sentText.Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"];
        _statusText.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        _shownRuns = [];
        RenderText();
        RefreshSend();
    }

    // Layout

    private Grid BuildTop()
    {
        var top = new Grid();
        for (var i = 0; i < 5; i++)
        {
            top.RowDefinitions.Add(new RowDefinition { Height = i == 4 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        }
        AddRow(top, BuildHeader(), 0);
        AddRow(top, BuildSettingsRow(), 1);
        AddRow(top, BuildStrip(), 2);
        AddRow(top, BuildStatusLine(), 3);
        var textHost = new Grid();
        _textScroller.Content = _decodedText;
        textHost.Children.Add(_textScroller);
        textHost.Children.Add(_placeholder);
        Grid.SetRow(textHost, 4);
        top.Children.Add(textHost);
        return top;
    }

    private static void AddRow(Grid grid, FrameworkElement element, int row)
    {
        Grid.SetRow(element, row);
        grid.Children.Add(element);
        var line = new Rectangle
        {
            Height = 1,
            Fill = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        Grid.SetRow(line, row);
        grid.Children.Add(line);
    }

    private Grid BuildHeader()
    {
        var header = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        foreach (var mode in Enum.GetValues<DigiMode>())
        {
            _modeBar.Items.Add(new SelectorBarItem { Text = mode.Title(), Tag = mode });
        }
        _modeBar.SelectionChanged += (bar, _) =>
        {
            if (!_updating && bar.SelectedItem?.Tag is DigiMode mode)
            {
                _receiver.Mode = mode;
            }
        };
        _channelBar.Items.Add(_mainItem);
        _channelBar.Items.Add(_subItem);
        _channelBar.Items.Add(_webSdrItem);
        ToolTipService.SetToolTip(_channelBar, Loc.S("digiWindow.whichAudio"));
        ToolTipService.SetToolTip(_webSdrItem, Loc.S("cwWindow.decodeWhatTheWebSDR"));
        ToolTipService.SetToolTip(_mainItem, Loc.S("cwWindow.decodeTheRigsMAIN"));
        _channelBar.SelectionChanged += (bar, _) =>
        {
            if (!_updating && bar.SelectedItem?.Tag is CwAudioChannel channel)
            {
                _receiver.Channel = channel;
            }
        };
        var pickers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        pickers.Children.Add(_modeBar);
        pickers.Children.Add(_channelBar);
        header.Children.Add(pickers);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        SetContent(_openButton, "", Loc.S("cwWindow.openAudioFile"));
        ToolTipService.SetToolTip(_openButton, Loc.S("digiWindow.decodeARecording"));
        _openButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.O, Modifiers = VirtualKeyModifiers.Control });
        _openButton.Click += async (_, _) => await OpenFileAsync();
        SetContent(_copyButton, "", Loc.S("cwWindow.copy"));
        ToolTipService.SetToolTip(_copyButton, Loc.S("digiWindow.copyTheText"));
        _copyButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.C, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift });
        _copyButton.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(_receiver.DecodedText);
            Clipboard.SetContent(package);
        };
        SetContent(_clearButton, "", Loc.S("common.clear"));
        ToolTipService.SetToolTip(_clearButton, Loc.S("digiWindow.clearTheText"));
        _clearButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.K, Modifiers = VirtualKeyModifiers.Control });
        _clearButton.Click += (_, _) => _receiver.ClearText();
        buttons.Children.Add(_openButton);
        buttons.Children.Add(_copyButton);
        buttons.Children.Add(_clearButton);
        Grid.SetColumn(buttons, 2);
        header.Children.Add(buttons);
        return header;
    }

    private StackPanel BuildSettingsRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, Padding = new Thickness(16, 6, 16, 6) };

        foreach (var shift in RttySettings.Shifts)
        {
            _shiftBox.Items.Add(new ComboBoxItem { Content = $"{shift:0} Hz", Tag = shift });
        }
        _shiftBox.SelectionChanged += (_, _) =>
        {
            if (!_updating && _shiftBox.SelectedItem is ComboBoxItem { Tag: double shift })
            {
                _receiver.RttyShiftHz = shift;
            }
        };
        foreach (var baud in RttySettings.Bauds)
        {
            _baudBox.Items.Add(new ComboBoxItem { Content = baud == 45.45 ? "45.45" : $"{baud:0}", Tag = baud });
        }
        _baudBox.SelectionChanged += (_, _) =>
        {
            if (!_updating && _baudBox.SelectedItem is ComboBoxItem { Tag: double baud })
            {
                _receiver.RttyBaud = baud;
            }
        };
        _rttyPanel.Children.Add(Labeled(Loc.S("digiWindow.shift"), _shiftBox));
        _rttyPanel.Children.Add(Labeled(Loc.S("digiWindow.baud"), _baudBox));
        ToolTipService.SetToolTip(_reverseBox, Loc.S("digiWindow.reverseHelp"));
        _reverseBox.Click += (_, _) => { if (!_updating) _receiver.RttyReverse = _reverseBox.IsChecked == true; };
        ToolTipService.SetToolTip(_usosBox, Loc.S("digiWindow.unshiftOnSpaceHelp"));
        _usosBox.Click += (_, _) => { if (!_updating) _receiver.RttyUnshiftOnSpace = _usosBox.IsChecked == true; };
        _rttyPanel.Children.Add(_reverseBox);
        _rttyPanel.Children.Add(_usosBox);
        row.Children.Add(_rttyPanel);

        ToolTipService.SetToolTip(_afcBox, Loc.S("digiWindow.afcHelp"));
        _afcBox.Click += (_, _) => { if (!_updating) _receiver.AfcEnabled = _afcBox.IsChecked == true; };
        row.Children.Add(_afcBox);

        var squelch = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        squelch.Children.Add(Label(Loc.S("digiWindow.squelch")));
        _squelchSlider.ValueChanged += (_, e) => { if (!_updating) _receiver.Squelch = e.NewValue; };
        squelch.Children.Add(_squelchSlider);
        ToolTipService.SetToolTip(squelch, Loc.S("digiWindow.squelchHelp"));
        row.Children.Add(squelch);

        SetContent(_rigTonesButton, "", Loc.S("digiWindow.rigTones"));
        ToolTipService.SetToolTip(_rigTonesButton, Loc.S("digiWindow.rigTonesHelp"));
        _rigTonesButton.Click += async (_, _) => await UseRigTonesAsync();
        row.Children.Add(_rigTonesButton);
        return row;
    }

    private Grid BuildStrip()
    {
        _stripHost.Height = 84;
        _stripHost.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _stripHost.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var area = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Black) };
        area.Children.Add(_stripImage);
        area.Children.Add(_markers);
        area.PointerPressed += (_, e) =>
        {
            var x = e.GetCurrentPoint(area).Position.X;
            if (area.ActualWidth <= 0)
            {
                return;
            }
            var hz = x / area.ActualWidth * DigiDecoder.StripSpanHz;
            _receiver.SetCenter(Snap(hz));
        };
        area.SizeChanged += (_, _) => { UpdateMarkers(); BuildScale(); };
        ToolTipService.SetToolTip(area, Loc.S("digiWindow.clickToTune"));
        var clip = new Grid();
        clip.Children.Add(area);
        _stripHost.Children.Add(clip);
        Grid.SetRow(_scale, 1);
        _stripHost.Children.Add(_scale);
        return _stripHost;
    }

    private StackPanel BuildStatusLine()
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(16, 4, 16, 4) };
        bar.Children.Add(_trackedText);
        var quality = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        quality.Children.Add(Label(Loc.S("digiWindow.quality")));
        quality.Children.Add(_qualityBar);
        bar.Children.Add(quality);
        bar.Children.Add(_fileRing);
        bar.Children.Add(_noteText);
        return bar;
    }

    private Grid BuildSendPane()
    {
        var pane = new Grid();
        pane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        pane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        pane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        pane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // Header: state, TX / RX / Stop, level, macros.
        var header = new Grid { Padding = new Thickness(16, 6, 12, 6), ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        _stateBadge.Child = _stateLabel;
        left.Children.Add(_stateBadge);
        _txButton.Click += (_, _) => _sender.Transmit();
        _txButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.T, Modifiers = VirtualKeyModifiers.Control });
        ToolTipService.SetToolTip(_txButton, Loc.S("digiSendPane.txHelp"));
        _rxButton.Click += (_, _) => _sender.Finish();
        _rxButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.R, Modifiers = VirtualKeyModifiers.Control });
        ToolTipService.SetToolTip(_rxButton, Loc.S("digiSendPane.rxHelp"));
        SetContent(_stopButton, "", Loc.S("common.stop"));
        _stopButton.Click += (_, _) => _sender.Stop();
        _stopButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.Escape });
        ToolTipService.SetToolTip(_stopButton, Loc.S("digiSendPane.stopHelp"));
        left.Children.Add(_txButton);
        left.Children.Add(_rxButton);
        left.Children.Add(_stopButton);
        header.Children.Add(left);

        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        var level = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        level.Children.Add(Label(Loc.S("digiSendPane.level")));
        _levelSlider.ValueChanged += (_, e) =>
        {
            if (_updating)
            {
                return;
            }
            _sender.LevelDb = e.NewValue;
            AppSettings.Digi.TxLevelDb = _sender.LevelDb;
            AppSettings.SaveDigi();
        };
        level.Children.Add(_levelSlider);
        level.Children.Add(_levelValue);
        ToolTipService.SetToolTip(level, Loc.S("digiSendPane.levelHelp"));
        right.Children.Add(level);
        SetContent(_macrosButton, "", Loc.S("cwSendPane.macros"));
        ToolTipService.SetToolTip(_macrosButton, Loc.S("cwSendPane.editTheMacroButtons"));
        _macrosButton.Click += async (_, _) => await EditMacrosAsync();
        right.Children.Add(_macrosButton);
        Grid.SetColumn(right, 2);
        header.Children.Add(right);
        AddRow(pane, header, 0);

        // Their call + macros.
        var macroScroller = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Enabled,
        };
        var macroHost = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(16, 8, 16, 8) };
        SetContent(_lookupButton, "", Loc.S("cwLogPane.lookup"));
        _lookupButton.Click += async (_, _) => await LookUpAsync();
        macroHost.Children.Add(_lookupButton);
        _theirCallBox.TextChanged += (_, _) =>
        {
            if (_updating)
            {
                return;
            }
            _sender.TheirCall = _theirCallBox.Text.Trim();
            _lookupNote = null;
            RefreshSend();
        };
        macroHost.Children.Add(_theirCallBox);
        macroHost.Children.Add(_macroRow);
        macroScroller.Content = macroHost;
        AddRow(pane, macroScroller, 1);
        RebuildMacros();

        // The typeahead: sent text greyed above, the unsent part editable.
        var typeahead = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var typeStack = new StackPanel { Padding = new Thickness(16, 8, 16, 8) };
        typeStack.Children.Add(_sentText);
        typeStack.Children.Add(_typeBox);
        typeahead.Content = typeStack;
        AutomationProperties.SetName(_typeBox, Loc.S("digiSendPane.typeHere"));
        _typeBox.TextChanged += (_, _) => OnTypeChanged();
        var typeHost = new Grid();
        typeHost.Children.Add(typeahead);
        AddRow(pane, typeHost, 2);

        // Status line.
        _statusPanel.Children.Add(_statusIcon);
        _statusPanel.Children.Add(_statusText);
        Grid.SetRow(_statusPanel, 3);
        pane.Children.Add(_statusPanel);
        return pane;
    }

    private static TextBlock Label(string text) => new() { Text = text, VerticalAlignment = VerticalAlignment.Center };

    private static StackPanel Labeled(string label, FrameworkElement control)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        panel.Children.Add(Label(label));
        panel.Children.Add(control);
        return panel;
    }

    private static void SetContent(Button button, string glyph, string text)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        panel.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        panel.Children.Add(new TextBlock { Text = text });
        button.Content = panel;
        AutomationProperties.SetName(button, text);
    }

    // Receive side

    private void OnReceiverChanged()
    {
        _textDirty = true;
        Refresh();
    }

    /// Settings, notes and button states — on every receiver change.
    private void Refresh()
    {
        _updating = true;
        try
        {
            foreach (SelectorBarItem item in _modeBar.Items)
            {
                if (item.Tag is DigiMode m && m == _receiver.Mode && !item.IsSelected)
                {
                    item.IsSelected = true;
                }
            }
            var selected = _receiver.Channel switch
            {
                CwAudioChannel.Main => _mainItem,
                CwAudioChannel.Sub => _subItem,
                _ => _webSdrItem,
            };
            if (!selected.IsSelected)
            {
                selected.IsSelected = true;
            }
            var isRtty = _receiver.Mode == DigiMode.Rtty;
            _rttyPanel.Visibility = isRtty ? Visibility.Visible : Visibility.Collapsed;
            SelectCombo(_shiftBox, _receiver.RttyShiftHz);
            SelectCombo(_baudBox, _receiver.RttyBaud);
            _reverseBox.IsChecked = _receiver.RttyReverse;
            _usosBox.IsChecked = _receiver.RttyUnshiftOnSpace;
            _afcBox.IsChecked = _receiver.AfcEnabled;
            _squelchSlider.Value = _receiver.Squelch;
            _copyButton.IsEnabled = _clearButton.IsEnabled = _receiver.HasText;
            _openButton.IsEnabled = !_receiver.IsDecodingFile;
            _rigTonesButton.IsEnabled = _link.IsConnected();
        }
        finally
        {
            _updating = false;
        }
        UpdateNote();
        UpdateSubAvailability();
        UpdateMarkers();
    }

    private static void SelectCombo(ComboBox box, double value)
    {
        foreach (ComboBoxItem item in box.Items)
        {
            if (item.Tag is double tag && Math.Abs(tag - value) < 0.001)
            {
                if (!ReferenceEquals(box.SelectedItem, item))
                {
                    box.SelectedItem = item;
                }
                return;
            }
        }
    }

    /// Why the decoder isn't decoding normally, or the file indicator.
    private void UpdateNote()
    {
        _fileRing.IsActive = _receiver.IsDecodingFile;
        _fileRing.Visibility = _receiver.IsDecodingFile ? Visibility.Visible : Visibility.Collapsed;
        string? note;
        if (_receiver.IsDecodingFile)
        {
            note = Loc.S("cwWindow.decodingFile");
        }
        else if (_receiver.IsPausedForTransmit)
        {
            note = Loc.S("cwWindow.pausedWhileTransmitting");
        }
        else if (_receiver.UnsuitableSourceMode is { } mode)
        {
            note = Loc.F("digiWindow.sourceIsIn", _receiver.Channel == CwAudioChannel.Main ? "MAIN" : _receiver.Channel == CwAudioChannel.Sub ? "SUB" : "WebSDR", mode.DisplayName());
        }
        else if (_receiver.Channel == CwAudioChannel.WebSdr)
        {
            note = WebSdrNote();
        }
        else
        {
            note = null;
        }
        _noteText.Text = note ?? "";
        ToolTipService.SetToolTip(_noteText, note);
    }

    private string? WebSdrNote()
    {
        if (_receiver.WebSdr is not { } webSdr)
        {
            return Loc.S("cwWindow.openTheWebSDRWindow");
        }
        if (!webSdr.Connected)
        {
            return Loc.S("cwWindow.connectTheWebSDRWindow");
        }
        return _receiver.WebSdrPhase switch
        {
            WebSdrTapPhase.Failed => Loc.F("cwWindow.cantCaptureTheWebSDRs", _receiver.WebSdrFailure),
            WebSdrTapPhase.Silent when webSdr.Muted => Loc.S("cwWindow.theWebSDRIsMuted"),
            WebSdrTapPhase.Silent => Loc.S("cwWindow.theWebSDRIsSilent"),
            WebSdrTapPhase.WaitingForWebSdr => Loc.S("cwWindow.waitingForTheWebSDR"),
            _ => null,
        };
    }

    /// SUB is unselectable with no Sub audio (mono input) or in
    /// single-receive display, as on the Mac.
    private void UpdateSubAvailability()
    {
        string? reason = !_receiver.IsSubAudioAvailable
            ? Loc.S("cwWindow.noSUBAudioThe")
            : _link.SingleReceive() == true
                ? Loc.S("cwWindow.sUBIsOffThe")
                : null;
        var enabled = reason is null || _receiver.Channel == CwAudioChannel.Sub;
        if (_subItem.IsEnabled != enabled)
        {
            _subItem.IsEnabled = enabled;
        }
        ToolTipService.SetToolTip(_subItem, reason ?? Loc.S("cwWindow.decodeTheRigsSUB"));
    }

    // Decoded text

    /// Renders the runs: received text with its callsigns as links, this
    /// station's own transmissions in red. Appended text (the usual case)
    /// only re-renders from the last word break on; anything else renders
    /// from scratch.
    private void RenderText()
    {
        var runs = _receiver.Runs;
        var inlines = _decodedText.Inlines;
        var incremental = _shownRuns.Count > 0 && runs.Count >= _shownRuns.Count;
        if (incremental)
        {
            for (var i = 0; i < _shownRuns.Count - 1; i++)
            {
                if (runs[i] != _shownRuns[i])
                {
                    incremental = false;
                    break;
                }
            }
            var last = _shownRuns[^1];
            if (incremental && (runs[_shownRuns.Count - 1].IsTransmit != last.IsTransmit
                    || !runs[_shownRuns.Count - 1].Text.StartsWith(last.Text, StringComparison.Ordinal)))
            {
                incremental = false;
            }
        }
        var firstRun = 0;
        var stable = 0;
        if (incremental)
        {
            for (var i = 0; i < _tailInlineCount; i++)
            {
                inlines.RemoveAt(inlines.Count - 1);
            }
            firstRun = _shownRuns.Count - 1;
            stable = _stableInLast;
        }
        else
        {
            inlines.Clear();
        }
        _tailInlineCount = 0;
        for (var r = firstRun; r < runs.Count; r++)
        {
            var run = runs[r];
            var start = r == firstRun ? stable : 0;
            var isLast = r == runs.Count - 1;
            var breakAt = isLast ? Math.Max(start, run.Text.LastIndexOfAny([' ', '\n']) + 1) : run.Text.Length;
            AppendInlines(run, start, breakAt);
            if (isLast)
            {
                var before = inlines.Count;
                AppendInlines(run, breakAt, run.Text.Length);
                _tailInlineCount = inlines.Count - before;
                _stableInLast = breakAt;
            }
        }
        _shownRuns = [.. runs];
        _placeholder.Visibility = runs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AppendInlines(DigiTextRun run, int from, int to)
    {
        if (to <= from)
        {
            return;
        }
        var segment = run.Text[from..to];
        var inlines = _decodedText.Inlines;
        if (run.IsTransmit)
        {
            inlines.Add(new Run { Text = segment, Foreground = new SolidColorBrush(Microsoft.UI.Colors.Red) });
            return;
        }
        // PSK is often typed in lowercase, so calls are found in the
        // uppercased text (same offsets).
        var position = 0;
        foreach (var (start, length) in CwCallsigns.Find(segment.ToUpperInvariant(), AppSettings.Callsign))
        {
            if (start > position)
            {
                inlines.Add(new Run { Text = segment[position..start] });
            }
            var call = segment.Substring(start, length).ToUpperInvariant();
            var link = new Hyperlink { UnderlineStyle = UnderlineStyle.Single };
            link.Inlines.Add(new Run { Text = segment.Substring(start, length) });
            ToolTipService.SetToolTip(link, Loc.F("cwWindow.useXAsTheir", call));
            link.Click += (_, _) => FillTheirCall(call);
            inlines.Add(link);
            position = start + length;
        }
        if (position < segment.Length)
        {
            inlines.Add(new Run { Text = segment[position..] });
        }
    }

    private void FillTheirCall(string call)
    {
        _updating = true;
        _theirCallBox.Text = call;
        _updating = false;
        _sender.TheirCall = call;
        _lookupNote = null;
        RefreshSend();
    }

    // Tuning strip

    private void OnTick()
    {
        if (_textDirty)
        {
            _textDirty = false;
            // Keep following the newest text only if the reader is already
            // at the bottom.
            var atBottom = _textScroller.VerticalOffset >= _textScroller.ScrollableHeight - 4;
            RenderText();
            if (atBottom)
            {
                _textScroller.UpdateLayout();
                _textScroller.ChangeView(null, _textScroller.ScrollableHeight, null, disableAnimation: true);
            }
        }
        UpdateStrip();
        UpdateSubAvailability();
        RefreshSendLive();
    }

    private void UpdateStrip()
    {
        var meters = _receiver.Meters;
        if (meters.RowSerial != _shownRowSerial && meters.Row.Length > 0)
        {
            _shownRowSerial = meters.RowSerial;
            AppendRow(meters.Row);
        }
        _trackedText.Text = $"{Math.Round(meters.TrackedHz):0} Hz";
        _qualityBar.Value = Math.Clamp(meters.Quality, 0, 1);
        _qualityBar.Foreground = meters.Quality >= _receiver.Squelch
            ? new SolidColorBrush(Microsoft.UI.Colors.LimeGreen)
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        UpdateMarkers();
    }

    private void AppendRow(float[] row)
    {
        _lastRow = row;
        var rowBytes = _stripColumns * 4;
        Buffer.BlockCopy(_stripPixels, 0, _stripPixels, rowBytes, _stripPixels.Length - rowBytes);
        for (var x = 0; x < _stripColumns; x++)
        {
            var value = x < row.Length ? row[x] : 0;
            var color = WaterfallPalette.Lut[WaterfallPalette.Index(value)];
            var o = x * 4;
            _stripPixels[o] = color.B;
            _stripPixels[o + 1] = color.G;
            _stripPixels[o + 2] = color.R;
            _stripPixels[o + 3] = 255;
        }
        FlushStrip();
    }

    private void ClearStrip()
    {
        var black = WaterfallPalette.Lut[0];
        for (var o = 0; o < _stripPixels.Length; o += 4)
        {
            _stripPixels[o] = black.B;
            _stripPixels[o + 1] = black.G;
            _stripPixels[o + 2] = black.R;
            _stripPixels[o + 3] = 255;
        }
        FlushStrip();
    }

    private void FlushStrip()
    {
        using (var stream = _stripBitmap.PixelBuffer.AsStream())
        {
            stream.Write(_stripPixels, 0, _stripPixels.Length);
        }
        _stripBitmap.Invalidate();
    }

    private double XFor(double hz) => hz / DigiDecoder.StripSpanHz * Math.Max(_stripImage.ActualWidth, 1);

    /// Yellow markers at the tones (RTTY) or around the carrier (PSK).
    private void UpdateMarkers()
    {
        _markers.Children.Clear();
        var height = _stripImage.ActualHeight;
        if (height <= 0 || _stripImage.ActualWidth <= 0)
        {
            return;
        }
        var center = _receiver.Meters.TrackedHz;
        var yellow = new SolidColorBrush(Windows.UI.Color.FromArgb(217, 255, 235, 0));
        if (_receiver.Mode == DigiMode.Rtty)
        {
            var half = _receiver.RttyShiftHz / 2;
            foreach (var hz in new[] { center - half, center + half })
            {
                var line = new Rectangle { Width = 1.5, Height = height, Fill = yellow };
                Canvas.SetLeft(line, XFor(hz) - 0.75);
                _markers.Children.Add(line);
            }
        }
        else
        {
            var bandwidth = _receiver.Mode.BandwidthHz(_receiver.Rtty);
            var left = XFor(center - bandwidth / 2);
            var right = XFor(center + bandwidth / 2);
            var box = new Rectangle { Width = Math.Max(right - left, 3), Height = height, Stroke = yellow, StrokeThickness = 1.5 };
            Canvas.SetLeft(box, left);
            _markers.Children.Add(box);
        }
    }

    private void BuildScale()
    {
        _scale.Children.Clear();
        for (var hz = 500; hz < (int)DigiDecoder.StripSpanHz; hz += 500)
        {
            var label = new TextBlock
            {
                Text = hz.ToString(),
                FontFamily = new FontFamily("Consolas"),
                FontSize = 9,
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            };
            Canvas.SetLeft(label, XFor(hz) - 10);
            Canvas.SetTop(label, 2);
            _scale.Children.Add(label);
        }
    }

    /// Moves a click onto the signal near it. RTTY: the centre that puts the
    /// most energy on both tones, within half a shift of the click. PSK: the
    /// strongest bin within 15 Hz. Unchanged before any row.
    private double Snap(double hz)
    {
        if (_lastRow.Length == 0)
        {
            return hz;
        }
        var binHz = DigiDecoder.StripSpanHz / _lastRow.Length;
        float Level(double frequency)
        {
            var bin = (int)Math.Round(frequency / binHz);
            if (bin < 1 || bin >= _lastRow.Length - 1)
            {
                return 0;
            }
            return Math.Max(_lastRow[bin - 1], Math.Max(_lastRow[bin], _lastRow[bin + 1]));
        }
        var isRtty = _receiver.Mode == DigiMode.Rtty;
        var shift = _receiver.RttyShiftHz;
        var reach = isRtty ? shift / 2 : 15;
        var best = hz;
        var bestScore = -1f;
        for (var candidate = hz - reach; candidate <= hz + reach; candidate += binHz)
        {
            var score = isRtty
                ? Math.Min(Level(candidate - shift / 2), Level(candidate + shift / 2))
                : Level(candidate);
            if (score > bestScore)
            {
                bestScore = score;
                best = candidate;
            }
        }
        return best;
    }

    /// RTTY: the rig's MARK FREQUENCY and SHIFT (MODE RTTY, EX010514/15); in
    /// the rig's RTTY mode the space tone is assumed to sit above the mark,
    /// as on the classic 2125/2295 Hz pair. PSK: its PSK TONE (MODE DATA,
    /// EX010417).
    private async Task UseRigTonesAsync()
    {
        _rigTonesButton.IsEnabled = false;
        try
        {
            if (_receiver.Mode == DigiMode.Rtty)
            {
                var mark = await _link.ReadMenuItemAsync(1, 5, 14);
                var shiftText = await _link.ReadMenuItemAsync(1, 5, 15);
                if (!int.TryParse(mark, out var markCode) || !int.TryParse(shiftText, out var shiftCode)
                    || shiftCode < 0 || shiftCode >= RttySettings.Shifts.Length)
                {
                    ShowError(Loc.S("digiWindow.rigTonesFailed"));
                    return;
                }
                var markHz = markCode == 0 ? 1275.0 : 2125.0;
                var shift = RttySettings.Shifts[shiftCode];
                _receiver.RttyShiftHz = shift;
                _receiver.SetCenter(markHz + shift / 2);
            }
            else
            {
                if (!int.TryParse(await _link.ReadMenuItemAsync(1, 4, 17), out var toneCode))
                {
                    ShowError(Loc.S("digiWindow.rigTonesFailed"));
                    return;
                }
                _receiver.SetCenter(toneCode == 0 ? 1000 : 1500);
            }
        }
        finally
        {
            _rigTonesButton.IsEnabled = _link.IsConnected();
        }
    }

    // Send pane

    private void OnTypeChanged()
    {
        if (_updating)
        {
            return;
        }
        var sent = _sender.Text[.._sender.SentCount];
        var typed = _typeBox.Text.Replace("\r\n", "\n").Replace('\r', '\n');
        _sender.Edit(sent + typed);
    }

    private void RefreshSend()
    {
        _updating = true;
        try
        {
            var text = _sender.Text;
            var sentCount = Math.Min(_sender.SentCount, text.Length);
            _sentText.Text = text[..sentCount];
            _sentText.Visibility = sentCount > 0 ? Visibility.Visible : Visibility.Collapsed;
            var unsent = text[sentCount..].Replace("\n", "\r");
            if (_typeBox.Text != unsent)
            {
                var caret = _typeBox.SelectionStart;
                var consumed = _typeBox.Text.Length - unsent.Length;
                _typeBox.Text = unsent;
                _typeBox.SelectionStart = Math.Clamp(consumed > 0 && _typeBox.Text == unsent ? caret - consumed : caret, 0, unsent.Length);
            }
            var transmitting = _sender.State == DigiSender.SenderState.Transmitting;
            _txButton.IsEnabled = !transmitting;
            _rxButton.IsEnabled = transmitting;
            _stopButton.IsEnabled = _sender.IsTransmitting;
            _levelSlider.IsEnabled = !_sender.IsTransmitting;
            _levelSlider.Value = _sender.LevelDb;
            _levelValue.Text = $"{(int)_sender.LevelDb} dB";
            if (_theirCallBox.Text != _sender.TheirCall)
            {
                _theirCallBox.Text = _sender.TheirCall;
            }
            _lookupButton.Visibility = LogbookPrograms.Current is { SupportsLookup: true } ? Visibility.Visible : Visibility.Collapsed;
            _lookupButton.IsEnabled = _sender.TheirCall.Length > 0;
        }
        finally
        {
            _updating = false;
        }
        RefreshSendLive();
    }

    /// TX state badge, elapsed time and the status line — also on the timer,
    /// since the transmit gate and the rig's state change without the sender
    /// saying so.
    private void RefreshSendLive()
    {
        if (_sender.TransmitStartedAt is { } start)
        {
            var elapsed = Math.Max(0, (int)(_sender.Now - start));
            var limit = (int)DigiSender.TransmitLimit;
            _stateLabel.Text = $"TX {elapsed / 60}:{elapsed % 60:00} / {limit / 60}:{limit % 60:00}";
            _stateLabel.Foreground = new SolidColorBrush(Microsoft.UI.Colors.White);
            _stateBadge.Background = new SolidColorBrush(Microsoft.UI.Colors.Red);
        }
        else
        {
            _stateLabel.Text = "RX";
            _stateLabel.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            _stateBadge.Background = null;
        }

        string? line;
        var isProblem = true;
        if (_lookupNote is not null)
        {
            // The Lookup's outcome is the newest thing the operator did: it
            // shows until Their call changes.
            line = _lookupNote;
            isProblem = _lookupNoteIsProblem;
        }
        else if ((_sender.Message ?? (_sender.IsTransmitting ? null : _sender.BlockReason) ?? _modSourceWarning) is { } message)
        {
            line = message;
        }
        else
        {
            line = _sender.IsTransmitting
                ? Loc.P("digiSendPane.queued", _sender.UnsentCount)
                : Loc.S("digiSendPane.ready");
            isProblem = false;
        }
        _statusText.Text = line;
        ToolTipService.SetToolTip(_statusText, line);
        _statusIcon.Visibility = isProblem ? Visibility.Visible : Visibility.Collapsed;
        _statusIcon.Foreground = new SolidColorBrush(Microsoft.UI.Colors.DarkOrange);

        // Re-read MOD SOURCE when the transmitting mode or the link changes.
        var key = $"{_sender.BlockReason is null}|{_link.IsConnected()}";
        if (key != _modSourceKey)
        {
            _modSourceKey = key;
            _ = RefreshModSourceAsync();
        }
    }

    private async Task RefreshModSourceAsync()
    {
        _modSourceWarning = await _link.ModSourceWarningAsync();
    }

    private void RebuildMacros()
    {
        _macroRow.Children.Clear();
        for (var i = 0; i < _macros.Count; i++)
        {
            var macro = _macros[i];
            var button = new Button { Content = macro.Label };
            ToolTipService.SetToolTip(button, macro.Text);
            button.Click += (_, _) => _sender.Run(macro);
            if (i < 9)
            {
                button.KeyboardAccelerators.Add(new KeyboardAccelerator
                {
                    Key = (VirtualKey)((int)VirtualKey.Number1 + i),
                    Modifiers = VirtualKeyModifiers.Control,
                });
            }
            _macroRow.Children.Add(button);
        }
    }

    private async Task LookUpAsync()
    {
        var call = _sender.TheirCall.Trim().ToUpperInvariant();
        if (call.Length == 0)
        {
            return;
        }
        _lookupButton.IsEnabled = false;
        var problem = await QsoLogger.LookUpAsync(call);
        _lookupButton.IsEnabled = _sender.TheirCall.Length > 0;
        _lookupNote = problem ?? Loc.F("cwLogPane.xSentToLog4OM", call);
        _lookupNoteIsProblem = problem is not null;
        RefreshSendLive();
    }

    private async Task EditMacrosAsync()
    {
        var edited = _macros.Select(m => new DigiMacro(m.Label, m.Text) { Id = m.Id }).ToList();
        var list = new StackPanel { Spacing = 8 };
        void Rebuild()
        {
            list.Children.Clear();
            foreach (var macro in edited.ToList())
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var label = new TextBox { Text = macro.Label, PlaceholderText = Loc.S("digiSendPane.label") };
                label.TextChanged += (_, _) => macro.Label = label.Text;
                var text = new TextBox
                {
                    Text = macro.Text.Replace("\n", "\r"),
                    PlaceholderText = Loc.S("digiSendPane.text"),
                    AcceptsReturn = true,
                    TextWrapping = TextWrapping.Wrap,
                    FontFamily = new FontFamily("Consolas"),
                    MaxHeight = 110,
                };
                text.TextChanged += (_, _) => macro.Text = text.Text.Replace("\r\n", "\n").Replace('\r', '\n');
                var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 } };
                ToolTipService.SetToolTip(remove, Loc.S("digiSendPane.removeThisMacro"));
                AutomationProperties.SetName(remove, Loc.S("digiSendPane.removeThisMacro"));
                remove.Click += (_, _) =>
                {
                    edited.Remove(macro);
                    Rebuild();
                };
                Grid.SetColumn(text, 1);
                Grid.SetColumn(remove, 2);
                row.Children.Add(label);
                row.Children.Add(text);
                row.Children.Add(remove);
                list.Children.Add(row);
            }
        }
        Rebuild();

        var add = new Button { Content = Loc.S("cwSendPane.add") };
        add.Click += (_, _) =>
        {
            edited.Add(new DigiMacro("New", "{TX}\n\n{RX}"));
            Rebuild();
        };
        var restore = new Button { Content = Loc.S("digiSendPane.restoreDefaults") };
        restore.Click += (_, _) =>
        {
            edited = DigiMacro.Defaults();
            Rebuild();
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(add);
        buttons.Children.Add(restore);

        var content = new StackPanel { Spacing = 10, Width = 640 };
        content.Children.Add(new TextBlock
        {
            Text = Loc.S("digiSendPane.macrosHelp"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        content.Children.Add(new ScrollViewer { Content = list, MaxHeight = 360 });
        content.Children.Add(buttons);

        var dialog = new ContentDialog
        {
            Title = Loc.S("digiSendPane.macrosTitle"),
            Content = content,
            PrimaryButtonText = Loc.S("common.done"),
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = _root.XamlRoot,
            RequestedTheme = _root.RequestedTheme,
        };
        try
        {
            await dialog.ShowAsync();
        }
        catch (COMException)
        {
            return;
        }
        _macros = edited;
        AppSettings.Digi.Macros = _macros;
        AppSettings.SaveDigi();
        RebuildMacros();
    }

    // Files and errors

    private async Task OpenFileAsync()
    {
        var picker = new Microsoft.Windows.Storage.Pickers.FileOpenPicker(AppWindow.Id)
        {
            SuggestedFolder = Recordings.Directory,
        };
        foreach (var type in new[] { ".wav", ".mp3", ".m4a", ".aac", ".wma", ".flac", ".aiff", ".aif" })
        {
            picker.FileTypeFilter.Add(type);
        }
        var result = await picker.PickSingleFileAsync();
        if (result is not null)
        {
            _receiver.DecodeFile(result.Path);
        }
    }

    private async void ShowError(string message)
    {
        var dialog = new ContentDialog
        {
            Title = "RTTY/PSK",
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = _root.XamlRoot,
            RequestedTheme = _root.RequestedTheme,
        };
        try
        {
            await dialog.ShowAsync();
        }
        catch (COMException)
        {
            // Another dialog is already open; the message is in app.log.
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}

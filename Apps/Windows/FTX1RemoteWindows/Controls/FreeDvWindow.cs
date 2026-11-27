using System.Globalization;
using System.Runtime.InteropServices;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.FreeDv;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace FTX1RemoteWindows.Controls;

/// What the FreeDV window needs from MainWindow beyond the receiver and
/// sender.
public sealed class FreeDvWindowLink
{
    /// Single-receive display ("FR"); null if not read or disconnected.
    public required Func<bool?> SingleReceive { get; init; }
    public required LocalSdrAudioSource LocalSdr { get; init; }
    /// What's wrong with the WebSDR source, null when it's fine.
    public required Func<string?> WebSdrNote { get; init; }
    public required Action ShowRecordings { get; init; }
    /// Tunes MAIN to a FreeDV Reporter station; returns why it didn't.
    public required Func<long, string?> TuneMain { get; init; }
}

/// Tools → FreeDV — the Mac's FreeDVWindowView: FreeDV RADE V1 from MAIN,
/// SUB, the WebSDR window or the MyKiwiSDR window, decoded to speech on this
/// PC, with the callsigns heard at each end-of-over, transmit from this PC's
/// microphone (TX/RX, or hold the space bar), and FreeDV Reporter: reporting
/// this station and listing the others (double-click tunes MAIN there).
///
/// Decodes only while open; the heard list lives in <see cref="FreeDvReceiver"/>
/// and the transmission in <see cref="FreeDvSender"/> (both owned by
/// MainWindow). Closing the window ends an over (the end-of-over still goes
/// out). Built in code, like the CW and RTTY/PSK windows.
public sealed class FreeDvWindow : Window
{
    private static readonly GridLength[] Columns = [new(90), new(130), new(70), new(140), new(1, GridUnitType.Star)];
    /// Callsign, grid, frequency, mode, last heard, message, time.
    private static readonly GridLength[] StationColumns =
        [new(95), new(65), new(110), new(100), new(130), new(1, GridUnitType.Star), new(50)];
    private static readonly FontFamily MonoFont = new("Consolas");

    private readonly FreeDvReceiver _receiver;
    private readonly FreeDvSender _sender;
    private readonly FreeDvWindowLink _link;

    /// Takes the keyboard focus, so the space bar reaches the window.
    private readonly ContentControl _host = new()
    {
        IsTabStop = true,
        UseSystemFocusVisuals = false,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        VerticalContentAlignment = VerticalAlignment.Stretch,
    };
    private readonly Grid _root = new();

    // Header
    private readonly SelectorBar _sourceBar = new();
    private readonly Dictionary<CwAudioChannel, SelectorBarItem> _sourceItems = [];
    private readonly ToggleButton _muteButton = new();
    private readonly FontIcon _muteIcon = new() { FontSize = 14 };
    private readonly Slider _volumeSlider = new() { Minimum = 0, Maximum = 1, StepFrequency = 0.01, Width = 110, VerticalAlignment = VerticalAlignment.Center, IsThumbToolTipEnabled = false };
    private readonly Button _openButton = new();
    private readonly Button _clearButton = new();

    // Transmit row
    private readonly Button _transmitButton = new() { MinWidth = 90 };
    private readonly TextBlock _transmitLabel = new();
    private readonly FontIcon _transmitIcon = new() { FontSize = 14 };
    private readonly TextBlock _elapsedText = new() { FontFamily = MonoFont, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressBar _micMeter = new() { Width = 90, Minimum = 0, Maximum = 1, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _holdSpaceText = new() { Text = Loc.S("freeDvWindow.holdSpace"), VerticalAlignment = VerticalAlignment.Center };
    private readonly Slider _levelSlider = new() { Minimum = FreeDvSender.MinLevelDb, Maximum = FreeDvSender.MaxLevelDb, StepFrequency = 1, Width = 100, VerticalAlignment = VerticalAlignment.Center, IsThumbToolTipEnabled = false };
    private readonly TextBlock _levelValue = new() { FontFamily = MonoFont, Width = 52, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _transmitStatus = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };

    // Status line
    private readonly Ellipse _syncDot = new() { Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _syncText = new() { MinWidth = 150, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _snrText = new() { FontFamily = MonoFont, MinWidth = 90, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _offsetText = new() { FontFamily = MonoFont, VerticalAlignment = VerticalAlignment.Center };

    private readonly StackPanel _notes = new() { Spacing = 3, Padding = new Thickness(16, 6, 16, 6) };
    private string _shownNotes = "";

    // Heard list
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly TextBlock _placeholder = new()
    {
        Text = Loc.S("freeDvWindow.placeholder"),
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        MaxWidth = 460,
        IsHitTestVisible = false,
    };
    private int _shownHeardCount;
    private FreeDvHeardStation? _shownNewest;

    // File line
    private readonly StackPanel _fileLine = new() { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(16, 6, 16, 6) };
    private readonly ProgressRing _fileRing = new() { Width = 16, Height = 16 };
    private readonly TextBlock _fileText = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 560 };
    private readonly Button _recordingsButton = new() { Content = Loc.S("freeDvWindow.showRecordings") };

    // FreeDV Reporter
    private readonly CheckBox _reportBox = new() { Content = Loc.S("freeDvWindow.reportToFreeDVReporter"), MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
    private readonly Ellipse _reporterDot = new() { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _reporterStatus = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox _messageBox = new() { Width = 220, PlaceholderText = Loc.S("freeDvWindow.message") };
    private readonly SelectorBar _listBar = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private readonly SelectorBarItem _heardTab = new();
    private readonly SelectorBarItem _reporterTab = new();
    private Grid _heardHost = null!;
    private Grid _stationHost = null!;
    private readonly ListView _stationList = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _stationPlaceholder = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
    };
    /// Rows by session id, updated in place so the list keeps its place.
    private readonly Dictionary<string, (Grid Row, FreeDvReporterStation Shown)> _stationRows = [];
    private readonly FreeDvReporter _reporter;

    private readonly DispatcherQueueTimer _timer;
    private bool _updating;

    public FreeDvWindow(FreeDvReceiver receiver, FreeDvSender sender, FreeDvReporter reporter, FreeDvWindowLink link)
    {
        _receiver = receiver;
        _sender = sender;
        _reporter = reporter;
        _link = link;
        Title = "FreeDV";
        // AppWindow sizes are physical pixels; scale from DIPs.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(980 * scale), (int)(620 * scale)));

        for (var i = 0; i < 8; i++)
        {
            _root.RowDefinitions.Add(new RowDefinition { Height = i == 6 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        }
        AddRow(BuildHeader(), 0);
        AddRow(BuildTransmitRow(), 1);
        AddRow(BuildReporterRow(), 2);
        AddRow(BuildStatusLine(), 3);
        Grid.SetRow(_notes, 4);
        _root.Children.Add(_notes);
        Grid.SetRow(BuildListBar(), 5);
        _root.Children.Add(_listBar);
        _heardHost = BuildHeardList();
        Grid.SetRow(_heardHost, 6);
        _root.Children.Add(_heardHost);
        _stationHost = BuildStationList();
        Grid.SetRow(_stationHost, 6);
        _root.Children.Add(_stationHost);
        BuildFileLine();
        Grid.SetRow(_fileLine, 7);
        _root.Children.Add(_fileLine);

        _host.Content = _root;
        Content = _host;
        ApplyTheme();

        // Hold the space bar to talk (while this window has the keyboard).
        // Taken on the way down, so it never presses the focused button.
        _host.PreviewKeyDown += (_, e) =>
        {
            // A space typed into the status message is just a space.
            if (e.Key != VirtualKey.Space || e.OriginalSource is TextBox)
            {
                return;
            }
            e.Handled = true;
            if (!e.KeyStatus.WasKeyDown && _sender.State == FreeDvSender.SenderState.Idle)
            {
                _sender.Start(FreeDvSender.Trigger.Momentary);
            }
        };
        _host.PreviewKeyUp += (_, e) =>
        {
            if (e.Key == VirtualKey.Space && e.OriginalSource is not TextBox)
            {
                e.Handled = true;
                _sender.ReleaseMomentary();
            }
        };
        _host.Loaded += (_, _) => _host.Focus(FocusState.Programmatic);
        // The key's release goes elsewhere once another window has the
        // keyboard: end the over rather than stay keyed.
        Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated)
            {
                _sender.ReleaseMomentary();
            }
        };

        _receiver.Changed += Refresh;
        _receiver.Error += ShowError;
        _sender.Changed += Refresh;
        _link.LocalSdr.Changed += Refresh;
        _reporter.Changed += RefreshReporter;
        _reporter.StationsChanged += RefreshStations;
        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(100);
        _timer.Tick += (_, _) => RefreshLive();
        _timer.Start();
        Closed += (_, _) =>
        {
            _timer.Stop();
            _receiver.Changed -= Refresh;
            _receiver.Error -= ShowError;
            _sender.Changed -= Refresh;
            _link.LocalSdr.Changed -= Refresh;
            _reporter.Changed -= RefreshReporter;
            _reporter.StationsChanged -= RefreshStations;
            CommitMessage();
        };
        Refresh();
        RefreshStations();
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        ThemeEngine.ApplyTo(_host);
        _root.Background = ThemeEngine.WindowBackground;
        var secondary = Secondary;
        _holdSpaceText.Foreground = secondary;
        _placeholder.Foreground = secondary;
        _fileText.Foreground = secondary;
        _reporterStatus.Foreground = secondary;
        _stationPlaceholder.Foreground = secondary;
        _shownNotes = "";
        _shownHeardCount = -1;
        _stationRows.Clear();
        _stationList.Items.Clear();
        Refresh();
        RefreshStations();
    }

    private static Brush Secondary => (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];

    // Layout

    private void AddRow(FrameworkElement element, int row)
    {
        Grid.SetRow(element, row);
        _root.Children.Add(element);
        var line = new Rectangle
        {
            Height = 1,
            Fill = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        Grid.SetRow(line, row);
        _root.Children.Add(line);
    }

    private Grid BuildHeader()
    {
        var header = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        foreach (var channel in new[] { CwAudioChannel.Main, CwAudioChannel.Sub, CwAudioChannel.WebSdr, CwAudioChannel.MyKiwiSdr })
        {
            var item = new SelectorBarItem { Text = CwWindow.ChannelLabel(channel), Tag = channel };
            _sourceItems[channel] = item;
            _sourceBar.Items.Add(item);
        }
        ToolTipService.SetToolTip(_sourceBar, Loc.S("freeDvWindow.whichAudio"));
        _sourceBar.SelectionChanged += (bar, _) =>
        {
            if (!_updating && bar.SelectedItem?.Tag is CwAudioChannel channel)
            {
                _receiver.Channel = channel;
            }
        };
        header.Children.Add(_sourceBar);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        _muteButton.Content = _muteIcon;
        _muteButton.Click += (_, _) => { if (!_updating) _receiver.IsMuted = _muteButton.IsChecked == true; };
        _volumeSlider.ValueChanged += (_, e) => { if (!_updating) _receiver.Volume = e.NewValue; };
        ToolTipService.SetToolTip(_volumeSlider, Loc.S("freeDvWindow.volume"));
        AutomationProperties.SetName(_volumeSlider, Loc.S("freeDvWindow.volume"));
        SetContent(_openButton, "", Loc.S("cwWindow.openAudioFile"));
        ToolTipService.SetToolTip(_openButton, Loc.S("freeDvWindow.decodeARecording"));
        _openButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.O, Modifiers = VirtualKeyModifiers.Control });
        _openButton.Click += async (_, _) => await OpenFileAsync();
        SetContent(_clearButton, "", Loc.S("common.clear"));
        ToolTipService.SetToolTip(_clearButton, Loc.S("freeDvWindow.clearTheList"));
        _clearButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.K, Modifiers = VirtualKeyModifiers.Control });
        _clearButton.Click += (_, _) => _receiver.ClearHeard();
        buttons.Children.Add(_muteButton);
        buttons.Children.Add(_volumeSlider);
        buttons.Children.Add(_openButton);
        buttons.Children.Add(_clearButton);
        Grid.SetColumn(buttons, 2);
        header.Children.Add(buttons);
        return header;
    }

    private Grid BuildTransmitRow()
    {
        var row = new Grid { Padding = new Thickness(16, 6, 16, 6), ColumnSpacing = 14 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(_transmitIcon);
        content.Children.Add(_transmitLabel);
        _transmitButton.Content = content;
        _transmitButton.Click += (_, _) =>
        {
            if (_sender.State == FreeDvSender.SenderState.Idle)
            {
                _sender.Start(FreeDvSender.Trigger.Toggle);
            }
            else
            {
                _sender.Finish();
            }
        };
        _transmitButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.T, Modifiers = VirtualKeyModifiers.Control });
        ToolTipService.SetToolTip(_transmitButton, Loc.S("freeDvWindow.transmitHelp"));

        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        left.Children.Add(_transmitButton);
        left.Children.Add(_elapsedText);
        ToolTipService.SetToolTip(_micMeter, Loc.S("freeDvWindow.micLevelHelp"));
        left.Children.Add(_micMeter);
        left.Children.Add(_holdSpaceText);
        var level = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        level.Children.Add(Label(Loc.S("freeDvWindow.level")));
        _levelSlider.Value = _sender.LevelDb;
        _levelSlider.ValueChanged += (_, e) =>
        {
            if (_updating)
            {
                return;
            }
            _sender.LevelDb = e.NewValue;
            AppSettings.FreeDv.TxLevelDb = _sender.LevelDb;
            AppSettings.SaveFreeDv();
            _levelValue.Text = $"{(int)_sender.LevelDb} dB";
        };
        AutomationProperties.SetName(_levelSlider, Loc.S("freeDvWindow.level"));
        level.Children.Add(_levelSlider);
        level.Children.Add(_levelValue);
        ToolTipService.SetToolTip(level, Loc.S("freeDvWindow.levelHelp"));
        left.Children.Add(level);
        row.Children.Add(left);
        Grid.SetColumn(_transmitStatus, 1);
        row.Children.Add(_transmitStatus);
        return row;
    }

    private StackPanel BuildStatusLine()
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, Padding = new Thickness(16, 6, 16, 6) };
        var sync = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        sync.Children.Add(_syncDot);
        sync.Children.Add(_syncText);
        bar.Children.Add(sync);
        bar.Children.Add(_snrText);
        ToolTipService.SetToolTip(_offsetText, Loc.S("freeDvWindow.offsetHelp"));
        bar.Children.Add(_offsetText);
        return bar;
    }

    private Grid BuildHeardList()
    {
        var host = new Grid();
        host.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        host.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = Row(Columns, bold: true, Loc.S("freeDvWindow.timeUTC"), Loc.S("freeDvWindow.callsign"), "SNR",
            Loc.S("freeDvWindow.frequency"), Loc.S("freeDvWindow.source"));
        header.Padding = new Thickness(16, 6, 12, 4);
        host.Children.Add(header);
        Grid.SetRow(_list, 1);
        Grid.SetRow(_placeholder, 1);
        host.Children.Add(_list);
        host.Children.Add(_placeholder);
        return host;
    }

    private Grid BuildReporterRow()
    {
        var row = new Grid { Padding = new Thickness(16, 6, 16, 6), ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ToolTipService.SetToolTip(_reportBox, Loc.S("freeDvWindow.reportHelp"));
        _reportBox.Click += (_, _) => { if (!_updating) _reporter.Enabled = _reportBox.IsChecked == true; };
        ToolTipService.SetToolTip(_messageBox, Loc.S("freeDvWindow.messageHelp"));
        AutomationProperties.SetName(_messageBox, Loc.S("freeDvWindow.message"));
        _messageBox.Text = _reporter.Message;
        // Sent on Return or when the box loses the keyboard, not per key.
        _messageBox.LostFocus += (_, _) => CommitMessage();
        _messageBox.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter)
            {
                e.Handled = true;
                CommitMessage();
                // Back to the window, so Space talks again.
                _host.Focus(FocusState.Programmatic);
            }
        };
        row.Children.Add(_reportBox);
        Grid.SetColumn(_reporterDot, 1);
        row.Children.Add(_reporterDot);
        Grid.SetColumn(_reporterStatus, 2);
        row.Children.Add(_reporterStatus);
        Grid.SetColumn(_messageBox, 3);
        row.Children.Add(_messageBox);
        return row;
    }

    private void CommitMessage() => _reporter.Message = _messageBox.Text;

    private SelectorBar BuildListBar()
    {
        _listBar.Items.Add(_heardTab);
        _listBar.Items.Add(_reporterTab);
        _listBar.SelectionChanged += (bar, _) =>
        {
            if (!_updating && bar.SelectedItem is { } item)
            {
                AppSettings.FreeDv.ShowReporterList = ReferenceEquals(item, _reporterTab);
                AppSettings.SaveFreeDv();
                RefreshReporter();
            }
        };
        return _listBar;
    }

    private Grid BuildStationList()
    {
        var host = new Grid();
        host.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        host.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = Row(StationColumns, bold: true, Loc.S("freeDvWindow.callsign"), Loc.S("freeDvWindow.grid"),
            Loc.S("freeDvWindow.frequency"), Loc.S("freeDvWindow.mode"), Loc.S("freeDvWindow.lastHeard"),
            Loc.S("freeDvWindow.statusMessage"), Loc.S("freeDvWindow.updated"));
        header.Padding = new Thickness(16, 6, 12, 4);
        host.Children.Add(header);
        // Rows stretch, so the columns line up with the header's.
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _stationList.ItemContainerStyle = style;
        Grid.SetRow(_stationList, 1);
        Grid.SetRow(_stationPlaceholder, 1);
        host.Children.Add(_stationList);
        host.Children.Add(_stationPlaceholder);
        return host;
    }

    private void BuildFileLine()
    {
        _recordingsButton.Click += (_, _) => _link.ShowRecordings();
        _fileLine.Children.Add(_fileRing);
        _fileLine.Children.Add(_fileText);
        _fileLine.Children.Add(_recordingsButton);
    }

    private static TextBlock Label(string text) => new() { Text = text, VerticalAlignment = VerticalAlignment.Center };

    private static void SetContent(Button button, string glyph, string text)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        panel.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        panel.Children.Add(new TextBlock { Text = text });
        button.Content = panel;
        AutomationProperties.SetName(button, text);
    }

    // Refresh

    /// Everything that changes on an event.
    private void Refresh()
    {
        _updating = true;
        try
        {
            var selected = _sourceItems[_receiver.Channel];
            if (!selected.IsSelected)
            {
                selected.IsSelected = true;
            }
            _muteButton.IsChecked = _receiver.IsMuted;
            _muteIcon.Glyph = _receiver.IsMuted ? "" : "";
            var muteHelp = _receiver.IsMuted ? Loc.S("freeDvWindow.unmuteHelp") : Loc.S("freeDvWindow.muteHelp");
            ToolTipService.SetToolTip(_muteButton, muteHelp);
            AutomationProperties.SetName(_muteButton, muteHelp);
            _volumeSlider.Value = _receiver.Volume;
            _volumeSlider.IsEnabled = !_receiver.IsMuted;
            _levelSlider.Value = _sender.LevelDb;
            _levelValue.Text = $"{(int)_sender.LevelDb} dB";
        }
        finally
        {
            _updating = false;
        }
        _openButton.IsEnabled = !_receiver.IsDecodingFile;
        _clearButton.IsEnabled = _receiver.Heard.Count > 0;
        RefreshHeard();
        RefreshReporter();
        RefreshFileLine();
        RefreshLive();
    }

    /// The reporter row, the list switch and which list shows.
    private void RefreshReporter()
    {
        var enabled = _reporter.Enabled;
        var showStations = enabled && AppSettings.FreeDv.ShowReporterList;
        var count = _reporter.Stations.Count;
        _updating = true;
        try
        {
            _reportBox.IsChecked = enabled;
            _heardTab.Text = Loc.F("freeDvWindow.heardTab", _receiver.Heard.Count);
            _reporterTab.Text = Loc.F("freeDvWindow.reporterTab", count);
            var tab = showStations ? _reporterTab : _heardTab;
            if (!tab.IsSelected)
            {
                tab.IsSelected = true;
            }
        }
        finally
        {
            _updating = false;
        }
        var visible = enabled ? Visibility.Visible : Visibility.Collapsed;
        _reporterDot.Visibility = _reporterStatus.Visibility = _messageBox.Visibility = _listBar.Visibility = visible;
        _heardHost.Visibility = showStations ? Visibility.Collapsed : Visibility.Visible;
        _stationHost.Visibility = showStations ? Visibility.Visible : Visibility.Collapsed;
        var status = _reporter.Status;
        _reporterDot.Fill = new SolidColorBrush(status switch
        {
            FreeDvReporter.ConnectionStatus.Connected => Microsoft.UI.Colors.LimeGreen,
            FreeDvReporter.ConnectionStatus.Connecting => Microsoft.UI.Colors.Gold,
            FreeDvReporter.ConnectionStatus.Retrying or FreeDvReporter.ConnectionStatus.NeedsStation => Microsoft.UI.Colors.DarkOrange,
            _ => Microsoft.UI.Colors.Gray,
        });
        var text = status switch
        {
            FreeDvReporter.ConnectionStatus.NeedsStation => Loc.S("freeDvWindow.reporterNeedsStation"),
            FreeDvReporter.ConnectionStatus.Connecting => Loc.S("freeDvWindow.reporterConnecting"),
            FreeDvReporter.ConnectionStatus.Connected => Loc.F("freeDvWindow.reporterConnected", count),
            FreeDvReporter.ConnectionStatus.Retrying => Loc.F("freeDvWindow.reporterRetrying", _reporter.RetryReason),
            _ => "",
        };
        if (_reporterStatus.Text != text)
        {
            _reporterStatus.Text = text;
            ToolTipService.SetToolTip(_reporterStatus, text.Length == 0 ? null : text);
        }
        _stationPlaceholder.Text = status == FreeDvReporter.ConnectionStatus.Connected
            ? Loc.S("freeDvWindow.reporterEmpty")
            : Loc.S("freeDvWindow.reporterNotConnected");
        _stationPlaceholder.Visibility = count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Updates the rows in place and moves them into order.
    private void RefreshStations()
    {
        var stations = _reporter.Stations;
        var items = _stationList.Items;
        for (var i = 0; i < stations.Count; i++)
        {
            var station = stations[i];
            if (!_stationRows.TryGetValue(station.Id, out var entry))
            {
                entry = (StationRow(station.Id), station with { Callsign = "" });
            }
            if (entry.Shown != station)
            {
                FillStationRow(entry.Row, station);
                _stationRows[station.Id] = (entry.Row, station);
            }
            if (i >= items.Count || !ReferenceEquals(items[i], entry.Row))
            {
                var selected = ReferenceEquals(_stationList.SelectedItem, entry.Row);
                items.Remove(entry.Row);
                items.Insert(i, entry.Row);
                if (selected)
                {
                    _stationList.SelectedItem = entry.Row;
                }
            }
        }
        while (items.Count > stations.Count)
        {
            items.RemoveAt(items.Count - 1);
        }
        var ids = stations.Select(s => s.Id).ToHashSet();
        foreach (var gone in _stationRows.Keys.Where(id => !ids.Contains(id)).ToList())
        {
            _stationRows.Remove(gone);
        }
        RefreshReporter();
    }

    private Grid StationRow(string id)
    {
        var row = Row(StationColumns, bold: false, "", "", "", "", "", "", "");
        // Hit-testable between the texts too, and no text selection, which
        // would take the double-click.
        row.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        foreach (var text in row.Children.OfType<TextBlock>())
        {
            text.IsTextSelectionEnabled = false;
        }
        ((TextBlock)row.Children[0]).FontFamily = MonoFont;
        ((TextBlock)row.Children[0]).FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        ((TextBlock)row.Children[1]).FontFamily = MonoFont;
        row.DoubleTapped += (_, _) => Tune(id);
        var menu = new MenuFlyout();
        var item = new MenuFlyoutItem();
        item.Click += (_, _) => Tune(id);
        menu.Items.Add(item);
        menu.Opening += (_, _) =>
        {
            var hz = Station(id)?.FrequencyHz;
            item.IsEnabled = hz is not null;
            item.Text = hz is { } value
                ? Loc.F("freeDvWindow.tuneMain", Recordings.Label(value, ""))
                : "—";
        };
        row.ContextFlyout = menu;
        return row;
    }

    private static void FillStationRow(Grid row, FreeDvReporterStation station)
    {
        var mode = station.Mode ?? (station.ReceiveOnly ? "RX" : "—");
        string[] cells =
        [
            station.Callsign,
            station.GridSquare,
            station.FrequencyHz is { } hz ? Recordings.Label(hz, "") : "—",
            station.Transmitting ? $"{mode}  TX" : mode,
            station.LastHeardCallsign is { } call
                ? station.LastHeardSnr is { } snr ? $"{call} {(int)Math.Round(snr)} dB" : call
                : "",
            station.Message,
            station.LastUpdateUtc?.ToString("HH:mm", CultureInfo.InvariantCulture) ?? "",
        ];
        for (var i = 0; i < cells.Length; i++)
        {
            var text = (TextBlock)row.Children[i];
            text.Text = cells[i];
            ToolTipService.SetToolTip(text, cells[i].Length == 0 ? null : cells[i]);
        }
        var modeText = (TextBlock)row.Children[3];
        if (station.Transmitting)
        {
            modeText.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Red);
            modeText.FontWeight = Microsoft.UI.Text.FontWeights.Bold;
        }
        else
        {
            modeText.ClearValue(TextBlock.ForegroundProperty);
            modeText.FontWeight = Microsoft.UI.Text.FontWeights.Normal;
        }
    }

    private FreeDvReporterStation? Station(string id) => _reporter.Stations.FirstOrDefault(s => s.Id == id);

    private void Tune(string id)
    {
        if (Station(id)?.FrequencyHz is { } hz && _link.TuneMain(hz) is { } problem)
        {
            ShowError(problem);
        }
    }

    /// The timer's part: readings, and the notes that depend on state nothing
    /// announces (Sub audio, the rig's display mode, the speech output).
    private void RefreshLive()
    {
        RefreshSources();
        RefreshTransmit();
        RefreshStatus();
        RefreshNotes();
    }

    private string? SubUnavailableReason()
    {
        if (!_receiver.IsSubAudioAvailable)
        {
            return Loc.S("cwWindow.noSUBAudioThe");
        }
        return _link.SingleReceive() == true ? Loc.S("cwWindow.sUBIsOffThe") : null;
    }

    private void RefreshSources()
    {
        // MyKiwiSDR is offered only while Settings → Devices has it enabled;
        // if it gets disabled while selected, fall back to MAIN.
        var kiwiOffered = AppSettings.LocalSdr.IsEnabled;
        if (!kiwiOffered && _receiver.Channel == CwAudioChannel.MyKiwiSdr)
        {
            _receiver.Channel = CwAudioChannel.Main;
        }
        var visibility = kiwiOffered ? Visibility.Visible : Visibility.Collapsed;
        var kiwi = _sourceItems[CwAudioChannel.MyKiwiSdr];
        if (kiwi.Visibility != visibility)
        {
            kiwi.Visibility = visibility;
        }
        var enabled = SubUnavailableReason() is null || _receiver.Channel == CwAudioChannel.Sub;
        var sub = _sourceItems[CwAudioChannel.Sub];
        if (sub.IsEnabled != enabled)
        {
            sub.IsEnabled = enabled;
        }
    }

    private void RefreshTransmit()
    {
        var idle = _sender.State == FreeDvSender.SenderState.Idle;
        _transmitLabel.Text = idle ? Loc.S("freeDvWindow.transmit") : Loc.S("freeDvWindow.receive");
        _transmitIcon.Glyph = idle ? "" : "";
        _transmitButton.IsEnabled = _sender.State != FreeDvSender.SenderState.Finishing;
        if (idle)
        {
            _transmitButton.ClearValue(Control.BackgroundProperty);
            _transmitButton.ClearValue(Control.ForegroundProperty);
        }
        else
        {
            _transmitButton.Background = new SolidColorBrush(Microsoft.UI.Colors.Red);
            _transmitButton.Foreground = new SolidColorBrush(Microsoft.UI.Colors.White);
        }

        var started = _sender.TransmitStartedAt;
        _elapsedText.Visibility = _micMeter.Visibility = started is null ? Visibility.Collapsed : Visibility.Visible;
        _holdSpaceText.Visibility = started is null ? Visibility.Visible : Visibility.Collapsed;
        if (started is { } start)
        {
            var elapsed = Math.Max(0, (int)(_sender.Now - start));
            _elapsedText.Text = $"{elapsed / 60}:{elapsed % 60:00}";
            _elapsedText.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Red);
            // −60…0 dBFS: green, yellow above −12, red above −3.
            var peak = _sender.MicPeakDb;
            _micMeter.Value = Math.Clamp((peak - FreeDvSender.MicFloorDb) / -FreeDvSender.MicFloorDb, 0, 1);
            _micMeter.Foreground = new SolidColorBrush(peak > -3 ? Microsoft.UI.Colors.Red
                : peak > -12 ? Microsoft.UI.Colors.Gold : Microsoft.UI.Colors.LimeGreen);
        }

        var callsign = AppSettings.Callsign.Trim();
        var (text, problem) = _sender.Message is { } message
            ? (message, true)
            : callsign.Length == 0
                ? (Loc.S("freeDvWindow.noCallsign"), false)
                : (Loc.F("freeDvWindow.sendsCallsign", callsign.ToUpperInvariant()), false);
        if (_transmitStatus.Text != text)
        {
            _transmitStatus.Text = text;
            ToolTipService.SetToolTip(_transmitStatus, text);
        }
        _transmitStatus.Foreground = problem ? new SolidColorBrush(Microsoft.UI.Colors.DarkOrange) : Secondary;
    }

    private void RefreshStatus()
    {
        var status = _receiver.Status;
        _syncDot.Fill = new SolidColorBrush(status.Sync ? Microsoft.UI.Colors.LimeGreen : Microsoft.UI.Colors.Gray);
        _syncText.Text = status.Sync ? Loc.S("freeDvWindow.receiving") : Loc.S("freeDvWindow.noSignal");
        _syncText.FontWeight = status.Sync ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
        var offset = (int)Math.Round(status.FrequencyOffsetHz);
        _snrText.Text = Loc.F("freeDvWindow.snr", (int)Math.Round(status.SnrDb));
        _offsetText.Text = Loc.F("freeDvWindow.offset", offset > 0 ? $"+{offset}" : offset.ToString(CultureInfo.InvariantCulture));
        if (status.Sync)
        {
            _snrText.ClearValue(TextBlock.ForegroundProperty);
            _offsetText.ClearValue(TextBlock.ForegroundProperty);
        }
        else
        {
            _snrText.Foreground = _offsetText.Foreground = Secondary;
        }
    }

    /// What might keep FreeDV from being heard, and what the window is doing
    /// to the other audio.
    private List<string> Notes()
    {
        var notes = new List<string>();
        var channel = _receiver.Channel;
        var source = CwWindow.ChannelLabel(channel);
        if (_receiver.DecoderProblem is { } decoder)
        {
            notes.Add(decoder);
        }
        if (_receiver.IsPausedForTransmit)
        {
            notes.Add(Loc.S("cwWindow.pausedWhileTransmitting"));
        }
        if (_receiver.ModeHint is { } hint)
        {
            notes.Add(hint.Expected switch
            {
                FreeDvSideband.Lower => Loc.F("freeDvWindow.useLSB", source, hint.Mode),
                FreeDvSideband.Upper => Loc.F("freeDvWindow.useUSB", source, hint.Mode),
                _ => Loc.F("freeDvWindow.useSSB", source, hint.Mode),
            });
        }
        if (_receiver.OutputProblem is { } output && !_receiver.IsMuted)
        {
            notes.Add(Loc.F("freeDvWindow.noSpeechOutput", output));
        }
        if (_receiver.IsReceivingVoice && channel is CwAudioChannel.Main or CwAudioChannel.Sub)
        {
            notes.Add(Loc.F("freeDvWindow.rigAudioMuted", source));
        }
        switch (channel)
        {
            case CwAudioChannel.Sub when SubUnavailableReason() is { } reason:
                notes.Add(reason);
                break;
            case CwAudioChannel.MyKiwiSdr:
                notes.Add(_link.LocalSdr.Status switch
                {
                    LocalSdrAudioSource.SourceStatus.NotConnected => Loc.S("cwWindow.myKiwiSDRNotConnected"),
                    LocalSdrAudioSource.SourceStatus.Silent => Loc.S("cwWindow.myKiwiSDRSilent"),
                    _ => Loc.S("freeDvWindow.kiwiStillPlays"),
                });
                break;
            case CwAudioChannel.WebSdr:
                // Muting the WebSDR would stop the decoding here (Windows
                // can't capture a muted page), unlike the Mac.
                notes.Add(_link.WebSdrNote() ?? Loc.S("freeDvWindow.webSDRStillPlays"));
                break;
        }
        return notes;
    }

    private void RefreshNotes()
    {
        var notes = Notes();
        var joined = string.Join("\n", notes);
        if (joined == _shownNotes && _notes.Children.Count == notes.Count)
        {
            return;
        }
        _shownNotes = joined;
        _notes.Children.Clear();
        foreach (var note in notes)
        {
            _notes.Children.Add(new TextBlock { Text = note, TextWrapping = TextWrapping.Wrap, Foreground = Secondary });
        }
        _notes.Visibility = notes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RefreshHeard()
    {
        var heard = _receiver.Heard;
        _placeholder.Visibility = heard.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var newest = heard.Count > 0 ? heard[0] : null;
        if (heard.Count == _shownHeardCount && ReferenceEquals(newest, _shownNewest))
        {
            return;
        }
        _shownHeardCount = heard.Count;
        _shownNewest = newest;
        _list.Items.Clear();
        foreach (var station in heard)
        {
            var row = Row(Columns, bold: false,
                station.TimeUtc.ToString("HH:mm:ss", CultureInfo.InvariantCulture),
                station.Callsign,
                station.SnrDb is { } snr ? $"{(int)Math.Round(snr)} dB" : "—",
                station.FrequencyHz is { } hz ? Recordings.Label(hz, "") : "—",
                station.FromFile ? Loc.S("freeDvWindow.fromFile") : CwWindow.ChannelLabel(station.Channel));
            var callsign = (TextBlock)row.Children[1];
            callsign.FontFamily = MonoFont;
            callsign.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            _list.Items.Add(row);
        }
    }

    private void RefreshFileLine()
    {
        var decoding = _receiver.IsDecodingFile;
        var saved = _receiver.LastDecodedFile;
        _fileLine.Visibility = decoding || saved is not null ? Visibility.Visible : Visibility.Collapsed;
        _fileRing.IsActive = decoding;
        _fileRing.Visibility = decoding ? Visibility.Visible : Visibility.Collapsed;
        _fileText.Text = decoding
            ? Loc.S("freeDvWindow.decodingFile")
            : saved is null ? "" : Loc.F("freeDvWindow.savedDecodedSpeech", System.IO.Path.GetFileName(saved));
        _recordingsButton.Visibility = !decoding && saved is not null ? Visibility.Visible : Visibility.Collapsed;
    }

    private static Grid Row(GridLength[] columns, bool bold, params string[] cells)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        foreach (var width in columns)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }
        for (var i = 0; i < cells.Length; i++)
        {
            var text = new TextBlock
            {
                Text = cells[i],
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
                IsTextSelectionEnabled = !bold,
            };
            if (bold)
            {
                text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            }
            Grid.SetColumn(text, i);
            grid.Children.Add(text);
        }
        return grid;
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
            Title = "FreeDV",
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = _host.XamlRoot,
            RequestedTheme = _host.RequestedTheme,
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

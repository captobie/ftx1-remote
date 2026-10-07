using System.Runtime.InteropServices;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows.Controls;

/// The memory list window (the Mem List button under Waterfall) — the
/// Mac's MemoryListView: the rig's programmed channels from
/// MemoryListStore (channel, tag, frequency, mode, shift, tone type), with
/// a search box and MAIN/SUB buttons per row that recall the channel on
/// that receiver. The button of the channel a receiver is on is shown in
/// the accent style. Built in code, like the APRS lists.
///
/// Rows are rebuilt only when the list's contents change (coalesced while
/// a scan fills it in); the current-channel highlight is restyled in place
/// on each poll.
///
/// The toolbar also drives the rig's memory scan (MainWindow.MemoryScan.cs,
/// the Mac's MemoryListView scan controls) — not the Refresh read of the
/// list, which this file otherwise calls a scan: a MAIN/SUB picker with
/// Scan Down/Up while stopped, then Skip (paused only) and Stop Scan.
public sealed class MemoryListWindow : Window
{
    private readonly MemoryListStore _store;
    private readonly Func<RigctldClient?> _clientProvider;
    private readonly Func<int, bool, Task> _recall;
    private readonly Func<bool, bool, Task> _startScan;
    private readonly Func<Task> _skipScan;
    private readonly Func<Task> _stopScan;
    private readonly ComboBox _scanSide = new() { Items = { "MAIN", "SUB" }, SelectedIndex = 0, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _scanDownButton = new() { Content = "Scan Down" };
    private readonly Button _scanUpButton = new() { Content = "Scan Up" };
    private readonly Button _skipButton = new() { Content = "Skip" };
    private readonly Button _stopScanButton = new() { Content = "Stop Scan" };
    private MemoryScanState? _memoryScan;
    private bool _memoryScanSub;
    private bool _canScanMain;
    private bool _canScanSub;
    private int? _scanChannel;
    private readonly Grid _root = new() { Padding = new Thickness(12), RowSpacing = 8 };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly TextBox _search = new() { PlaceholderText = "Name, channel, frequency", Width = 240 };
    private readonly Button _refreshButton = new() { Content = "Refresh" };
    private readonly TextBlock _statusText = new() { Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly StackPanel _emptyPanel = new() { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 420 };
    private readonly TextBlock _emptyHint = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray) };
    /// Each shown row's MAIN/SUB buttons, for the highlight and enabling.
    private readonly Dictionary<int, (Button Main, Button Sub)> _rowButtons = [];
    private bool _connected;
    private int? _mainChannel;
    private int? _subChannel;
    private bool _rebuildScheduled;

    private static readonly FontFamily MonoFont = new("Consolas");

    private static readonly GridLength[] Columns =
        [new(40), new(130), new(124), new(100), new(80), new(40), new(1, GridUnitType.Star)];

    /// <param name="clientProvider">MainWindow's current client (null while disconnected).</param>
    /// <param name="recall">Recalls (channel, sub) — MainWindow.RecallMemoryChannelAsync.</param>
    /// <param name="startScan">Starts the memory scan (sub, up) — MainWindow.StartMemoryScanAsync.</param>
    public MemoryListWindow(MemoryListStore store, Func<RigctldClient?> clientProvider, Func<int, bool, Task> recall,
        Func<bool, bool, Task> startScan, Func<Task> skipScan, Func<Task> stopScan)
    {
        _store = store;
        _clientProvider = clientProvider;
        _recall = recall;
        _startScan = startScan;
        _skipScan = skipScan;
        _stopScan = stopScan;
        Title = "Memory Channels";
        // AppWindow sizes are physical pixels; scale from DIPs.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(880 * scale), (int)(560 * scale)));

        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var toolbar = new Grid { ColumnSpacing = 12 };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _search.TextChanged += (_, _) => Rebuild();
        toolbar.Children.Add(_search);
        Grid.SetColumn(_statusText, 1);
        toolbar.Children.Add(_statusText);

        var scanPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        ToolTipService.SetToolTip(_scanSide, "Which receiver to scan");
        _scanSide.SelectionChanged += (_, _) => UpdateScanControls();
        _scanDownButton.Click += async (_, _) => await _startScan(_scanSide.SelectedIndex == 1, false);
        _scanUpButton.Click += async (_, _) => await _startScan(_scanSide.SelectedIndex == 1, true);
        _skipButton.Click += async (_, _) => await _skipScan();
        _stopScanButton.Click += async (_, _) => await _stopScan();
        ToolTipService.SetToolTip(_skipButton, "Resume the scan past this channel");
        foreach (var control in new FrameworkElement[] { _scanSide, _scanDownButton, _scanUpButton, _skipButton, _stopScanButton })
        {
            scanPanel.Children.Add(control);
        }
        Grid.SetColumn(scanPanel, 2);
        toolbar.Children.Add(scanPanel);
        UpdateScanControls();
        _refreshButton.Click += (_, _) =>
        {
            if (_store.IsScanning)
            {
                _store.Cancel();
            }
            else
            {
                _store.Refresh(_clientProvider);
            }
        };
        Grid.SetColumn(_refreshButton, 3);
        toolbar.Children.Add(_refreshButton);
        _root.Children.Add(toolbar);

        var header = Row(bold: true, "Ch", "Name", "", "Frequency", "Mode", "Shift", "Tone");
        // Lines the header up with the ListView items' own inner padding.
        header.Padding = new Thickness(16, 0, 12, 4);
        Grid.SetRow(header, 1);
        _root.Children.Add(header);

        _emptyPanel.Children.Add(new TextBlock
        {
            Text = "No Channels",
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        _emptyPanel.Children.Add(_emptyHint);
        Grid.SetRow(_list, 2);
        Grid.SetRow(_emptyPanel, 2);
        _root.Children.Add(_list);
        _root.Children.Add(_emptyPanel);

        Content = _root;
        ApplyTheme();

        _store.EntriesChanged += ScheduleRebuild;
        _store.StatusChanged += UpdateStatus;
        Closed += (_, _) =>
        {
            _store.EntriesChanged -= ScheduleRebuild;
            _store.StatusChanged -= UpdateStatus;
        };
        Rebuild();
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        _root.RequestedTheme = AppSettings.Theme.ElementTheme();
        _root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
    }

    /// From MainWindow's memory display update (every poll, so unchanged
    /// calls return at once). The cache is all the window
    /// needs once a list has been read; only a first-ever open reads the
    /// rig without being asked.
    public void SetConnected(bool connected)
    {
        if (connected == _connected)
        {
            return;
        }
        _connected = connected;
        foreach (var (main, sub) in _rowButtons.Values)
        {
            main.IsEnabled = connected;
            sub.IsEnabled = connected;
        }
        if (connected && _store.LastScanned is null && !_store.IsScanning)
        {
            _store.Refresh(_clientProvider);
        }
        UpdateScanControls();
        UpdateStatus();
    }

    /// From MainWindow's scan display update (every poll; unchanged calls
    /// return at once): the scan state, its side, which sides can start one
    /// (Memory mode, SUB shown), and the scanning side's channel.
    public void SetMemoryScan(MemoryScanState? state, bool sub, bool canScanMain, bool canScanSub, int? channel)
    {
        if (state == _memoryScan && sub == _memoryScanSub && canScanMain == _canScanMain && canScanSub == _canScanSub && channel == _scanChannel)
        {
            return;
        }
        _memoryScan = state;
        _memoryScanSub = sub;
        _canScanMain = canScanMain;
        _canScanSub = canScanSub;
        _scanChannel = channel;
        UpdateScanControls();
        UpdateStatus();
    }

    private bool ScanActive => _memoryScan is MemoryScanState.Scanning or MemoryScanState.Paused;

    private void UpdateScanControls()
    {
        var active = ScanActive;
        var picked = _scanSide.SelectedIndex == 1;
        var canStart = _connected && (picked ? _canScanSub : _canScanMain);
        foreach (var control in new Control[] { _scanSide, _scanDownButton, _scanUpButton })
        {
            control.Visibility = active ? Visibility.Collapsed : Visibility.Visible;
        }
        _scanDownButton.IsEnabled = canStart;
        _scanUpButton.IsEnabled = canStart;
        var hint = canStart || !_connected ? "" : $" (put {(picked ? "SUB" : "MAIN")} in Memory mode first)";
        ToolTipService.SetToolTip(_scanDownButton, $"Scan {(picked ? "SUB" : "MAIN")}'s memory channels downward{hint}");
        ToolTipService.SetToolTip(_scanUpButton, $"Scan {(picked ? "SUB" : "MAIN")}'s memory channels upward{hint}");
        _skipButton.Visibility = _memoryScan == MemoryScanState.Paused ? Visibility.Visible : Visibility.Collapsed;
        _stopScanButton.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(_stopScanButton, $"Stop the {(_memoryScanSub ? "SUB" : "MAIN")} memory scan");
    }

    /// Status text for the rig's memory scan; null when it isn't running.
    private string? ScanStatusText()
    {
        var side = _memoryScanSub ? "SUB" : "MAIN";
        return _memoryScan switch
        {
            MemoryScanState.Scanning => $"{side} memory scan running…",
            MemoryScanState.Paused => $"{side} memory scan paused on {(_scanChannel is { } c ? $"CH {c}" : "a busy channel")}",
            _ => null,
        };
    }

    /// From MainWindow's memory display update: the channel each receiver
    /// is on, null when that side isn't in plain Memory mode.
    public void SetCurrentChannels(int? main, int? sub)
    {
        if (main == _mainChannel && sub == _subChannel)
        {
            return;
        }
        var touched = new[] { _mainChannel, _subChannel, main, sub };
        _mainChannel = main;
        _subChannel = sub;
        foreach (var channel in touched)
        {
            if (channel is { } c && _rowButtons.TryGetValue(c, out var buttons))
            {
                StyleButtons(c, buttons);
            }
        }
    }

    private void StyleButtons(int channel, (Button Main, Button Sub) buttons)
    {
        var accent = (Style)Application.Current.Resources["AccentButtonStyle"];
        var plain = (Style)Application.Current.Resources["DefaultButtonStyle"];
        buttons.Main.Style = channel == _mainChannel ? accent : plain;
        buttons.Sub.Style = channel == _subChannel ? accent : plain;
    }

    /// A first scan fills the list a channel at a time; rebuilding every
    /// row for each one would be wasted work, so changes are coalesced.
    private void ScheduleRebuild()
    {
        if (_rebuildScheduled)
        {
            return;
        }
        _rebuildScheduled = true;
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(300);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            _rebuildScheduled = false;
            Rebuild();
        };
        timer.Start();
    }

    private void Rebuild()
    {
        _list.Items.Clear();
        _rowButtons.Clear();
        var query = _search.Text.Trim();
        var shown = _store.Entries.Where(e => Matches(e, query)).ToList();
        foreach (var entry in shown)
        {
            var row = Row(bold: false,
                entry.Channel.ToString(), entry.Tag ?? "", "", FormatHz(entry.FrequencyHz),
                entry.ModeName, entry.ShiftName, entry.ToneName);
            ((TextBlock)row.Children[0]).HorizontalAlignment = HorizontalAlignment.Right;
            ((TextBlock)row.Children[3]).FontFamily = MonoFont;
            ((TextBlock)row.Children[3]).HorizontalAlignment = HorizontalAlignment.Right;

            var buttons = (Main: RecallButton("MAIN", entry.Channel, sub: false), Sub: RecallButton("SUB", entry.Channel, sub: true));
            var buttonPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            buttonPanel.Children.Add(buttons.Main);
            buttonPanel.Children.Add(buttons.Sub);
            Grid.SetColumn(buttonPanel, 2);
            row.Children.Add(buttonPanel);
            StyleButtons(entry.Channel, buttons);
            _rowButtons[entry.Channel] = buttons;
            _list.Items.Add(row);
        }
        _emptyPanel.Visibility = shown.Count == 0 && !_store.IsScanning ? Visibility.Visible : Visibility.Collapsed;
        _emptyHint.Text = _store.Entries.Count > 0
            ? "No channel matches the search."
            : _connected ? "Click Refresh to read the rig's memory channels." : "Connect to the rig, then click Refresh.";
        UpdateStatus();
    }

    private Button RecallButton(string title, int channel, bool sub)
    {
        var button = new Button
        {
            Content = title,
            Width = 58,
            Padding = new Thickness(4, 2, 4, 2),
            FontSize = 12,
            IsEnabled = _connected,
        };
        ToolTipService.SetToolTip(button, $"Recall channel {channel} on {title}");
        button.Click += async (_, _) => await _recall(channel, sub);
        return button;
    }

    private static bool Matches(MemoryChannelEntry entry, string query) =>
        query.Length == 0
        || entry.Channel.ToString() == query
        || (entry.Tag?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)
        || FormatHz(entry.FrequencyHz).Contains(query, StringComparison.Ordinal)
        || entry.ModeName.Contains(query, StringComparison.OrdinalIgnoreCase);

    private void UpdateStatus()
    {
        _refreshButton.Content = _store.IsScanning ? "Stop" : "Refresh";
        _refreshButton.IsEnabled = _store.IsScanning || _connected;
        _statusText.Text = _store.ScanningChannel is { } channel
            ? $"Reading channel {channel}…"
            : ScanStatusText() is { } scanText
                ? scanText
            : _store.ScanError is { } error
                ? error
                : _store.LastScanned is { } scanned
                    ? $"{_store.Entries.Count} channels · read {scanned.ToLocalTime():g}"
                    : "";
        if (!_store.IsScanning && _store.Entries.Count == 0)
        {
            _emptyPanel.Visibility = Visibility.Visible;
        }
    }

    /// The main window's grouping: 431.075.000 (MHz.kHz.Hz).
    private static string FormatHz(long hz) =>
        $"{hz / 1_000_000}.{hz / 1_000 % 1_000:000}.{hz % 1_000:000}";

    private static Grid Row(bool bold, params string[] cells)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        foreach (var width in Columns)
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

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}

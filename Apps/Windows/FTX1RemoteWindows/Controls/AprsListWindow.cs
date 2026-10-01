using System.Globalization;
using System.Runtime.InteropServices;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows.Controls;

public enum AprsListKind
{
    Stations,
    Messages,
}

/// The FM page's APRS S.LIST / M.LIST windows — the Mac's
/// APRSStationListView / APRSMessageListView: a table of decoded stations
/// (newest first) or messages, with an All/Main/Sub source filter. Its own
/// window rather than a dialog, so it can stay open beside the main one
/// while operating, as on the Mac. Built in code, like the MENU grid.
///
/// Rebuilt from the store on each change; APRS brings a few packets a
/// minute at most, so there's nothing to gain from diffing rows. The
/// "Last heard" column is relative ("3 min ago"), its cells re-rendered
/// every 15 s; their tooltip has the local time.
public sealed class AprsListWindow : Window
{
    private readonly AprsListKind _kind;
    private readonly AprsStore _store;
    private readonly Grid _root = new() { Padding = new Thickness(12), RowSpacing = 8 };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly TextBlock _countText = new() { Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray), VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _emptyPanel = new() { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 420 };
    private readonly TextBlock _emptyHint = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray) };
    private readonly DispatcherQueueTimer _relativeTimeTimer;
    private AprsSource? _filter;
    /// Each row's relative-time cell, so the timer re-renders only those.
    private readonly List<(TextBlock Cell, DateTimeOffset At)> _timeCells = [];

    private static readonly FontFamily MonoFont = new("Consolas");

    /// Column widths; the star column (comment / message text) takes the rest.
    private static readonly GridLength[] StationColumns =
        [new(110), new(56), new(140), new(50), new(1, GridUnitType.Star), new(90)];
    private static readonly GridLength[] MessageColumns =
        [new(110), new(110), new(56), new(1, GridUnitType.Star), new(90)];

    public AprsListWindow(AprsListKind kind, AprsStore store)
    {
        _kind = kind;
        _store = store;
        Title = kind == AprsListKind.Stations ? "APRS Stations" : "APRS Messages";
        // AppWindow sizes are physical pixels; scale from DIPs so the columns
        // fit at any display scaling.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)((kind == AprsListKind.Stations ? 960 : 860) * scale), (int)(480 * scale)));

        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var filterBar = new SelectorBar();
        foreach (var (label, tag) in new[] { ("All", ""), ("Main", nameof(AprsSource.Main)), ("Sub", nameof(AprsSource.Sub)) })
        {
            filterBar.Items.Add(new SelectorBarItem { Text = label, Tag = tag, IsSelected = tag.Length == 0 });
        }
        filterBar.SelectionChanged += (bar, _) =>
        {
            _filter = bar.SelectedItem?.Tag is string tag && Enum.TryParse<AprsSource>(tag, out var source) ? source : null;
            Rebuild();
        };
        var toolbar = new Grid();
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.Children.Add(filterBar);
        _countText.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(_countText, 1);
        toolbar.Children.Add(_countText);
        _root.Children.Add(toolbar);

        var header = kind == AprsListKind.Stations
            ? Row(StationColumns, bold: true, "Callsign", "Source", "Position", "Symbol", "Comment", "Last heard")
            : Row(MessageColumns, bold: true, "From", "To", "Source", "Message", "Received");
        // Lines the header up with the ListView items' own inner padding.
        header.Padding = new Thickness(16, 0, 12, 4);
        Grid.SetRow(header, 1);
        _root.Children.Add(header);

        _emptyPanel.Children.Add(new TextBlock
        {
            Text = kind == AprsListKind.Stations ? "No Stations Heard" : "No Messages",
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

        _store.Changed += Rebuild;
        _relativeTimeTimer = DispatcherQueue.CreateTimer();
        _relativeTimeTimer.Interval = TimeSpan.FromSeconds(15);
        _relativeTimeTimer.Tick += (_, _) =>
        {
            var now = DateTimeOffset.Now;
            foreach (var (cell, at) in _timeCells)
            {
                cell.Text = Relative(now, at);
            }
        };
        _relativeTimeTimer.Start();
        Closed += (_, _) =>
        {
            _store.Changed -= Rebuild;
            _relativeTimeTimer.Stop();
        };
        Rebuild();
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        _root.RequestedTheme = AppSettings.Theme.ElementTheme();
        _root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        Rebuild();
    }

    private void Rebuild()
    {
        _list.Items.Clear();
        _timeCells.Clear();
        var now = DateTimeOffset.Now;
        int shown;
        if (_kind == AprsListKind.Stations)
        {
            var stations = _store.Stations
                .Where(s => _filter is null || s.Source == _filter)
                .OrderByDescending(s => s.LastHeardAt)
                .ToList();
            foreach (var s in stations)
            {
                var row = Row(StationColumns, bold: false,
                    s.Callsign,
                    SourceLabel(s.Source),
                    s.Latitude is { } lat && s.Longitude is { } lon
                        ? string.Create(CultureInfo.InvariantCulture, $"{lat:0.0000}, {lon:0.0000}")
                        : "—",
                    (s.SymbolTable ?? "") + (s.SymbolCode ?? ""),
                    s.Comment ?? "",
                    Relative(now, s.LastHeardAt));
                Decorate(row, timeColumn: 5, s.LastHeardAt);
                _list.Items.Add(row);
            }
            shown = stations.Count;
        }
        else
        {
            var messages = _store.Messages
                .Where(m => _filter is null || m.Source == _filter)
                .OrderByDescending(m => m.ReceivedAt)
                .ToList();
            foreach (var m in messages)
            {
                var row = Row(MessageColumns, bold: false,
                    m.From, m.To, SourceLabel(m.Source), m.Text, Relative(now, m.ReceivedAt));
                ((TextBlock)row.Children[1]).FontFamily = MonoFont;
                Decorate(row, timeColumn: 4, m.ReceivedAt);
                _list.Items.Add(row);
            }
            shown = messages.Count;
        }

        var total = _kind == AprsListKind.Stations ? _store.Stations.Count : _store.Messages.Count;
        var noun = _kind == AprsListKind.Stations ? "station" : "message";
        _countText.Text = shown == total
            ? $"{total} {noun}{(total == 1 ? "" : "s")}"
            : $"{shown} of {total} {noun}s";
        _emptyPanel.Visibility = shown == 0 ? Visibility.Visible : Visibility.Collapsed;
        _emptyHint.Text = !AppSettings.AprsEnabled
            ? "APRS decoding is off. Turn it on in Settings → APRS."
            : total > 0
                ? "Nothing from this receiver yet."
                : $"Decoded APRS {noun}s will appear here while a VFO is tuned to {AppSettings.AprsFrequencyHz / 1_000_000.0:0.000###} MHz, with audio on.";
    }

    /// The callsign column in a monospaced font, and the full local time as
    /// the relative-time cell's tooltip.
    private void Decorate(Grid row, int timeColumn, DateTimeOffset at)
    {
        ((TextBlock)row.Children[0]).FontFamily = MonoFont;
        var timeCell = (TextBlock)row.Children[timeColumn];
        ToolTipService.SetToolTip(timeCell, at.ToLocalTime().ToString("G", CultureInfo.CurrentCulture));
        _timeCells.Add((timeCell, at));
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
            else if (cells[i].Length > 0)
            {
                // Trimmed text stays readable on hover.
                ToolTipService.SetToolTip(text, cells[i]);
            }
            Grid.SetColumn(text, i);
            grid.Children.Add(text);
        }
        return grid;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private static string SourceLabel(AprsSource source) => source == AprsSource.Main ? "Main" : "Sub";

    private static string Relative(DateTimeOffset now, DateTimeOffset at)
    {
        var elapsed = now - at;
        return elapsed.TotalSeconds switch
        {
            < 60 => "just now",
            < 3600 => $"{(int)elapsed.TotalMinutes} min ago",
            < 86400 => $"{(int)elapsed.TotalHours} h ago",
            _ => $"{(int)elapsed.TotalDays} d ago",
        };
    }
}

using System.Globalization;
using System.Runtime.InteropServices;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;

namespace FTX1RemoteWindows.Controls;

/// The WebSDR window's Stations window — the Mac's WebSDRStationsView
/// sheet: the public KiwiSDR list (a sortable, searchable table, the Mac's
/// KiwiSDRDirectoryView) and classic WebSDRs (websdr.org itself in a web
/// view, the Mac's WebSDROrgBrowserView — see WebSdrOrgTab for why it
/// isn't a table). Either way, choosing a station only fills the host
/// field; connecting stays a separate, explicit Connect. A window rather
/// than a dialog because the table wants ~950 px.
public sealed class WebSdrStationsWindow : Window
{
    private readonly WebSdrFollowModel _model;
    private readonly KiwiSdrDirectory _directory;
    private readonly Grid _root = new() { Padding = new Thickness(10), RowSpacing = 8 };
    private readonly SelectorBar _tabBar = new();
    private readonly Grid _kiwiTab = new() { RowSpacing = 8 };
    private readonly Grid _webSdrTab = new() { RowSpacing = 8 };
    private bool _webSdrTabBuilt;

    // KiwiSDR tab
    private readonly TextBox _search = new() { PlaceholderText = "Search name, location, grid, antenna", Width = 320 };
    private readonly CheckBox _coversBox = new();
    private readonly CheckBox _hideFullBox = new() { Content = "Hide full" };
    private readonly CheckBox _favoritesOnlyBox = new() { Content = "Favorites only" };
    private readonly TextBlock _gridHint = new()
    {
        Text = "Set your grid square in Settings → Station to sort by distance.",
        FontSize = 12,
        Foreground = new SolidColorBrush(Colors.Gray),
        VerticalAlignment = VerticalAlignment.Center,
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 260,
    };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly Grid _header = new() { ColumnSpacing = 10, Padding = new Thickness(16, 0, 12, 0) };
    private readonly StackPanel _emptyPanel = new() { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460 };
    private readonly TextBlock _emptyTitle = new() { FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock _emptyDetail = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = new SolidColorBrush(Colors.Gray) };
    private readonly ProgressRing _emptyRing = new() { IsActive = false, Width = 32, Height = 32 };
    private readonly TextBlock _summary = new() { FontSize = 12, Foreground = new SolidColorBrush(Colors.Gray) };
    private readonly TextBlock _failure = new() { FontSize = 12, Foreground = new SolidColorBrush(Colors.DarkOrange), Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap };
    private readonly Button _refreshButton = new();
    private readonly ProgressRing _refreshRing = new() { IsActive = false, Width = 16, Height = 16 };
    private readonly Button _useButton = new() { Content = "Use Station", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };

    /// Sort column and direction. Nearest first when the operator's grid
    /// square is set; otherwise every distance is "—", so by name.
    private Column _sortColumn;
    private bool _sortDescending;
    private HashSet<string> _favoriteIds = [];

    private enum Column
    {
        Star,
        Name,
        Location,
        Distance,
        Users,
        Snr,
        Range,
        Antenna,
    }

    private static readonly (Column Column, string Title, GridLength Width)[] Columns =
    [
        (Column.Star, "", new GridLength(28)),
        (Column.Name, "Name", new GridLength(2.4, GridUnitType.Star)),
        (Column.Location, "Location", new GridLength(1.6, GridUnitType.Star)),
        (Column.Distance, "Distance", new GridLength(80)),
        (Column.Users, "Users", new GridLength(56)),
        (Column.Snr, "SNR", new GridLength(56)),
        (Column.Range, "Range", new GridLength(110)),
        (Column.Antenna, "Antenna", new GridLength(1.8, GridUnitType.Star)),
    ];

    /// One table row: the station plus its distance from the operator's
    /// grid square, precomputed so it can be sorted.
    private sealed record Row(KiwiSdrStation Station, double? DistanceKm);

    public WebSdrStationsWindow(WebSdrFollowModel model, KiwiSdrDirectory directory)
    {
        _model = model;
        _directory = directory;
        Title = "WebSDR Stations";
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(1100 * scale), (int)(640 * scale)));
        _sortColumn = Home is null ? Column.Name : Column.Distance;

        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        foreach (var platform in new[] { SdrPlatform.KiwiSdr, SdrPlatform.WebSdr })
        {
            _tabBar.Items.Add(new SelectorBarItem { Text = platform.DisplayName(), Tag = platform, IsSelected = platform == AppSettings.WebSdrStationsTab });
        }
        _tabBar.SelectionChanged += (bar, _) =>
        {
            if (bar.SelectedItem?.Tag is SdrPlatform platform)
            {
                AppSettings.WebSdrStationsTab = platform;
                ShowTab(platform);
            }
        };
        _root.Children.Add(_tabBar);
        Grid.SetRow(_kiwiTab, 1);
        Grid.SetRow(_webSdrTab, 1);
        _root.Children.Add(_kiwiTab);
        _root.Children.Add(_webSdrTab);
        BuildKiwiTab();

        Content = _root;
        ApplyTheme();

        _model.Changed += ModelChanged;
        _directory.Changed += RebuildRows;
        Closed += (_, _) =>
        {
            _model.Changed -= ModelChanged;
            _directory.Changed -= RebuildRows;
            _orgTab?.Dispose();
        };
        ShowTab(AppSettings.WebSdrStationsTab);
        _favoriteIds = _model.Favorites.Select(f => f.Id).ToHashSet();
        UpdateCoversLabel();
        RebuildRows();
        _directory.LoadIfNeeded();
    }

    public void ApplyTheme()
    {
        _root.RequestedTheme = AppSettings.Theme.ElementTheme();
        _root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
    }

    private void ShowTab(SdrPlatform platform)
    {
        _kiwiTab.Visibility = platform == SdrPlatform.KiwiSdr ? Visibility.Visible : Visibility.Collapsed;
        _webSdrTab.Visibility = platform == SdrPlatform.WebSdr ? Visibility.Visible : Visibility.Collapsed;
        if (platform == SdrPlatform.WebSdr && !_webSdrTabBuilt)
        {
            _webSdrTabBuilt = true;
            BuildWebSdrTab();
        }
    }

    private static (double Latitude, double Longitude)? Home => Maidenhead.Coordinates(AppSettings.GridSquare);

    private long? RigFrequencyUsable => _model.RigFrequencyHz is > 0 and var hz ? hz : null;

    private void ModelChanged()
    {
        UpdateCoversLabel();
        var ids = _model.Favorites.Select(f => f.Id).ToHashSet();
        if (!ids.SetEquals(_favoriteIds))
        {
            _favoriteIds = ids;
            if (_favoritesOnlyBox.IsChecked == true)
            {
                RebuildRows();
            }
            else
            {
                RefreshStars();
            }
        }
    }

    private void UpdateCoversLabel()
    {
        var hz = RigFrequencyUsable;
        _coversBox.Content = hz is { } f ? $"Covers {f / 1_000_000.0:0.000} MHz" : "Covers rig frequency";
        _coversBox.IsEnabled = hz is not null;
        ToolTipService.SetToolTip(_coversBox, hz is null
            ? "Available once the rig's frequency is known."
            : "Only stations whose receive range includes the rig's current frequency.");
    }

    // KiwiSDR tab

    private void BuildKiwiTab()
    {
        _kiwiTab.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _kiwiTab.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _kiwiTab.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _kiwiTab.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var filterBar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        _search.TextChanged += (_, _) => RebuildRows();
        filterBar.Children.Add(_search);
        foreach (var box in new[] { _coversBox, _hideFullBox, _favoritesOnlyBox })
        {
            box.Click += (_, _) => RebuildRows();
            filterBar.Children.Add(box);
        }
        filterBar.Children.Add(_gridHint);
        _kiwiTab.Children.Add(filterBar);

        foreach (var width in Columns.Select(c => c.Width))
        {
            _header.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }
        Grid.SetRow(_header, 1);
        _kiwiTab.Children.Add(_header);
        BuildHeader();

        // Rows are filled in ContainerContentChanging rather than by
        // {Binding}, and recycled, so ~900 stations stay quick to filter.
        _list.ItemTemplate = (DataTemplate)XamlReader.Load(
            "<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><Grid ColumnSpacing=\"10\" /></DataTemplate>");
        _list.ContainerContentChanging += List_ContainerContentChanging;
        _list.SelectionChanged += (_, _) => _useButton.IsEnabled = _list.SelectedItem is Row;
        // Double-click chooses too — it still only fills the host field.
        _list.DoubleTapped += (_, _) => ChooseSelected();
        Grid.SetRow(_list, 2);
        _kiwiTab.Children.Add(_list);

        _emptyPanel.Children.Add(_emptyRing);
        _emptyPanel.Children.Add(_emptyTitle);
        _emptyPanel.Children.Add(_emptyDetail);
        Grid.SetRow(_emptyPanel, 2);
        _kiwiTab.Children.Add(_emptyPanel);

        var footer = new Grid { ColumnSpacing = 10 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var leftFooter = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 560 };
        texts.Children.Add(_summary);
        texts.Children.Add(_failure);
        leftFooter.Children.Add(texts);
        _refreshButton.Content = IconText("", "Refresh");
        _refreshButton.Click += (_, _) => _directory.Refresh();
        leftFooter.Children.Add(_refreshButton);
        leftFooter.Children.Add(_refreshRing);
        footer.Children.Add(leftFooter);
        var rightFooter = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var cancel = new Button { Content = "Cancel" };
        cancel.Click += (_, _) => Close();
        rightFooter.Children.Add(cancel);
        _useButton.IsEnabled = false;
        _useButton.Click += (_, _) => ChooseSelected();
        rightFooter.Children.Add(_useButton);
        Grid.SetColumn(rightFooter, 1);
        footer.Children.Add(rightFooter);
        Grid.SetRow(footer, 3);
        _kiwiTab.Children.Add(footer);
    }

    private static StackPanel IconText(string glyph, string text)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        panel.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        panel.Children.Add(new TextBlock { Text = text });
        return panel;
    }

    /// Clickable column headings: click to sort, click again to reverse.
    /// The star column isn't sortable ("Favorites only" covers that).
    private void BuildHeader()
    {
        _header.Children.Clear();
        for (var i = 0; i < Columns.Length; i++)
        {
            var (column, title, _) = Columns[i];
            if (column == Column.Star)
            {
                continue;
            }
            var label = title + (column == _sortColumn ? (_sortDescending ? " ▼" : " ▲") : "");
            var button = new HyperlinkButton
            {
                Content = new TextBlock { Text = label, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                Padding = new Thickness(0),
                Foreground = (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"],
            };
            button.Click += (_, _) =>
            {
                if (_sortColumn == column)
                {
                    _sortDescending = !_sortDescending;
                }
                else
                {
                    _sortColumn = column;
                    _sortDescending = false;
                }
                BuildHeader();
                RebuildRows();
            };
            Grid.SetColumn(button, i);
            _header.Children.Add(button);
        }
    }

    private void RebuildRows()
    {
        var home = Home;
        _gridHint.Visibility = home is null ? Visibility.Visible : Visibility.Collapsed;
        var query = _search.Text.Trim().ToLowerInvariant();
        var filterFrequency = _coversBox.IsChecked == true ? RigFrequencyUsable : null;
        var hideFull = _hideFullBox.IsChecked == true;
        var favoritesOnly = _favoritesOnlyBox.IsChecked == true;
        var rows = _directory.Stations
            .Where(station =>
            {
                if (favoritesOnly && !IsFavorite(station))
                {
                    return false;
                }
                if (hideFull && station.IsFull)
                {
                    return false;
                }
                if (filterFrequency is { } hz && !station.Covers(hz))
                {
                    return false;
                }
                return query.Length == 0
                    || new[] { station.Name, station.Location, station.Grid, station.Antenna, station.HostPort }
                        .Any(s => s.Contains(query, StringComparison.OrdinalIgnoreCase));
            })
            .Select(station => new Row(station,
                home is { } h && station.Latitude is { } lat && station.Longitude is { } lon
                    ? Maidenhead.DistanceKm(h, (lat, lon))
                    : null))
            .ToList();
        rows.Sort(Compare);
        if (_sortDescending)
        {
            rows.Reverse();
        }
        var selectedId = (_list.SelectedItem as Row)?.Station.Id;
        _list.ItemsSource = rows;
        if (selectedId is not null && rows.FirstOrDefault(r => r.Station.Id == selectedId) is { } again)
        {
            _list.SelectedItem = again;
        }
        _useButton.IsEnabled = _list.SelectedItem is Row;
        UpdateEmptyState(rows.Count);
        UpdateFooter(rows.Count);
    }

    private int Compare(Row a, Row b) => _sortColumn switch
    {
        Column.Location => string.Compare(a.Station.Location, b.Station.Location, StringComparison.CurrentCultureIgnoreCase),
        Column.Distance => (a.DistanceKm ?? double.PositiveInfinity).CompareTo(b.DistanceKm ?? double.PositiveInfinity),
        Column.Users => a.Station.Users.CompareTo(b.Station.Users),
        Column.Snr => (a.Station.Snr ?? -1).CompareTo(b.Station.Snr ?? -1),
        Column.Range => a.Station.Bands.Max(r => r.High).CompareTo(b.Station.Bands.Max(r => r.High)),
        Column.Antenna => string.Compare(a.Station.Antenna, b.Station.Antenna, StringComparison.CurrentCultureIgnoreCase),
        _ => string.Compare(a.Station.Name, b.Station.Name, StringComparison.CurrentCultureIgnoreCase),
    };

    private bool IsFavorite(KiwiSdrStation station) => _favoriteIds.Contains(WebSdrFavorite.Key(station.HostPort));

    private void UpdateEmptyState(int rowCount)
    {
        _emptyRing.IsActive = false;
        _emptyRing.Visibility = Visibility.Collapsed;
        if (_directory.Stations.Count == 0)
        {
            _emptyPanel.Visibility = Visibility.Visible;
            if (_directory.State == KiwiSdrDirectory.LoadState.Failed)
            {
                _emptyTitle.Text = "Station List Unavailable";
                _emptyDetail.Text = _directory.FailureMessage ?? "";
            }
            else
            {
                _emptyRing.IsActive = true;
                _emptyRing.Visibility = Visibility.Visible;
                _emptyTitle.Text = "Loading KiwiSDR list…";
                _emptyDetail.Text = "";
            }
        }
        else if (rowCount == 0)
        {
            _emptyPanel.Visibility = Visibility.Visible;
            _emptyTitle.Text = "No Results";
            _emptyDetail.Text = "Check the spelling or try a different search or filter.";
        }
        else
        {
            _emptyPanel.Visibility = Visibility.Collapsed;
        }
    }

    private void UpdateFooter(int rowCount)
    {
        var parts = new List<string> { $"{rowCount} of {_directory.Stations.Count} stations" };
        if (_directory.FetchedAt is { } fetchedAt)
        {
            parts.Add("updated " + Relative(DateTime.Now - fetchedAt));
        }
        parts.Add("list from rx.linkfanel.net");
        _summary.Text = string.Join(" · ", parts);
        var refreshFailed = _directory.State == KiwiSdrDirectory.LoadState.Failed && _directory.Stations.Count > 0;
        _failure.Text = refreshFailed ? _directory.FailureMessage ?? "" : "";
        _failure.Visibility = refreshFailed ? Visibility.Visible : Visibility.Collapsed;
        var loading = _directory.State == KiwiSdrDirectory.LoadState.Loading;
        _refreshButton.IsEnabled = !loading;
        _refreshRing.IsActive = loading && _directory.Stations.Count > 0;
        _refreshRing.Visibility = _refreshRing.IsActive ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string Relative(TimeSpan elapsed) => elapsed.TotalSeconds switch
    {
        < 60 => "just now",
        < 3600 => $"{(int)elapsed.TotalMinutes} min ago",
        < 86400 => $"{(int)elapsed.TotalHours} h ago",
        _ => $"{(int)elapsed.TotalDays} d ago",
    };

    private void List_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.Item is not Row row || args.ItemContainer.ContentTemplateRoot is not Grid grid)
        {
            return;
        }
        if (grid.Children.Count == 0)
        {
            BuildRowCells(grid);
        }
        grid.Tag = row;
        var s = row.Station;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, s.Name);
        UpdateStar(grid);
        SetCell(grid, 1, s.Name);
        SetCell(grid, 2, s.Location);
        SetCell(grid, 3, row.DistanceKm is { } km ? $"{Math.Round(km):0} km" : "—", tooltip: false);
        var users = SetCell(grid, 4, $"{s.Users}/{s.UsersMax}", tooltip: false);
        users.Foreground = s.IsFull ? new SolidColorBrush(Colors.Red) : (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
        SetCell(grid, 5, s.Snr is { } snr ? $"{snr} dB" : "—", tooltip: false);
        SetCell(grid, 6, s.BandsDescription);
        SetCell(grid, 7, s.Antenna);
    }

    private void BuildRowCells(Grid grid)
    {
        foreach (var width in Columns.Select(c => c.Width))
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }
        // Starring doesn't choose the station or close the window.
        var star = new Button
        {
            Content = new FontIcon { FontSize = 14 },
            Padding = new Thickness(4),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        star.Click += (sender, _) =>
        {
            if (((FrameworkElement)sender).Parent is Grid { Tag: Row row })
            {
                _model.ToggleFavorite(row.Station);
            }
        };
        grid.Children.Add(star);
        for (var i = 1; i < Columns.Length; i++)
        {
            var text = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(text, i);
            grid.Children.Add(text);
        }
    }

    private static TextBlock SetCell(Grid grid, int column, string text, bool tooltip = true)
    {
        var cell = (TextBlock)grid.Children[column];
        cell.Text = text;
        ToolTipService.SetToolTip(cell, tooltip && text.Length > 0 ? text : null);
        return cell;
    }

    private void UpdateStar(Grid grid)
    {
        if (grid.Tag is not Row row || grid.Children.Count == 0 || grid.Children[0] is not Button { Content: FontIcon icon } star)
        {
            return;
        }
        var starred = IsFavorite(row.Station);
        icon.Glyph = starred ? "" : "";
        icon.Foreground = new SolidColorBrush(starred ? Colors.Gold : Colors.Gray);
        ToolTipService.SetToolTip(star, starred ? "Remove from Favorites" : "Add to Favorites");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(star, starred ? "Remove from Favorites" : "Add to Favorites");
    }

    /// Favorites changed but the rows didn't: just the realized rows' stars.
    private void RefreshStars()
    {
        if (_list.ItemsPanelRoot is not Panel panel)
        {
            return;
        }
        foreach (var container in panel.Children.OfType<ListViewItem>())
        {
            if (container.ContentTemplateRoot is Grid grid)
            {
                UpdateStar(grid);
            }
        }
    }

    private void ChooseSelected()
    {
        if (_list.SelectedItem is not Row row)
        {
            return;
        }
        _model.Select(row.Station);
        Close();
    }

    // WebSDR tab

    private WebSdrOrgTab? _orgTab;

    private void BuildWebSdrTab()
    {
        _orgTab = new WebSdrOrgTab(url =>
        {
            _model.SelectWebSdr(WebSdrFavorite.HostPortFromUrl(url));
            Close();
        }, Close);
        _webSdrTab.Children.Add(_orgTab.Root);
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}

/// The Stations window's WebSDR tab: websdr.org itself, in a web view — the
/// Mac's WebSDROrgBrowserView.
///
/// **Why the site rather than a native table** (user decision, 2026-09-25):
/// websdr.org's station list comes from a JSON endpoint whose response
/// opens with a notice that the data "may not be re-used in another
/// website or automated system without prior permission" of its maintainer
/// (PA3FWM). So the app never fetches or parses that list — it shows the
/// site, which fetches it for the user like any browser would, with its
/// own map, table and band/region filters.
///
/// Picking: the site sends a station click to the station's URL as a
/// top-level navigation (its table cells set `top.location`, its links use
/// `target="_top"`). Any such navigation off the directory pages is
/// cancelled and handed to `onPick` instead — it only fills the host field
/// (WebSdrFollowModel.SelectWebSdr), never connects. Links meant for a new
/// window, and mailto:, go to the default browser.
internal sealed class WebSdrOrgTab : IDisposable
{
    public static readonly string HomeUrl = "http://websdr.org/";

    public Grid Root { get; } = new() { RowSpacing = 8 };
    private readonly WebView2 _webView = new();
    private readonly StackPanel _errorPanel = new() { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460, Visibility = Visibility.Collapsed };
    private readonly TextBlock _errorText = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = new SolidColorBrush(Colors.Gray) };
    private readonly Action<string> _onPick;
    private CoreWebView2? _core;

    public WebSdrOrgTab(Action<string> onPick, Action onCancel)
    {
        _onPick = onPick;
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var area = new Grid { BorderBrush = new SolidColorBrush(Colors.Gray), BorderThickness = new Thickness(0, 1, 0, 1) };
        area.Children.Add(_webView);
        _errorPanel.Children.Add(new TextBlock { Text = "websdr.org Unavailable", FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        _errorPanel.Children.Add(_errorText);
        area.Children.Add(_errorPanel);
        Root.Children.Add(area);

        var footer = new Grid { ColumnSpacing = 10 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        left.Children.Add(new TextBlock
        {
            Text = "Click a station to use it · list shown by websdr.org",
            FontSize = 12,
            Foreground = new SolidColorBrush(Colors.Gray),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var reload = new Button();
        var reloadContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        reloadContent.Children.Add(new FontIcon { Glyph = "", FontSize = 14 });
        reloadContent.Children.Add(new TextBlock { Text = "Reload" });
        reload.Content = reloadContent;
        reload.Click += (_, _) =>
        {
            ShowError(null);
            _core?.Navigate(HomeUrl);
        };
        left.Children.Add(reload);
        footer.Children.Add(left);
        var cancel = new Button { Content = "Cancel" };
        cancel.Click += (_, _) => onCancel();
        Grid.SetColumn(cancel, 1);
        footer.Children.Add(cancel);
        Grid.SetRow(footer, 1);
        Root.Children.Add(footer);
        _ = InitAsync();
    }

    private async Task InitAsync()
    {
        try
        {
            await _webView.EnsureCoreWebView2Async(await SdrWebViewEnvironment.GetAsync());
        }
        catch (Exception ex)
        {
            ShowError($"The web view couldn't start ({ex.Message}).");
            return;
        }
        _core = _webView.CoreWebView2;
        // Only the main frame raises NavigationStarting (the site's inner
        // frames raise FrameNavigationStarting and load normally), so every
        // navigation seen here is a top-level one.
        _core.NavigationStarting += (_, args) =>
        {
            if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var url))
            {
                return;
            }
            if (url.Scheme == "mailto")
            {
                args.Cancel = true;
                WebSdrWindow.OpenExternally(args.Uri);
                return;
            }
            if ((url.Scheme == Uri.UriSchemeHttp || url.Scheme == Uri.UriSchemeHttps) && !IsDirectoryPage(url))
            {
                args.Cancel = true;
                _onPick(url.AbsoluteUri);
            }
        };
        // target=_blank links: the default browser, not here.
        _core.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            WebSdrWindow.OpenExternally(args.Uri);
        };
        _core.NavigationCompleted += (_, args) =>
        {
            if (args.IsSuccess)
            {
                ShowError(null);
            }
            // A cancelled pick (or a reload superseding a load) isn't a failure.
            else if (args.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
            {
                ShowError($"Couldn't load websdr.org ({args.WebErrorStatus}).");
            }
        };
        _core.Navigate(HomeUrl);
    }

    private void ShowError(string? message)
    {
        _errorText.Text = message ?? "";
        _errorPanel.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
        _webView.Visibility = message is null ? Visibility.Visible : Visibility.Collapsed;
    }

    /// websdr.org is a frameset around websdr.ewi.utwente.nl/org/ (port 80;
    /// the Twente receiver itself is on :8901, which is a station pick).
    public static bool IsDirectoryPage(Uri url)
    {
        var host = url.Host.ToLowerInvariant();
        if (host.Length == 0 || host is "websdr.org" or "www.websdr.org")
        {
            return true;
        }
        return host == "websdr.ewi.utwente.nl" && (url.IsDefaultPort || url.Port == 80);
    }

    public void Dispose() => _webView.Close();
}

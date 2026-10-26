using System.Runtime.InteropServices;
using System.Text.Json;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;

namespace FTX1RemoteWindows.Controls;

/// The APRS map — the Mac's APRSMapView, on OpenStreetMap instead of Apple
/// Maps: the stations in the history that sent a position, blue for Main
/// and orange for Sub, each labelled with its callsign; a click shows its
/// position, symbol, source, last heard and comment. All/Main/Sub filter
/// like the lists. Fits all stations when it opens and on "Fit All", never
/// by itself afterwards, so a new packet doesn't move a map being looked
/// at (as on the Mac).
///
/// The page is Assets/AprsMap/index.html with Leaflet 1.9.4 (BSD-2-Clause,
/// vendored next to it), served from the app folder through a WebView2
/// virtual host; only the tiles come from the network
/// (tile.openstreetmap.org — its usage policy wants an identifying user
/// agent, hence the "FTX1RemoteWindows/<version>" suffix, and the
/// attribution the page shows). Tiles are cached by WebView2's HTTP cache
/// in the shared profile (SdrWebViewEnvironment).
public sealed class AprsMapWindow : Window
{
    /// Never resolves, so the page can't be confused with a real site.
    private const string PageHost = "aprs-map.ftx1remote.example";

    private readonly AprsStore _store;
    private readonly Grid _root = new() { Padding = new Thickness(12), RowSpacing = 8 };
    private readonly WebView2 _webView = new();
    private readonly TextBlock _countText = new() { Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray), VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _fitButton = new() { Content = "Fit All" };
    private readonly StackPanel _emptyPanel = new()
    {
        Spacing = 6,
        Padding = new Thickness(16),
        CornerRadius = new CornerRadius(8),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        MaxWidth = 440,
    };
    private readonly TextBlock _emptyTitle = new()
    {
        FontSize = 18,
        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        HorizontalAlignment = HorizontalAlignment.Center,
    };
    private readonly TextBlock _emptyHint = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray) };
    private CoreWebView2? _core;
    private bool _pageLoaded;
    /// Fit on the first push that has stations in it (the window opening,
    /// or the first position heard while it's open).
    private bool _fitPending = true;
    private AprsSource? _filter;

    public AprsMapWindow(AprsStore store)
    {
        _store = store;
        Title = "APRS Map";
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(900 * scale), (int)(640 * scale)));

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
            Push();
        };
        _fitButton.Click += (_, _) => _core?.PostWebMessageAsJson("""{"type":"fit"}""");
        ToolTipService.SetToolTip(_fitButton, "Zoom to show every station on the map");

        var toolbar = new Grid { ColumnSpacing = 12 };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.Children.Add(filterBar);
        _countText.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(_countText, 1);
        toolbar.Children.Add(_countText);
        Grid.SetColumn(_fitButton, 2);
        toolbar.Children.Add(_fitButton);
        _root.Children.Add(toolbar);

        _emptyPanel.Children.Add(_emptyTitle);
        _emptyPanel.Children.Add(_emptyHint);
        Grid.SetRow(_webView, 1);
        Grid.SetRow(_emptyPanel, 1);
        _root.Children.Add(_webView);
        _root.Children.Add(_emptyPanel);

        Content = _root;
        ApplyTheme();

        _store.Changed += Push;
        Closed += (_, _) =>
        {
            _store.Changed -= Push;
            _webView.Close();
        };
        _ = InitWebViewAsync();
    }

    /// Follows Settings → Appearance, like the main window. The map tiles
    /// themselves stay light.
    public void ApplyTheme()
    {
        ThemeEngine.ApplyTo(_root);
        _root.Background = ThemeEngine.WindowBackground;
        _emptyPanel.Background = (Brush)Application.Current.Resources["LayerFillColorDefaultBrush"];
    }

    private async Task InitWebViewAsync()
    {
        try
        {
            await _webView.EnsureCoreWebView2Async(await SdrWebViewEnvironment.GetAsync());
        }
        catch (Exception ex)
        {
            AppLog.Write($"aprs-map: WebView2 failed to start: {ex.Message}");
            ShowMessage("The map couldn't start", $"The web view couldn't start ({ex.Message}). Installing Microsoft's WebView2 Runtime should fix this.");
            return;
        }
        _core = _webView.CoreWebView2;
        _core.Settings.UserAgent = $"{_core.Settings.UserAgent} FTX1RemoteWindows/{UpdateChecker.CurrentVersionText}";
        _core.Settings.AreDevToolsEnabled = false;
        _core.Settings.AreDefaultContextMenusEnabled = false;
        _core.SetVirtualHostNameToFolderMapping(PageHost,
            Path.Combine(AppContext.BaseDirectory, "Assets", "AprsMap"),
            CoreWebView2HostResourceAccessKind.DenyCors);
        // The attribution's OpenStreetMap link (and any other) opens in the
        // default browser; the map page itself never navigates.
        _core.NavigationStarting += (_, args) =>
        {
            if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var url) && url.Host != PageHost)
            {
                args.Cancel = true;
                WebSdrWindow.OpenExternally(args.Uri);
            }
        };
        _core.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            WebSdrWindow.OpenExternally(args.Uri);
        };
        _core.NavigationCompleted += (_, args) =>
        {
            if (args.IsSuccess)
            {
                _pageLoaded = true;
                Push();
            }
            else if (args.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
            {
                AppLog.Write($"aprs-map: page failed to load: {args.WebErrorStatus}");
                ShowMessage("The map couldn't load", $"The map page failed to load ({args.WebErrorStatus}).");
            }
        };
        _core.Navigate($"https://{PageHost}/index.html");
    }

    /// Sends the plotted stations to the page (all of them, each time —
    /// a few packets a minute at most) and updates the count and the
    /// empty-state note.
    private void Push()
    {
        var all = _store.Stations.Where(s => s.Latitude is not null && s.Longitude is not null).ToList();
        var shown = all.Where(s => _filter is null || s.Source == _filter).ToList();

        _countText.Text = shown.Count == all.Count
            ? $"{all.Count} station{(all.Count == 1 ? "" : "s")} with a position"
            : $"{shown.Count} of {all.Count} stations with a position";
        _fitButton.IsEnabled = shown.Count > 0;
        if (shown.Count == 0)
        {
            ShowMessage(
                all.Count == 0 ? "No Positions Heard" : "Nothing From This Receiver",
                !AppSettings.AprsEnabled
                    ? "APRS decoding is off. Turn it on in Settings → APRS."
                    : all.Count > 0
                        ? "No position reports from this receiver yet."
                        : $"Decoded APRS position reports will appear here while a VFO is tuned to {AppSettings.AprsFrequencyHz / 1_000_000.0:0.000###} MHz, with audio on.");
        }
        else
        {
            _emptyPanel.Visibility = Visibility.Collapsed;
        }

        if (_core is null || !_pageLoaded)
        {
            return;
        }
        var fit = _fitPending && shown.Count > 0;
        if (fit)
        {
            _fitPending = false;
        }
        var message = new
        {
            type = "stations",
            fit,
            stations = shown.Select(s => new
            {
                call = s.Callsign,
                lat = s.Latitude!.Value,
                lon = s.Longitude!.Value,
                source = s.Source.ToString(),
                symbol = (s.SymbolTable ?? "") + (s.SymbolCode ?? ""),
                comment = s.Comment ?? "",
                heard = s.LastHeardAt.ToString("o"),
            }),
        };
        _core.PostWebMessageAsJson(JsonSerializer.Serialize(message));
    }

    private void ShowMessage(string title, string hint)
    {
        _emptyTitle.Text = title;
        _emptyHint.Text = hint;
        _emptyPanel.Visibility = Visibility.Visible;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}

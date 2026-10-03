using System.Diagnostics;
using System.Runtime.InteropServices;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;

namespace FTX1RemoteWindows.Controls;

/// The WebSDR window — the Mac's WebSDRFollowView + KiwiWebView: an
/// embedded KiwiSDR, classic WebSDR or OpenWebRX (WebView2) that retunes to follow the
/// rig's Main VFO and, with "Tune rig", tunes the rig when the user tunes
/// in the page. All the logic is in Services/WebSdrFollowModel.cs; this is
/// the toolbar, the web view and the status line. Its own window rather
/// than a dialog, so it stays open beside the main one; built in code,
/// like the APRS lists.
///
/// Always opens disconnected (public Kiwis have few listener slots), and
/// closing it ends the session. A close while recording first saves the
/// file (the web view, and the page's recorder with it, die with the
/// window), then closes.
public sealed class WebSdrWindow : Window
{
    public WebSdrFollowModel Model { get; }

    /// The WebView2 browser process, whose process tree plays the page's
    /// audio (the CW window's WebSDR source captures it); null until the web
    /// view has started. UI thread.
    public uint? BrowserProcessId
    {
        get
        {
            try
            {
                return _core?.BrowserProcessId;
            }
            catch (Exception)
            {
                // The browser process went away under us.
                return null;
            }
        }
    }

    /// Owned here (not per Stations window) so reopening it shows the
    /// already-loaded list; its disk cache outlives the window anyway.
    private readonly KiwiSdrDirectory _directory = new();
    private WebSdrStationsWindow? _stationsWindow;

    private readonly Grid _root = new();
    private readonly WebView2 _webView = new();
    private CoreWebView2? _core;
    /// The page request the web view was last told to load (the Mac's
    /// KiwiWebView.Coordinator.loaded).
    private WebSdrFollowModel.PageRequest? _loaded;
    private bool _webViewFailed;

    private readonly TextBox _hostBox = new()
    {
        PlaceholderText = "KiwiSDR, WebSDR or OpenWebRX host:port",
        FontFamily = new FontFamily("Consolas"),
        MinWidth = 160,
        VerticalAlignment = VerticalAlignment.Center,
    };
    /// The model's host as last mirrored into the box, so a pick replaces
    /// the box's text but the model's own echo of a commit doesn't.
    private string? _mirroredHost;
    private readonly Button _starButton = new() { Padding = new Thickness(8, 5, 8, 6) };
    private readonly FontIcon _starIcon = new() { FontSize = 16 };
    private readonly DropDownButton _favoritesButton = new();
    private readonly MenuFlyout _favoritesMenu = new() { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Bottom };
    private readonly Button _connectButton = new();
    private readonly CheckBox _followBox = new() { Content = "Follow rig" };
    private readonly CheckBox _tuneBox = new() { Content = "Tune rig" };
    private readonly CheckBox _muteOnTxBox = new() { Content = "Mute on TX" };
    private readonly Button _muteButton = new();
    private readonly Button _recordButton = new();
    private readonly TextBlock _statusText = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _noteText = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460 };
    private readonly StackPanel _notConnectedPanel = new() { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 440 };
    private readonly TextBlock _notConnectedHint = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
    private readonly DispatcherQueueTimer _elapsedTimer;
    private bool _suppressToggles;
    private bool _closingAfterSave;
    private bool _manageOpen;

    public WebSdrWindow(WebSdrRigLink rig)
    {
        Model = new WebSdrFollowModel(rig);
        Title = "WebSDR";
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        // Wide enough for the one-row toolbar with the host box at full
        // width, but never wider than the screen (the host box shrinks).
        var workArea = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Min((int)(1480 * scale), workArea.Width), Math.Min((int)(760 * scale), workArea.Height)));

        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.Children.Add(BuildToolbar());

        var pageArea = new Grid
        {
            BorderBrush = new SolidColorBrush(Colors.Gray),
            BorderThickness = new Thickness(0, 1, 0, 1),
        };
        Grid.SetRow(pageArea, 1);
        pageArea.Children.Add(_webView);
        _notConnectedPanel.Children.Add(new FontIcon { Glyph = "", FontSize = 36, Foreground = new SolidColorBrush(Colors.Gray) });
        _notConnectedPanel.Children.Add(new TextBlock
        {
            Text = "Not Connected",
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        _notConnectedHint.Foreground = new SolidColorBrush(Colors.Gray);
        _notConnectedPanel.Children.Add(_notConnectedHint);
        pageArea.Children.Add(_notConnectedPanel);
        _root.Children.Add(pageArea);

        var statusBar = new Grid { Padding = new Thickness(10, 5, 10, 6), ColumnSpacing = 12 };
        statusBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        statusBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _statusText.FontSize = 12;
        _noteText.FontSize = 12;
        _statusText.Foreground = new SolidColorBrush(Colors.Gray);
        _noteText.Foreground = new SolidColorBrush(Colors.Gray);
        statusBar.Children.Add(_statusText);
        Grid.SetColumn(_noteText, 1);
        statusBar.Children.Add(_noteText);
        Grid.SetRow(statusBar, 2);
        _root.Children.Add(statusBar);

        _elapsedTimer = DispatcherQueue.CreateTimer();
        _elapsedTimer.Interval = TimeSpan.FromSeconds(1);
        _elapsedTimer.Tick += (_, _) => UpdateRecordButton();

        Content = _root;
        ApplyTheme();

        Model.Changed += Refresh;
        _directory.Changed += DirectoryChanged;
        AppWindow.Closing += async (_, args) =>
        {
            if (!Model.IsRecording || _closingAfterSave)
            {
                return;
            }
            args.Cancel = true;
            _closingAfterSave = true;
            await Model.Disconnect();
            Close();
        };
        Closed += (_, _) =>
        {
            Model.Changed -= Refresh;
            _directory.Changed -= DirectoryChanged;
            _elapsedTimer.Stop();
            // Ends the session (and lifts the WebSDR's mute of Main); the
            // web view itself goes with the window.
            if (Model.IsConnected)
            {
                _ = Model.Disconnect();
            }
            _stationsWindow?.Close();
            _webView.Close();
        };

        Refresh();
        _ = InitWebViewAsync();
    }

    private IReadOnlyList<Models.KiwiSdrStation>? _lastDirectoryStations;

    /// The Mac's `.onChange(of: directory.stations)`: favorites saved from a
    /// typed host get the directory's name/location/ranges once it loads.
    private void DirectoryChanged()
    {
        if (!ReferenceEquals(_directory.Stations, _lastDirectoryStations))
        {
            _lastDirectoryStations = _directory.Stations;
            Model.FillInFavorites(_directory.Stations);
        }
    }

    private FrameworkElement BuildToolbar()
    {
        // One row: Stations, Favorites, host, star, Connect, the three
        // toggles, then (right-aligned) Mute, Record, Recordings. The host
        // box's column is the one that gives when the window is narrow.
        var bar = new Grid { Padding = new Thickness(10), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = 300 });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var stationsButton = new Button();
        SetContent(stationsButton, "", "Stations…");
        ToolTipService.SetToolTip(stationsButton, "Choose a public KiwiSDR or WebSDR");
        stationsButton.Click += (_, _) => ShowStations();
        left.Children.Add(stationsButton);

        // Picks a saved station (fills the host, never connects — same as a
        // directory pick). Still openable when empty, so the hint shows.
        SetContent(_favoritesButton, "", "Favorites");
        _favoritesButton.Flyout = _favoritesMenu;
        ToolTipService.SetToolTip(_favoritesButton, "Choose a saved station");
        _favoritesMenu.Opening += (_, _) => BuildFavoritesMenu();
        left.Children.Add(_favoritesButton);

        // Return and Connect both commit, so an edited-but-uncommitted host
        // is never silently ignored by Connect.
        _hostBox.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                CommitHostAndConnect();
            }
        };
        _hostBox.TextChanged += (_, _) => Refresh();
        AutomationPropertiesName(_hostBox, "WebSDR host");
        Grid.SetColumn(_hostBox, 1);
        bar.Children.Add(_hostBox);
        bar.Children.Add(left);

        var middle = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };

        _starButton.Content = _starIcon;
        _starButton.Click += (_, _) => Model.ToggleFavoriteForCurrentHost(_directory.Stations);
        middle.Children.Add(_starButton);

        _connectButton.Click += (_, _) =>
        {
            if (Model.IsConnected)
            {
                _ = Model.Disconnect();
            }
            else
            {
                CommitHostAndConnect();
            }
        };
        middle.Children.Add(_connectButton);

        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _muteButton.Click += (_, _) => Model.ToggleMuted();
        right.Children.Add(_muteButton);
        _recordButton.Click += (_, _) => Model.ToggleRecording();
        right.Children.Add(_recordButton);
        // The CW page's PLAY is still a placeholder here, so there's no
        // Recordings window yet (the Mac's Play opens one): this opens the
        // folder the WebSDR recordings go to.
        var recordingsButton = new Button();
        SetContent(recordingsButton, "", "Recordings");
        ToolTipService.SetToolTip(recordingsButton, "Open the Recordings folder");
        recordingsButton.Click += (_, _) => OpenRecordingsFolder();
        right.Children.Add(recordingsButton);
        Grid.SetColumn(right, 4);
        bar.Children.Add(right);

        var toggles = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(8, 0, 0, 0) };
        ToolTipService.SetToolTip(_followBox, "Retune the WebSDR when the rig's Main VFO changes");
        ToolTipService.SetToolTip(_tuneBox, "Tune the rig's Main VFO when you tune in the WebSDR page (click the waterfall, enter a frequency, pick a mode)");
        ToolTipService.SetToolTip(_muteOnTxBox, "Mute the WebSDR while the rig is transmitting");
        _followBox.Click += (_, _) => { if (!_suppressToggles) { Model.FollowRig = _followBox.IsChecked == true; } };
        _tuneBox.Click += (_, _) => { if (!_suppressToggles) { Model.TuneRig = _tuneBox.IsChecked == true; } };
        _muteOnTxBox.Click += (_, _) => { if (!_suppressToggles) { Model.MuteOnTransmit = _muteOnTxBox.IsChecked == true; } };
        foreach (var box in new[] { _followBox, _tuneBox, _muteOnTxBox })
        {
            // CheckBox's default MinWidth (120) would spread them out.
            box.MinWidth = 0;
            box.VerticalAlignment = VerticalAlignment.Center;
            toggles.Children.Add(box);
        }
        middle.Children.Add(toggles);
        Grid.SetColumn(middle, 2);
        bar.Children.Add(middle);
        return bar;
    }

    private static void AutomationPropertiesName(DependencyObject element, string name) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);

    /// An icon + label as a button's content, with the label as its
    /// accessible name (a StackPanel content gives the button none).
    private static void SetContent(ContentControl button, string glyph, string text, Brush? foreground = null)
    {
        button.Content = IconLabel(glyph, text, foreground);
        AutomationPropertiesName(button, text);
    }

    private static StackPanel IconLabel(string glyph, string text, Brush? foreground = null)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var icon = new FontIcon { Glyph = glyph, FontSize = 14 };
        var label = new TextBlock { Text = text };
        if (foreground is not null)
        {
            icon.Foreground = foreground;
            label.Foreground = foreground;
        }
        panel.Children.Add(icon);
        panel.Children.Add(label);
        return panel;
    }

    private void CommitHostAndConnect()
    {
        var host = _hostBox.Text.Trim();
        _hostBox.Text = host;
        _mirroredHost = host;
        Model.HostPort = host;
        Model.Connect();
    }

    private void BuildFavoritesMenu()
    {
        _favoritesMenu.Items.Clear();
        if (Model.Favorites.Count == 0)
        {
            _favoritesMenu.Items.Add(new MenuFlyoutItem { Text = "No favorites yet — star a station", IsEnabled = false });
        }
        else
        {
            var currentKey = Models.WebSdrFavorite.Key(Model.HostPort);
            foreach (var favorite in Model.Favorites)
            {
                // Unchecking does nothing but re-pick the same station.
                var item = new ToggleMenuFlyoutItem { Text = favorite.Name, IsChecked = favorite.Id == currentKey };
                item.Click += (_, _) => Model.Select(favorite);
                _favoritesMenu.Items.Add(item);
            }
        }
        _favoritesMenu.Items.Add(new MenuFlyoutSeparator());
        var manage = new MenuFlyoutItem { Text = "Manage Favorites…", IsEnabled = Model.Favorites.Count > 0 };
        manage.Click += async (_, _) => await ShowManageFavoritesAsync();
        _favoritesMenu.Items.Add(manage);
    }

    private async Task ShowManageFavoritesAsync()
    {
        if (_manageOpen || Content.XamlRoot is null)
        {
            return;
        }
        _manageOpen = true;
        try
        {
            await new WebSdrFavoritesDialog(Content.XamlRoot, _root.ActualTheme, Model).ShowAsync();
        }
        finally
        {
            _manageOpen = false;
        }
    }

    private void ShowStations()
    {
        if (_stationsWindow is null)
        {
            _stationsWindow = new WebSdrStationsWindow(Model, _directory);
            _stationsWindow.Closed += (_, _) => _stationsWindow = null;
        }
        _stationsWindow.Activate();
    }

    private static void OpenRecordingsFolder()
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Recordings.Directory}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            AppLog.Write($"websdr: couldn't open the Recordings folder: {ex.Message}");
        }
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        _root.RequestedTheme = AppSettings.Theme.ElementTheme();
        _root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        _stationsWindow?.ApplyTheme();
        UpdateMuteButton();
        UpdateRecordButton();
    }

    // Web view

    private async Task InitWebViewAsync()
    {
        try
        {
            var environment = await SdrWebViewEnvironment.GetAsync();
            await _webView.EnsureCoreWebView2Async(environment);
        }
        catch (Exception ex)
        {
            // Most likely no WebView2 Runtime (it ships with Windows 11 and
            // current Windows 10, but can be missing on an old install).
            AppLog.Write($"websdr: WebView2 failed to start: {ex.Message}");
            _webViewFailed = true;
            _notConnectedHint.Text = $"The web view couldn't start ({ex.Message}). Installing Microsoft's WebView2 Runtime should fix this.";
            Refresh();
            return;
        }
        _core = _webView.CoreWebView2;
        Model.Bridge.WebView = _core;
        _core.NavigationCompleted += Core_NavigationCompleted;
        _core.DownloadStarting += (_, args) => Model.Bridge.OnDownloadStarting(args);
        // Each recording's save is a script-made download, and Chromium holds
        // a page's second one behind a "download multiple files?" prompt that
        // WebView2 never shows — so without this only the first recording of
        // a page session was saved (a retune's split timed out). Every other
        // permission keeps WebView2's default.
        _core.PermissionRequested += (_, args) =>
        {
            if (args.PermissionKind == CoreWebView2PermissionKind.MultipleAutomaticDownloads)
            {
                args.State = CoreWebView2PermissionState.Allow;
            }
        };
        // target=_blank links in the page (a Kiwi's info links etc.) go to
        // the default browser rather than a bare WebView2 popup.
        // The OpenWebRX recorder's tap posts its audio blocks here (see
        // SdrPageBridge.ReceiveTapAudio); the bridge ignores anything else.
        _core.WebMessageReceived += (_, args) => Model.Bridge.ReceiveTapAudio(args.WebMessageAsJson);
        _core.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            OpenExternally(args.Uri);
        };
        ApplyPage();
    }

    internal static void OpenExternally(string uri)
    {
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var parsed)
            || parsed.Scheme is not ("http" or "https" or "mailto"))
        {
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo(parsed.AbsoluteUri) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            AppLog.Write($"websdr: couldn't open {parsed.AbsoluteUri}: {ex.Message}");
        }
    }

    /// Loads whenever the model's page request changes — for a Kiwi,
    /// retuning is a plain load of a new `?f=` URL (a full page reload and
    /// reconnect). A classic WebSDR is loaded once per connection and then
    /// retuned in place, so its request doesn't change. A null request
    /// navigates to about:blank: unloading the page is what makes it close
    /// its WebSocket (stopping alone doesn't touch a loaded page).
    private void ApplyPage()
    {
        if (_core is null || Model.Page == _loaded)
        {
            return;
        }
        _loaded = Model.Page;
        if (_loaded is { } page)
        {
            _core.Navigate(page.Url);
        }
        else
        {
            _core.Stop();
            _core.Navigate("about:blank");
        }
    }

    private void Core_NavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (!args.IsSuccess)
        {
            // A retune superseding a still-loading page cancels it — that's
            // expected, not a failure worth surfacing.
            if (args.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled)
            {
                return;
            }
            Model.ReportLoadFailure(args.HttpStatusCode >= 400 ? $"HTTP {args.HttpStatusCode}" : Describe(args.WebErrorStatus));
            return;
        }
        if (sender.Source.StartsWith("about:", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        Model.PageDidLoad();
    }

    private static string Describe(CoreWebView2WebErrorStatus status) => status switch
    {
        CoreWebView2WebErrorStatus.HostNameNotResolved => "host not found",
        CoreWebView2WebErrorStatus.CannotConnect or CoreWebView2WebErrorStatus.ConnectionAborted
            or CoreWebView2WebErrorStatus.ConnectionReset or CoreWebView2WebErrorStatus.Disconnected => "couldn't connect",
        CoreWebView2WebErrorStatus.Timeout => "timed out",
        _ => status.ToString(),
    };

    // State → UI

    private void Refresh()
    {
        if (Model.HostPort != _mirroredHost)
        {
            // A pick (or startup) sets the committed host; mirror it into the box.
            _mirroredHost = Model.HostPort;
            _hostBox.Text = Model.HostPort;
        }
        var draft = _hostBox.Text.Trim();
        var committed = draft == Model.HostPort;

        var isFavorite = Model.IsFavorite(Model.HostPort);
        _starIcon.Glyph = isFavorite ? "" : "";
        _starIcon.Foreground = isFavorite ? new SolidColorBrush(Colors.Gold) : new SolidColorBrush(Colors.Gray);
        _starButton.IsEnabled = Model.HostPort.Length > 0 && committed;
        ToolTipService.SetToolTip(_starButton, isFavorite ? "Remove this station from Favorites"
            : !committed ? "Press Enter to use this host, then add it to Favorites"
            : "Add this station to Favorites");
        AutomationPropertiesName(_starButton, isFavorite ? "Remove from Favorites" : "Add to Favorites");

        if (Model.IsConnected)
        {
            SetContent(_connectButton, "", "Disconnect");
        }
        else
        {
            SetContent(_connectButton, "", "Connect");
        }
        _connectButton.IsEnabled = Model.IsConnected || (Models.KiwiSdrUrlBuilder.BaseUrl(draft) is not null && !_webViewFailed);

        _suppressToggles = true;
        _followBox.IsChecked = Model.FollowRig;
        _tuneBox.IsChecked = Model.TuneRig;
        _muteOnTxBox.IsChecked = Model.MuteOnTransmit;
        _suppressToggles = false;

        UpdateMuteButton();
        UpdateRecordButton();

        // Hidden rather than removed while disconnected: it has to stay
        // alive to unload the page (and save a recording) on disconnect.
        _webView.Visibility = Model.IsConnected ? Visibility.Visible : Visibility.Collapsed;
        _notConnectedPanel.Visibility = Model.IsConnected ? Visibility.Collapsed : Visibility.Visible;
        if (!_webViewFailed)
        {
            _notConnectedHint.Text = "Pick a station or enter a KiwiSDR, WebSDR or OpenWebRX host:port, then press Connect.";
        }

        _statusText.Text = Model.Status;
        ToolTipService.SetToolTip(_statusText, Model.Status.Length > 0 ? Model.Status : null);
        _noteText.Text = Model.RecordingNote ?? "";
        ApplyPage();
    }

    /// Mutes the receiver page. While it's audible (connected, not muted
    /// here) the rig's Main audio is muted; muting here brings Main back.
    /// Usable while disconnected too, to pick how the next connection starts.
    private void UpdateMuteButton()
    {
        if (Model.IsMuted)
        {
            SetContent(_muteButton, "", "Muted", new SolidColorBrush(Colors.Red));
        }
        else
        {
            SetContent(_muteButton, "", "Mute");
        }
        ToolTipService.SetToolTip(_muteButton, Model.IsMuted
            ? "Unmute the WebSDR (mutes the rig's Main audio while connected)"
            : "Mute the WebSDR and bring back the rig's Main audio");
    }

    /// Record while connected; Stop (red, with the current file's elapsed
    /// time) while recording. The time is blank between files — saving,
    /// reloading after a retune, or waiting for the page's audio.
    private void UpdateRecordButton()
    {
        if (Model.IsRecording)
        {
            var elapsed = Model.SegmentStartedAt is { } started
                ? " " + (DateTime.Now - started).ToString(@"m\:ss")
                : "";
            _recordButton.Content = IconLabel("", "Stop" + elapsed, new SolidColorBrush(Colors.Red));
            AutomationPropertiesName(_recordButton, "Stop recording");
            _recordButton.IsEnabled = true;
            ToolTipService.SetToolTip(_recordButton, "Stop recording and save to Recordings");
            if (!_elapsedTimer.IsRunning)
            {
                _elapsedTimer.Start();
            }
        }
        else
        {
            SetContent(_recordButton, "", "Record");
            _recordButton.IsEnabled = Model.IsConnected;
            ToolTipService.SetToolTip(_recordButton, Model.IsConnected ? "Record the WebSDR's audio" : "Connect to a station to record");
            _elapsedTimer.Stop();
        }
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}

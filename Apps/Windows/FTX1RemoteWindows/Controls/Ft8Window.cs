using System.Globalization;
using System.Runtime.InteropServices;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Ft8;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace FTX1RemoteWindows.Controls;

/// Tools → FT8 / FT4 — the Mac's FT8ListView: a table of the decoded messages
/// (newest first), the source picker (MAIN, SUB or the MyKiwiSDR window's
/// audio), and the PSK Reporter upload checkbox. One window per mode, each with
/// its own <see cref="Ft8Store"/>; both can be open and decoding at once.
///
/// Decoding is tied to the window's lifetime (MainWindow starts it when the
/// window opens and stops it on close, see MainWindow.Ft8.cs). Built in code,
/// like the CW and RTTY/PSK windows.
public sealed class Ft8Window : Window
{
    /// Rows shown; the store keeps up to 2,000.
    private const int MaxRows = 1_000;

    private static readonly GridLength[] Columns =
        [new(90), new(90), new(100), new(50), new(50), new(1, GridUnitType.Star), new(110), new(60)];

    private static readonly FontFamily MonoFont = new("Consolas");

    private readonly Ft8Store _store;
    private readonly PskReporterUploader _uploader;
    private readonly LocalSdrAudioSource _localSdr;
    private readonly Func<bool?> _singleReceive;
    private readonly Func<string?> _webSdrNote;
    private readonly Grid _root = new() { Padding = new Thickness(12), RowSpacing = 8 };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly StackPanel _emptyPanel = new() { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460 };
    private readonly TextBlock _statusText = new() { FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _lastCycleText = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _nextText = new() { FontFamily = MonoFont, VerticalAlignment = VerticalAlignment.Center };
    private readonly SelectorBar _sourceBar = new();
    private readonly Dictionary<CwAudioChannel, SelectorBarItem> _sourceItems = [];
    private readonly TextBlock _sourceNote = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly CheckBox _uploadBox = new() { MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _uploadStatus = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly HyperlinkButton _mapLink = new();
    private readonly DispatcherQueueTimer _tickTimer;
    private bool _syncing;

    public Ft8Window(Ft8Store store, PskReporterUploader uploader, LocalSdrAudioSource localSdr, Func<bool?> singleReceive, Func<string?> webSdrNote)
    {
        _store = store;
        _uploader = uploader;
        _localSdr = localSdr;
        _singleReceive = singleReceive;
        _webSdrNote = webSdrNote;
        var modeName = store.Mode.Name();
        Title = modeName;
        // AppWindow sizes are physical pixels; scale from DIPs.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(980 * scale), (int)(560 * scale)));

        for (var i = 0; i < 6; i++)
        {
            _root.RowDefinitions.Add(new RowDefinition { Height = i == 4 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        }

        // Status line: cycle state, last cycle, countdown.
        var status = new Grid { ColumnSpacing = 16 };
        status.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        status.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        status.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        status.Children.Add(_statusText);
        _lastCycleText.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(_lastCycleText, 1);
        status.Children.Add(_lastCycleText);
        Grid.SetColumn(_nextText, 2);
        status.Children.Add(_nextText);
        AddRow(status, 0);

        // Source row.
        foreach (var channel in Ft8Store.OfferedChannels)
        {
            var item = new SelectorBarItem
            {
                Text = SourceTitle(channel),
                Tag = channel,
                IsSelected = channel == _store.Channel,
            };
            _sourceItems[channel] = item;
            _sourceBar.Items.Add(item);
        }
        ToolTipService.SetToolTip(_sourceBar, Loc.F("ft8List.whichAudio", modeName));
        _sourceBar.SelectionChanged += (bar, _) =>
        {
            if (!_syncing && bar.SelectedItem?.Tag is CwAudioChannel channel)
            {
                _store.Channel = channel;
            }
        };
        var sourceRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        sourceRow.Children.Add(_sourceBar);
        sourceRow.Children.Add(_sourceNote);
        AddRow(sourceRow, 1);

        // PSK Reporter row.
        _uploadBox.Content = Loc.S("ft8List.uploadToPskReporter");
        _uploadBox.Checked += (_, _) => SetUpload(true);
        _uploadBox.Unchecked += (_, _) => SetUpload(false);
        _mapLink.Content = Loc.S("ft8List.viewOnPskReporter");
        _mapLink.HorizontalAlignment = HorizontalAlignment.Right;
        var pskRow = new Grid { ColumnSpacing = 12 };
        pskRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        pskRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pskRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        pskRow.Children.Add(_uploadBox);
        Grid.SetColumn(_uploadStatus, 1);
        pskRow.Children.Add(_uploadStatus);
        Grid.SetColumn(_mapLink, 2);
        pskRow.Children.Add(_mapLink);
        AddRow(pskRow, 2);

        // Table.
        var header = Row(bold: true, Loc.S("ft8List.time"), Loc.S("ft8List.source"), Loc.S("ft8List.freqMHz"), "SNR", "DT",
            Loc.S("common.message"), Loc.S("aprsListWindow.callsign"), Loc.S("ft8List.grid"));
        header.Padding = new Thickness(16, 0, 12, 4);
        AddRow(header, 3);

        _emptyPanel.Children.Add(new TextBlock
        {
            Text = Loc.S("ft8List.noDecodesYet"),
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        _emptyPanel.Children.Add(new TextBlock
        {
            Text = Loc.F("ft8List.decodedMessagesWill", modeName, modeName),
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
        });
        Grid.SetRow(_list, 4);
        Grid.SetRow(_emptyPanel, 4);
        _root.Children.Add(_list);
        _root.Children.Add(_emptyPanel);

        Content = _root;
        ApplyTheme();

        _store.Changed += Refresh;
        _store.SpotsRecorded += OnSpotsRecorded;
        _store.Cleared += RebuildRows;
        _uploader.Changed += Refresh;
        _localSdr.Changed += Refresh;

        _tickTimer = DispatcherQueue.CreateTimer();
        _tickTimer.Interval = TimeSpan.FromSeconds(1);
        _tickTimer.Tick += (_, _) => Tick();
        _tickTimer.Start();

        Closed += (_, _) =>
        {
            _tickTimer.Stop();
            _store.Changed -= Refresh;
            _store.SpotsRecorded -= OnSpotsRecorded;
            _store.Cleared -= RebuildRows;
            _uploader.Changed -= Refresh;
            _localSdr.Changed -= Refresh;
        };

        RebuildRows();
        Refresh();
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        ThemeEngine.ApplyTo(_root);
        _root.Background = ThemeEngine.WindowBackground;
    }

    private void AddRow(UIElement element, int row)
    {
        Grid.SetRow((FrameworkElement)element, row);
        _root.Children.Add(element);
    }

    private void SetUpload(bool on)
    {
        if (!_syncing)
        {
            _uploader.IsEnabled = on;
        }
    }

    private static readonly Brush Gray = new SolidColorBrush(Microsoft.UI.Colors.Gray);

    /// Everything but the table rows.
    private void Refresh()
    {
        _syncing = true;
        try
        {
            RefreshStatus();
            RefreshSource();
            RefreshUpload();
        }
        finally
        {
            _syncing = false;
        }
        _emptyPanel.Visibility = _store.Spots.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RefreshStatus()
    {
        (_statusText.Text, _statusText.Foreground) = _store.CycleStatus switch
        {
            Ft8CycleStatus.Accumulating => (Loc.S("ft8List.receiving"), new SolidColorBrush(Color.FromArgb(255, 70, 130, 220))),
            Ft8CycleStatus.Decoding => (Loc.S("ft8List.decoding"), new SolidColorBrush(Color.FromArgb(255, 235, 140, 30))),
            _ => (Loc.S("ft8List.idle"), Gray),
        };
        _lastCycleText.Text = _store.LastCycleCompletedAt is { } at ? Loc.F("ft8List.lastCycle", at.ToLocalTime().ToString("T")) : "";
        _lastCycleText.Foreground = Gray;
        _nextText.Foreground = Gray;
        Tick();
    }

    /// The countdown, rounded up so FT4's 7.5 s slot counts 8…1 rather than 0.
    private void Tick()
    {
        var slot = _store.Mode.SlotSeconds();
        var phase = (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0) % slot;
        _nextText.Text = Loc.F("ft8List.nextInS", (int)Math.Ceiling(slot - phase));
        // The source note depends on SUB's audio, the rig's display mode and the Kiwi.
        _store.RefreshSubAudio();
        RefreshSourceNote();
    }

    private string? SubUnavailableReason()
    {
        if (!_store.IsSubAudioAvailable)
        {
            return Loc.S("cwWindow.noSUBAudioThe");
        }
        return _singleReceive() == true ? Loc.S("cwWindow.sUBIsOffThe") : null;
    }

    private void RefreshSource()
    {
        foreach (var (channel, item) in _sourceItems)
        {
            item.IsSelected = channel == _store.Channel;
        }
        RefreshSourceNote();
    }

    private void RefreshSourceNote()
    {
        // MyKiwiSDR is offered only while Settings → Devices has it enabled;
        // if it gets disabled while selected, fall back to MAIN.
        var kiwiOffered = AppSettings.LocalSdr.IsEnabled;
        if (!kiwiOffered && _store.Channel == CwAudioChannel.MyKiwiSdr)
        {
            _store.Channel = CwAudioChannel.Main;
        }
        _sourceItems[CwAudioChannel.MyKiwiSdr].Visibility = kiwiOffered ? Visibility.Visible : Visibility.Collapsed;
        _sourceItems[CwAudioChannel.Sub].IsEnabled = SubUnavailableReason() is null || _store.Channel == CwAudioChannel.Sub;
        string? note = null;
        switch (_store.Channel)
        {
            case CwAudioChannel.Sub:
                note = SubUnavailableReason();
                break;
            case CwAudioChannel.WebSdr:
                note = _webSdrNote();
                break;
            case CwAudioChannel.MyKiwiSdr:
                note = _localSdr.Status switch
                {
                    LocalSdrAudioSource.SourceStatus.NotConnected => Loc.S("cwWindow.myKiwiSDRNotConnected"),
                    LocalSdrAudioSource.SourceStatus.Silent => Loc.S("cwWindow.myKiwiSDRSilent"),
                    _ => _localSdr.Mode is { } mode && mode != RigMode.Usb
                        ? Loc.F("ft8List.kiwiNeedsUSB", mode.DisplayName(), _store.Mode.Name())
                        : null,
                };
                break;
        }
        _sourceNote.Text = note ?? "";
        _sourceNote.Foreground = Gray;
    }

    private void RefreshUpload()
    {
        var stationSet = PskReporterUploader.StationIsSet;
        _uploadBox.IsEnabled = stationSet;
        _uploadBox.IsChecked = _uploader.IsEnabled;
        _uploadStatus.Foreground = Gray;
        if (!stationSet)
        {
            _uploadStatus.Text = Loc.S("ft8List.setYourCallsignAnd");
        }
        else if (_uploader.LastError is { } error)
        {
            _uploadStatus.Text = Loc.F("ft8List.uploadFailed", error);
            _uploadStatus.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Red);
        }
        else if (_uploader.IsEnabled)
        {
            var text = Loc.F("ft8List.pskQueuedSent", _uploader.PendingCount, _uploader.SentThisSession);
            if (_uploader.LastUploadAt is { } last)
            {
                text = Loc.F("ft8List.pskWithLastUpload", text, last.ToLocalTime().ToString("t"));
            }
            if (_uploader.NextUploadAt is { } next)
            {
                text = Loc.F("ft8List.pskWithNextUpload", text, next.ToLocalTime().ToString("t"));
            }
            _uploadStatus.Text = text;
        }
        else
        {
            _uploadStatus.Text = "";
        }
        var call = AppSettings.Callsign.Trim().ToUpperInvariant();
        _mapLink.Visibility = stationSet ? Visibility.Visible : Visibility.Collapsed;
        if (stationSet)
        {
            _mapLink.NavigateUri = new Uri("https://pskreporter.info/pskmap.html?callsign=" + Uri.EscapeDataString(call));
        }
    }

    // Table rows

    /// A decode cycle's spots go in at the top, newest first, as one block.
    private void OnSpotsRecorded(IReadOnlyList<Ft8Spot> spots)
    {
        for (var i = 0; i < spots.Count; i++)
        {
            _list.Items.Insert(i, SpotRow(spots[i]));
        }
        while (_list.Items.Count > MaxRows)
        {
            _list.Items.RemoveAt(_list.Items.Count - 1);
        }
    }

    private void RebuildRows()
    {
        _list.Items.Clear();
        foreach (var spot in _store.Spots.Reverse().Take(MaxRows))
        {
            _list.Items.Add(SpotRow(spot));
        }
    }

    private static Grid SpotRow(Ft8Spot spot)
    {
        var row = Row(bold: false,
            spot.UtcTimestamp.ToLocalTime().ToString("T"),
            SourceTitle(spot.Channel),
            (spot.AbsoluteFrequencyHz / 1e6).ToString("0.0000", CultureInfo.InvariantCulture),
            spot.SnrDb > 0 ? $"+{spot.SnrDb}" : spot.SnrDb.ToString(CultureInfo.InvariantCulture),
            spot.DtSeconds.ToString("+0.0;-0.0;+0.0", CultureInfo.InvariantCulture),
            spot.MessageText,
            spot.SpottedCallsign ?? "",
            spot.SpottedGrid ?? "");
        foreach (var column in new[] { 2, 5 })
        {
            ((TextBlock)row.Children[column]).FontFamily = MonoFont;
        }
        return row;
    }

    private static string SourceTitle(CwAudioChannel channel) =>
        channel switch { CwAudioChannel.MyKiwiSdr => "MyKiwiSDR", CwAudioChannel.WebSdr => "WebSDR", _ => channel.ToString().ToUpperInvariant() };

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
                IsTextSelectionEnabled = !bold,
            };
            if (bold)
            {
                text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            }
            else if (cells[i].Length > 0)
            {
                ToolTipService.SetToolTip(text, cells[i]);
            }
            Grid.SetColumn(text, i);
            grid.Children.Add(text);
        }
        return grid;
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}

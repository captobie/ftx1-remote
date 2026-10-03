using System.Runtime.InteropServices;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.ApplicationModel.DataTransfer;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace FTX1RemoteWindows.Controls;

/// The CW window — the Mac's Tools → CW (CWWindowView.swift): the receive
/// pane on top (MAIN/SUB + Open Audio File / Copy / Clear header, the
/// signal status bar, the decoded text, and the tuning row: auto-tune,
/// tone, Rig Pitch, squelch), the send pane below (<see cref="CwSendPane"/>).
/// Neural or classic decoder (picker next to MAIN/SUB); the neural one's
/// newest, not-yet-final text is shown dimmed after the committed text.
/// Callsigns in the decoded text are links that fill the send pane's Their
/// call (the Mac's CWCallsigns).
///
/// Decodes only while open, like the Mac's; the text itself lives in
/// <see cref="CwReceiver"/> and the send queue in <see cref="CwSender"/>
/// (both owned by MainWindow), so they outlive the window: a queued line
/// still goes out after it closes. Built in code, like the other windows.
public sealed class CwWindow : Window
{
    private readonly CwReceiver _receiver;
    private readonly CwWindowLink _link;
    private readonly CwSendPane _sendPane;

    private readonly Grid _root = new();
    private readonly Grid _receivePane = new();
    private readonly SelectorBar _channelBar = new();
    private readonly SelectorBarItem _mainItem = new() { Text = "MAIN", Tag = CwAudioChannel.Main };
    private readonly SelectorBarItem _subItem = new() { Text = "SUB", Tag = CwAudioChannel.Sub };
    private readonly SelectorBarItem _webSdrItem = new() { Text = "WebSDR", Tag = CwAudioChannel.WebSdr };
    private readonly SelectorBar _decoderBar = new();
    private readonly SelectorBarItem _neuralItem = new() { Text = "Neural", Tag = CwDecoderKind.Neural };
    private readonly SelectorBarItem _classicItem = new() { Text = "Classic", Tag = CwDecoderKind.Classic };
    private readonly StackPanel _squelchPanel = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly Button _openButton = new();
    private readonly Button _copyButton = new();
    private readonly Button _clearButton = new();

    private readonly Ellipse _keyLed = new() { Width = 12, Height = 12 };
    private readonly ProgressBar _levelMeter = new() { Width = 120, Minimum = 0, Maximum = 1, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _pendingText = new() { FontFamily = MonoFont, FontSize = 20, MinWidth = 110, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _fileRing = new() { Width = 16, Height = 16, IsActive = false };
    private readonly TextBlock _noteText = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _toneReadout = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _snrReadout = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _wpmReadout = new() { VerticalAlignment = VerticalAlignment.Center };

    private readonly ScrollViewer _textScroller = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(16, 12, 16, 12) };
    private readonly TextBlock _decodedText = new() { FontFamily = MonoFont, FontSize = 20, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private readonly TextBlock _placeholder = new()
    {
        Text = "Decoded CW from the selected receiver appears here. Tune to a CW signal, or open a recording.",
        FontSize = 20,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(16, 12, 16, 12),
    };

    private readonly CheckBox _autoTuneBox = new() { Content = "Auto-tune", MinWidth = 0 };
    private readonly Slider _toneSlider = new()
    {
        Minimum = FrequencyTracker.SearchMin,
        Maximum = FrequencyTracker.SearchMax,
        StepFrequency = 10,
        Width = 220,
        VerticalAlignment = VerticalAlignment.Center,
        IsThumbToolTipEnabled = false,
    };
    private readonly TextBlock _toneValue = new() { Width = 64, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _rigPitchButton = new() { Content = "Rig Pitch" };
    private readonly Slider _squelchSlider = new()
    {
        Minimum = 3,
        Maximum = 30,
        StepFrequency = 1,
        Width = 160,
        VerticalAlignment = VerticalAlignment.Center,
        IsThumbToolTipEnabled = false,
    };
    private readonly TextBlock _squelchValue = new() { Width = 44, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };

    private readonly DispatcherQueueTimer _meterTimer;
    /// Set while code (not the user) moves a control, so its change
    /// handler doesn't write the value straight back.
    private bool _updating;
    private string _shownText = "";
    private string _shownTentative = "";
    /// How much of _shownText is rendered as final inlines: up to its last
    /// space or newline, so a callsign still being received can't be split.
    /// The rest is the tail, re-rendered on every change.
    private int _stableLength;
    private int _tailInlineCount;
    private CwMeters? _shownMeters;

    private static readonly FontFamily MonoFont = new("Consolas");

    public CwWindow(CwReceiver receiver, CwSender sender, CwWindowLink link)
    {
        _receiver = receiver;
        _link = link;
        Title = "CW";
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(860 * scale), (int)(860 * scale)));

        _receivePane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _receivePane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _receivePane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _receivePane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        AddRow(BuildHeader(), 0, withDivider: true);
        AddRow(BuildStatusBar(), 1, withDivider: true);
        _textScroller.Content = _decodedText;
        var textHost = new Grid();
        textHost.Children.Add(_textScroller);
        textHost.Children.Add(_placeholder);
        AddRow(textHost, 2, withDivider: false);
        AddRow(BuildTuningRow(), 3, withDivider: false, dividerAbove: true);

        // Receive above send, like the Mac's VSplitView (no splitter in
        // WinUI 3 without the Community Toolkit, so fixed proportions).
        _sendPane = new CwSendPane(sender, link);
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1.1, GridUnitType.Star), MinHeight = 240 });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 230 });
        _root.Children.Add(_receivePane);
        Grid.SetRow(_sendPane, 1);
        _root.Children.Add(_sendPane);
        _root.Children.Add(new Rectangle
        {
            Height = 2,
            Fill = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
            VerticalAlignment = VerticalAlignment.Bottom,
        });

        Content = _root;
        ApplyTheme();

        _receiver.Changed += Refresh;
        _receiver.Error += ShowError;
        _meterTimer = DispatcherQueue.CreateTimer();
        // Fast enough for the key LED to follow 30 WPM dits.
        _meterTimer.Interval = TimeSpan.FromMilliseconds(30);
        _meterTimer.Tick += (_, _) => UpdateMeters();
        _meterTimer.Start();
        _receiver.Start();
        Closed += (_, _) =>
        {
            _meterTimer.Stop();
            _receiver.Changed -= Refresh;
            _receiver.Error -= ShowError;
            _receiver.Stop();
        };
        Refresh();
        UpdateMeters();
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        _root.RequestedTheme = AppSettings.Theme.ElementTheme();
        _root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        _textScroller.Background = (Brush)Application.Current.Resources["TextControlBackground"];
        _placeholder.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        _noteText.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        foreach (var readout in new[] { _toneReadout, _snrReadout, _wpmReadout })
        {
            readout.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        }
        _sendPane.ApplyTheme();
        _shownMeters = null;
        UpdateMeters();
    }

    private void AddRow(FrameworkElement element, int row, bool withDivider, bool dividerAbove = false)
    {
        Grid.SetRow(element, row);
        _receivePane.Children.Add(element);
        if (withDivider || dividerAbove)
        {
            var divider = new Rectangle
            {
                Height = 1,
                Fill = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
                VerticalAlignment = dividerAbove ? VerticalAlignment.Top : VerticalAlignment.Bottom,
            };
            Grid.SetRow(divider, row);
            _receivePane.Children.Add(divider);
        }
    }

    private Grid BuildHeader()
    {
        var header = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _channelBar.Items.Add(_mainItem);
        _channelBar.Items.Add(_subItem);
        _channelBar.Items.Add(_webSdrItem);
        ToolTipService.SetToolTip(_webSdrItem, "Decode what the WebSDR window is playing");
        _channelBar.SelectionChanged += (bar, _) =>
        {
            if (_updating || bar.SelectedItem?.Tag is not CwAudioChannel channel)
            {
                return;
            }
            _receiver.Channel = channel;
        };
        ToolTipService.SetToolTip(_mainItem, "Decode the rig's MAIN receiver");

        _decoderBar.Items.Add(_neuralItem);
        _decoderBar.Items.Add(_classicItem);
        _decoderBar.SelectionChanged += (bar, _) =>
        {
            // The bar shows the decoder actually running, so selecting it in
            // code (Refresh) raises this too, after _updating is cleared; only
            // a change from that is the user's. Without the check, a fallback
            // to Classic would overwrite the saved Neural preference.
            if (_updating || bar.SelectedItem?.Tag is not CwDecoderKind kind || kind == _receiver.EffectiveDecoder)
            {
                return;
            }
            _receiver.Decoder = kind;
        };
        var pickers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        pickers.Children.Add(_channelBar);
        pickers.Children.Add(_decoderBar);
        header.Children.Add(pickers);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        SetContent(_openButton, "", "Open Audio File…");
        ToolTipService.SetToolTip(_openButton, "Decode a recording (the Recordings folder opens first)");
        _openButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.O, Modifiers = VirtualKeyModifiers.Control });
        _openButton.Click += async (_, _) => await OpenFileAsync();
        SetContent(_copyButton, "", "Copy");
        ToolTipService.SetToolTip(_copyButton, "Copy the decoded text");
        _copyButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.C, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift });
        _copyButton.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(_receiver.DecodedText);
            Clipboard.SetContent(package);
        };
        SetContent(_clearButton, "", "Clear");
        ToolTipService.SetToolTip(_clearButton, "Clear the decoded text");
        _clearButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.K, Modifiers = VirtualKeyModifiers.Control });
        _clearButton.Click += (_, _) => _receiver.ClearText();
        buttons.Children.Add(_openButton);
        buttons.Children.Add(_copyButton);
        buttons.Children.Add(_clearButton);
        Grid.SetColumn(buttons, 2);
        header.Children.Add(buttons);
        return header;
    }

    private Grid BuildStatusBar()
    {
        var bar = new Grid { Padding = new Thickness(16, 8, 16, 8), ColumnSpacing = 14 };
        for (var i = 0; i < 8; i++)
        {
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = i == 4 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        }
        ToolTipService.SetToolTip(_keyLed, "Key down");
        ToolTipService.SetToolTip(_levelMeter, "Tone level between the noise floor and the signal peak");
        ToolTipService.SetToolTip(_pendingText, "Elements of the character being received (Classic decoder)");
        _keyLed.VerticalAlignment = VerticalAlignment.Center;
        var note = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
        note.Children.Add(_fileRing);
        note.Children.Add(_noteText);
        foreach (var (element, column) in new (FrameworkElement, int)[]
                 {
                     (_keyLed, 0), (_levelMeter, 1), (_pendingText, 2), (note, 4),
                     (_toneReadout, 5), (_snrReadout, 6), (_wpmReadout, 7),
                 })
        {
            Grid.SetColumn(element, column);
            bar.Children.Add(element);
        }
        return bar;
    }

    private StackPanel BuildTuningRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 24, Padding = new Thickness(16, 8, 16, 8) };

        ToolTipService.SetToolTip(_autoTuneBox,
            $"Follow the strongest tone between {FrequencyTracker.SearchMin:0} and {FrequencyTracker.SearchMax:0} Hz");
        _autoTuneBox.Checked += (_, _) => { if (!_updating) _receiver.AutoTune = true; };
        _autoTuneBox.Unchecked += (_, _) => { if (!_updating) _receiver.AutoTune = false; };
        row.Children.Add(_autoTuneBox);

        var tone = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        tone.Children.Add(Label("Tone"));
        _toneSlider.ValueChanged += (_, e) =>
        {
            if (!_updating && !_receiver.AutoTune)
            {
                _receiver.ToneFrequency = e.NewValue;
            }
        };
        tone.Children.Add(_toneSlider);
        tone.Children.Add(_toneValue);
        _rigPitchButton.Click += (_, _) => _receiver.UseRigPitch();
        tone.Children.Add(_rigPitchButton);
        row.Children.Add(tone);

        var squelch = _squelchPanel;
        squelch.Children.Add(Label("Squelch"));
        _squelchSlider.ValueChanged += (_, e) =>
        {
            if (!_updating)
            {
                _receiver.SquelchDb = e.NewValue;
            }
        };
        squelch.Children.Add(_squelchSlider);
        squelch.Children.Add(_squelchValue);
        row.Children.Add(squelch);
        return row;
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

    /// Text, settings and notes — on every receiver change.
    private void Refresh()
    {
        _updating = true;
        try
        {
            var text = _receiver.DecodedText;
            var tentative = _receiver.TentativeText;
            if (text != _shownText || tentative != _shownTentative)
            {
                // Keep following the newest text only if the reader is
                // already at the bottom, so scrolling back to read isn't
                // yanked away by the next character.
                var atBottom = _textScroller.VerticalOffset >= _textScroller.ScrollableHeight - 4;
                RenderText(text, tentative);
                if (atBottom)
                {
                    _textScroller.UpdateLayout();
                    _textScroller.ChangeView(null, _textScroller.ScrollableHeight, null, disableAnimation: true);
                }
            }
            _placeholder.Visibility = text.Length == 0 && tentative.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            _copyButton.IsEnabled = _clearButton.IsEnabled = text.Length > 0;
            _openButton.IsEnabled = !_receiver.IsDecodingFile;

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

            var decoder = _receiver.EffectiveDecoder == CwDecoderKind.Neural ? _neuralItem : _classicItem;
            if (!decoder.IsSelected)
            {
                decoder.IsSelected = true;
            }
            var unavailable = _receiver.NeuralUnavailableReason;
            _decoderBar.IsEnabled = unavailable is null;
            ToolTipService.SetToolTip(_decoderBar, unavailable
                ?? "Neural: a model trained on simulated CW, best on weak and noisy signals; text runs about 3½ s behind. Classic: tone threshold and timing rules.");
            var neural = _receiver.EffectiveDecoder == CwDecoderKind.Neural;
            _squelchPanel.Opacity = neural ? 0.5 : 1;
            _squelchSlider.IsEnabled = !neural;
            ToolTipService.SetToolTip(_squelchPanel, neural
                ? "The neural decoder doesn't need a squelch: it stays silent on noise"
                : "Minimum signal-to-noise ratio needed before anything is decoded");

            _autoTuneBox.IsChecked = _receiver.AutoTune;
            _toneSlider.IsEnabled = !_receiver.AutoTune;
            if (!_receiver.AutoTune)
            {
                _toneSlider.Value = _receiver.ToneFrequency;
                _toneValue.Text = $"{_receiver.ToneFrequency:0} Hz";
            }
            _rigPitchButton.IsEnabled = _receiver.RigPitchHz is not null;
            ToolTipService.SetToolTip(_rigPitchButton, _receiver.RigPitchHz is { } pitch
                ? $"Turn off auto-tune and use the rig's CW pitch, {pitch} Hz — where a zero-beat signal sounds"
                : "The rig's CW pitch hasn't been read yet (it's read in CW mode, or with the MENU grid's CW page open)");
            _squelchSlider.Value = _receiver.SquelchDb;
            _squelchValue.Text = $"{_receiver.SquelchDb:0} dB";
        }
        finally
        {
            _updating = false;
        }
        UpdateNote();
        UpdateSubAvailability();
    }

    /// Renders the decoded text with its callsigns as links, then the
    /// tentative text dimmed (not linked: it can still change). Appended
    /// text (the usual case) only re-renders from the last word break on; a
    /// cleared or trimmed text renders from scratch.
    private void RenderText(string text, string tentative)
    {
        var inlines = _decodedText.Inlines;
        if (_shownText.Length == 0 || !text.StartsWith(_shownText, StringComparison.Ordinal))
        {
            inlines.Clear();
            _stableLength = 0;
            _tailInlineCount = 0;
        }
        for (var i = 0; i < _tailInlineCount; i++)
        {
            inlines.RemoveAt(inlines.Count - 1);
        }
        var breakAt = text.LastIndexOfAny([' ', '\n']) + 1;
        if (breakAt > _stableLength)
        {
            AppendInlines(text[_stableLength..breakAt]);
            _stableLength = breakAt;
        }
        var before = inlines.Count;
        AppendInlines(text[_stableLength..]);
        if (tentative.Length > 0)
        {
            inlines.Add(new Run { Text = tentative, Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"] });
        }
        _tailInlineCount = inlines.Count - before;
        _shownText = text;
        _shownTentative = tentative;
    }

    private void AppendInlines(string segment)
    {
        if (segment.Length == 0)
        {
            return;
        }
        var inlines = _decodedText.Inlines;
        var position = 0;
        foreach (var (start, length) in CwCallsigns.Find(segment, AppSettings.Callsign))
        {
            if (start > position)
            {
                inlines.Add(new Run { Text = segment[position..start] });
            }
            var call = segment.Substring(start, length);
            var link = new Hyperlink { UnderlineStyle = UnderlineStyle.Single };
            link.Inlines.Add(new Run { Text = call });
            ToolTipService.SetToolTip(link, $"Use {call} as Their call");
            link.Click += (_, _) => _sendPane.FillTheirCall(call);
            inlines.Add(link);
            position = start + length;
        }
        if (position < segment.Length)
        {
            inlines.Add(new Run { Text = segment[position..] });
        }
    }

    /// Why the decoder isn't decoding normally, when it isn't (the Mac's
    /// sourceNote), or the file-decoding indicator.
    private void UpdateNote()
    {
        _fileRing.IsActive = _receiver.IsDecodingFile;
        _fileRing.Visibility = _receiver.IsDecodingFile ? Visibility.Visible : Visibility.Collapsed;
        string? note;
        if (_receiver.IsDecodingFile)
        {
            note = "Decoding file…";
        }
        else if (_receiver.IsPausedForTransmit)
        {
            note = "Paused while transmitting";
        }
        else if (_receiver.Channel == CwAudioChannel.WebSdr)
        {
            note = WebSdrNote();
        }
        else if (_receiver.SourceModeIfNotCw is { } mode)
        {
            note = $"{(_receiver.Channel == CwAudioChannel.Main ? "MAIN" : "SUB")} is in {mode.DisplayName()}, not CW — decoding anyway";
        }
        else
        {
            note = null;
        }
        _noteText.Text = note ?? "";
        ToolTipService.SetToolTip(_noteText, note);
    }

    /// Why the WebSDR source isn't decoding, when it isn't. Windows can't
    /// capture a muted WebSDR (see WebSdrAudioTap), so a muted window is
    /// called out before the generic "silent".
    private string? WebSdrNote()
    {
        if (_receiver.WebSdr is not { } webSdr)
        {
            return "Open the WebSDR window (WebSDR button) and connect it to decode what it plays";
        }
        if (!webSdr.Connected)
        {
            return "Connect the WebSDR window to decode what it plays";
        }
        return _receiver.WebSdrPhase switch
        {
            WebSdrTapPhase.Failed => $"Can't capture the WebSDR's audio: {_receiver.WebSdrFailure}",
            // Only once the capture has gone quiet: a page the window's Mute
            // doesn't reach would still be decoding.
            WebSdrTapPhase.Silent when webSdr.Muted => "The WebSDR is muted — unmute it to decode (Windows can't capture it while muted)",
            WebSdrTapPhase.Silent => "The WebSDR is silent — check that its page is playing",
            WebSdrTapPhase.WaitingForWebSdr => "Waiting for the WebSDR window's audio",
            _ => null,
        };
    }

    /// SUB is unselectable with no Sub audio (mono input) or in
    /// single-receive display, as on the Mac. A selection already on SUB is
    /// left alone, as the Mac's picker does.
    private void UpdateSubAvailability()
    {
        string? reason = !_receiver.IsSubAudioAvailable
            ? "No SUB audio: the audio is off, or the input is mono"
            : _link.SingleReceive() == true
                ? "SUB is off: the rig is in single-receive display"
                : null;
        var enabled = reason is null || _receiver.Channel == CwAudioChannel.Sub;
        if (_subItem.IsEnabled != enabled)
        {
            _subItem.IsEnabled = enabled;
        }
        ToolTipService.SetToolTip(_subItem, reason ?? "Decode the rig's SUB receiver");
    }

    private void UpdateMeters()
    {
        var meters = _receiver.Meters;
        if (!ReferenceEquals(meters, _shownMeters))
        {
            _shownMeters = meters;
            _keyLed.Fill = meters.KeyDown
                ? new SolidColorBrush(Microsoft.UI.Colors.LimeGreen)
                : new SolidColorBrush(Windows.UI.Color.FromArgb(64, 128, 128, 128));
            _levelMeter.Value = Math.Clamp(meters.SignalLevel, 0, 1);
            _pendingText.Text = new string(meters.PendingSymbols.Select(c => c == '.' ? '·' : '–').ToArray());
            _toneReadout.Text = $"{Math.Round(meters.ToneFrequency):0} Hz";
            _snrReadout.Text = $"SNR {Math.Round(meters.SnrDb):0} dB";
            _wpmReadout.Text = meters.Wpm > 0 ? $"{Math.Round(meters.Wpm):0} WPM" : "– WPM";
            if (_receiver.AutoTune)
            {
                // The slider shows the tone being followed.
                _updating = true;
                _toneSlider.Value = Math.Clamp(meters.ToneFrequency, _toneSlider.Minimum, _toneSlider.Maximum);
                _toneValue.Text = $"{Math.Round(meters.ToneFrequency):0} Hz";
                _updating = false;
            }
        }
        // Cheap, and the poll's rig changes don't all raise Changed.
        UpdateSubAvailability();
    }

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
            Title = "CW",
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


using System.Globalization;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows.Controls;

/// The MyKiwiSDR window — the Mac's LocalSDRWindowView: native audio and a
/// waterfall from the operator's own KiwiSDR (not the embedded page the WebSDR
/// window shows). All the logic is in Services/LocalSdrModel.cs; this is the
/// waterfall, the connection and tuning rows, the meter, the rig-link toggles,
/// the Receiver section and the status line. Its own window rather than a
/// dialog, so it stays open beside the main one; built in code, like the
/// WebSDR window. The address and password are in Settings → Devices.
///
/// Always opens disconnected, and closing it ends the session.
public sealed class LocalSdrWindow : Window
{
    public LocalSdrModel Model { get; }

    private static readonly int[] Steps = [100, 1_000, 5_000];

    private readonly Grid _root = new() { RowSpacing = 10, Padding = new Thickness(14) };
    private readonly KiwiWaterfallView _waterfall;
    private readonly TextBlock _zoomSpanText = new() { FontFamily = new FontFamily("Consolas"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _passbandText = new() { FontFamily = new FontFamily("Consolas"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
    private readonly Button _zoomOutButton = new();
    private readonly Button _zoomInButton = new();
    private readonly Button _resetPassbandButton = new();
    private readonly TextBlock _hostText = new() { FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 300 };
    private readonly Button _connectButton = new();
    private readonly TextBlock _frequencyText = new() { FontFamily = new FontFamily("Consolas"), FontSize = 26, VerticalAlignment = VerticalAlignment.Center, MinWidth = 190, TextAlignment = TextAlignment.Right };
    private readonly TextBox _frequencyBox = new() { Width = 120, FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center, PlaceholderText = "kHz" };
    private readonly List<(KiwiSdrMode Mode, ToggleButton Button)> _modeButtons = [];
    private readonly ProgressBar _meterBar = new() { Minimum = -130, Maximum = -20, Width = 260, Height = 8, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _meterText = new() { FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center, MinWidth = 150 };
    private readonly TextBlock _overloadText = new() { Foreground = new SolidColorBrush(Colors.OrangeRed), VerticalAlignment = VerticalAlignment.Center };
    private readonly Slider _volumeSlider = new() { Minimum = 0, Maximum = 1, StepFrequency = 0.01, Width = 140, VerticalAlignment = VerticalAlignment.Center };
    private readonly ToggleButton _muteButton = new();
    private readonly ToggleSwitch _followSwitch = new() { OnContent = Loc.S("localSdr.followRig"), OffContent = Loc.S("localSdr.followRig"), MinWidth = 0 };
    private readonly ToggleSwitch _followWidthSwitch = new() { OnContent = Loc.S("localSdr.followRigWidth"), OffContent = Loc.S("localSdr.followRigWidth"), MinWidth = 0 };
    private readonly ToggleSwitch _tuneSwitch = new() { OnContent = Loc.S("localSdr.tuneRig"), OffContent = Loc.S("localSdr.tuneRig"), MinWidth = 0 };
    private readonly ToggleSwitch _muteTxSwitch = new() { OnContent = Loc.S("localSdr.muteOnTx"), OffContent = Loc.S("localSdr.muteOnTx"), MinWidth = 0 };
    private readonly TextBlock _rigLinkText = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _statusText = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private readonly Expander _receiverExpander = new() { Header = Loc.S("localSdr.receiver"), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
    private readonly StackPanel _receiverPanel = new() { Spacing = 8 };

    private readonly Button _recordButton = new();
    private readonly DispatcherQueueTimer _elapsedTimer;

    /// The toolbar's Play button; MainWindow owns the Recordings window.
    public event Action? RecordingsRequested;

    private bool _suppress;
    private bool _frequencyFocused;

    public LocalSdrWindow(LocalSdrRigLink rig)
    {
        Model = new LocalSdrModel(rig);
        Title = Loc.S("app.myKiwiSDR");
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var workArea = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Min((int)(1000 * scale), workArea.Width), Math.Min((int)(820 * scale), workArea.Height)));

        _waterfall = new KiwiWaterfallView(Model) { MinHeight = 240 };
        for (var i = 0; i < 8; i++)
        {
            _root.RowDefinitions.Add(new RowDefinition { Height = i == 0 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        }
        AddRow(0, _waterfall);
        AddRow(1, BuildZoomRow());
        AddRow(2, BuildConnectionRow());
        AddRow(3, BuildTuningRow());
        AddRow(4, BuildMeterRow());
        AddRow(5, BuildRigLinkRow());
        BuildReceiverSection();
        AddRow(6, _receiverExpander);
        _statusText.Foreground = new SolidColorBrush(Colors.Gray);
        AddRow(7, _statusText);

        _elapsedTimer = DispatcherQueue.CreateTimer();
        _elapsedTimer.Interval = TimeSpan.FromSeconds(1);
        _elapsedTimer.Tick += (_, _) => UpdateRecordButton();

        Content = _root;
        ApplyTheme();
        Model.Changed += Refresh;
        Model.MeterChanged += RefreshMeter;
        Closed += (_, _) =>
        {
            Model.Changed -= Refresh;
            Model.MeterChanged -= RefreshMeter;
            _elapsedTimer.Stop();
            // Ends the session (and lifts the mute of the rig's Main audio).
            Model.Disconnect();
        };
        Refresh();
        RefreshMeter();
    }

    private void AddRow(int row, FrameworkElement element)
    {
        Grid.SetRow(element, row);
        _root.Children.Add(element);
    }

    /// Follows Settings → Appearance, like the main window.
    public void ApplyTheme()
    {
        ThemeEngine.ApplyTo(_root);
        _root.Background = ThemeEngine.WindowBackground;
    }

    // MARK: Rows

    private FrameworkElement BuildZoomRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _zoomOutButton.Content = new FontIcon { Glyph = "", FontSize = 14 };
        _zoomInButton.Content = new FontIcon { Glyph = "", FontSize = 14 };
        ToolTipService.SetToolTip(_zoomOutButton, Loc.S("localSdr.zoomOut"));
        ToolTipService.SetToolTip(_zoomInButton, Loc.S("localSdr.zoomIn"));
        AutomationProperties_Name(_zoomOutButton, Loc.S("localSdr.zoomOut"));
        AutomationProperties_Name(_zoomInButton, Loc.S("localSdr.zoomIn"));
        _zoomOutButton.Click += (_, _) => Model.Zoom(-1);
        _zoomInButton.Click += (_, _) => Model.Zoom(1);
        ToolTipService.SetToolTip(_passbandText, Loc.S("localSdr.passband.readoutHelp"));
        _resetPassbandButton.Content = Loc.S("localSdr.passband.reset");
        ToolTipService.SetToolTip(_resetPassbandButton, Loc.S("localSdr.passband.resetHelp"));
        _resetPassbandButton.Click += (_, _) => Model.ResetPassband();
        row.Children.Add(_zoomOutButton);
        row.Children.Add(_zoomInButton);
        row.Children.Add(_zoomSpanText);
        row.Children.Add(_passbandText);
        row.Children.Add(_resetPassbandButton);
        return row;
    }

    private FrameworkElement BuildConnectionRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        row.Children.Add(_hostText);
        var hint = new TextBlock { Text = Loc.S("localSdr.settingsHelp"), Foreground = new SolidColorBrush(Colors.Gray), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(hint);
        _connectButton.Click += (_, _) =>
        {
            if (Model.IsConnected)
            {
                Model.Disconnect();
            }
            else
            {
                Model.Connect();
            }
        };
        row.Children.Add(_connectButton);
        _recordButton.Click += (_, _) => Model.ToggleRecording();
        _recordButton.Margin = new Thickness(24, 0, 0, 0);
        row.Children.Add(_recordButton);
        // The same Recordings window as the WebSDR window's and the CW page's
        // PLAY: MyKiwiSDR recordings sit beside the rig's own.
        var play = new Button { Content = Loc.S("localSdr.play") };
        ToolTipService.SetToolTip(play, Loc.S("localSdr.playHelp"));
        play.Click += (_, _) => RecordingsRequested?.Invoke();
        row.Children.Add(play);
        return row;
    }

    private FrameworkElement BuildTuningRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        row.Children.Add(_frequencyText);
        ToolTipService.SetToolTip(_frequencyBox, Loc.S("localSdr.frequencyHelp"));
        _frequencyBox.GotFocus += (_, _) => _frequencyFocused = true;
        _frequencyBox.LostFocus += (_, _) =>
        {
            _frequencyFocused = false;
            _frequencyBox.Text = KHzText(Model.FrequencyHz);
        };
        _frequencyBox.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                CommitFrequency();
                e.Handled = true;
            }
        };
        row.Children.Add(_frequencyBox);
        foreach (var step in Steps)
        {
            var group = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            var down = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 } };
            var up = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 } };
            down.Click += (_, _) => Model.Step(-step);
            up.Click += (_, _) => Model.Step(step);
            group.Children.Add(down);
            group.Children.Add(new TextBlock
            {
                Text = step >= 1000 ? $"{step / 1000} kHz" : $"{step} Hz",
                FontSize = 12,
                MinWidth = 40,
                TextAlignment = TextAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
            group.Children.Add(up);
            row.Children.Add(group);
        }
        var modes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        foreach (var mode in Enum.GetValues<KiwiSdrMode>())
        {
            var button = new ToggleButton { Content = mode.Label(), MinWidth = 52 };
            button.Click += (_, _) => Model.SelectMode(mode);
            _modeButtons.Add((mode, button));
            modes.Children.Add(button);
        }
        row.Children.Add(modes);
        return row;
    }

    private FrameworkElement BuildMeterRow()
    {
        var row = new Grid { ColumnSpacing = 16 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var meter = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        meter.Children.Add(_meterBar);
        meter.Children.Add(_meterText);
        meter.Children.Add(_overloadText);
        row.Children.Add(meter);

        var audio = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        audio.Children.Add(new FontIcon { Glyph = "", FontSize = 14, VerticalAlignment = VerticalAlignment.Center });
        ToolTipService.SetToolTip(_volumeSlider, Loc.S("localSdr.volume"));
        _volumeSlider.ValueChanged += (_, e) =>
        {
            if (!_suppress)
            {
                Model.Volume = e.NewValue;
            }
        };
        audio.Children.Add(_volumeSlider);
        _muteButton.Click += (_, _) => Model.ToggleMuted();
        audio.Children.Add(_muteButton);
        Grid.SetColumn(audio, 1);
        row.Children.Add(audio);
        return row;
    }

    private FrameworkElement BuildRigLinkRow()
    {
        var row = new Grid { ColumnSpacing = 14 };
        for (var i = 0; i < 5; i++)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = i == 4 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        }
        ToolTipService.SetToolTip(_followWidthSwitch, Loc.S("localSdr.followRigWidthHelp"));
        _followWidthSwitch.Toggled += (_, _) => { if (!_suppress) { Model.SetFollowRigWidth(_followWidthSwitch.IsOn); } };
        ToolTipService.SetToolTip(_followSwitch, Loc.S("localSdr.followRigHelp"));
        ToolTipService.SetToolTip(_tuneSwitch, Loc.S("localSdr.tuneRigHelp"));
        ToolTipService.SetToolTip(_muteTxSwitch, Loc.S("localSdr.muteOnTxHelp"));
        _followSwitch.Toggled += (_, _) => { if (!_suppress) { Model.FollowRig = _followSwitch.IsOn; } };
        _tuneSwitch.Toggled += (_, _) => { if (!_suppress) { Model.TuneRig = _tuneSwitch.IsOn; } };
        _muteTxSwitch.Toggled += (_, _) => { if (!_suppress) { Model.MuteOnTransmit = _muteTxSwitch.IsOn; } };
        row.Children.Add(_followSwitch);
        Grid.SetColumn(_followWidthSwitch, 1);
        row.Children.Add(_followWidthSwitch);
        Grid.SetColumn(_tuneSwitch, 2);
        row.Children.Add(_tuneSwitch);
        Grid.SetColumn(_muteTxSwitch, 3);
        row.Children.Add(_muteTxSwitch);
        Grid.SetColumn(_rigLinkText, 4);
        row.Children.Add(_rigLinkText);
        return row;
    }

    // MARK: Receiver section

    private readonly List<Action> _receiverRefreshers = [];

    private void BuildReceiverSection()
    {
        _receiverExpander.Content = _receiverPanel;

        // AGC: threshold + decay while on, manual gain while off.
        var agc = Row();
        var agcSwitch = new ToggleSwitch { OnContent = "AGC", OffContent = "AGC", MinWidth = 0 };
        ToolTipService.SetToolTip(agcSwitch, Loc.S("localSdr.receiver.agcHelp"));
        agcSwitch.Toggled += (_, _) => { if (!_suppress) { Model.UpdateReceiver(r => r with { Agc = agcSwitch.IsOn }); } };
        agc.Children.Add(agcSwitch);
        var threshold = Knob(agc, "localSdr.receiver.threshold", KiwiReceiverSettings.ThresholdMin, KiwiReceiverSettings.ThresholdMax, 1,
                             v => Model.UpdateReceiver(r => r with { Threshold = (int)v }), r => r.Threshold, v => $"{v:0} dB");
        var decay = Knob(agc, "localSdr.receiver.decay", KiwiReceiverSettings.DecayMin, KiwiReceiverSettings.DecayMax, KiwiReceiverSettings.DecayStep,
                         v => Model.UpdateReceiver(r => r with { Decay = (int)v }), r => r.Decay, v => $"{v:0} ms");
        var gain = Knob(agc, "localSdr.receiver.manualGain", KiwiReceiverSettings.ManualGainMin, KiwiReceiverSettings.ManualGainMax, 1,
                        v => Model.UpdateReceiver(r => r with { ManualGain = (int)v }), r => r.ManualGain, v => $"{v:0} dB");
        _receiverRefreshers.Add(() =>
        {
            var on = Model.Receiver.Agc;
            agcSwitch.IsOn = on;
            threshold.Visibility = decay.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            gain.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        });
        _receiverPanel.Children.Add(agc);

        // Noise blanker.
        var nb = Row();
        nb.Children.Add(Label("NB"));
        var nbBox = new ComboBox { MinWidth = 120 };
        nbBox.Items.Add(new ComboBoxItem { Content = Loc.S("localSdr.receiver.off"), Tag = KiwiNoiseBlanker.Off });
        nbBox.Items.Add(new ComboBoxItem { Content = Loc.S("localSdr.receiver.standard"), Tag = KiwiNoiseBlanker.Standard });
        nbBox.Items.Add(new ComboBoxItem { Content = "Wild", Tag = KiwiNoiseBlanker.Wild });
        ToolTipService.SetToolTip(nbBox, Loc.S("localSdr.receiver.noiseBlankerHelp"));
        nbBox.SelectionChanged += (_, _) =>
        {
            if (!_suppress && nbBox.SelectedItem is ComboBoxItem { Tag: KiwiNoiseBlanker kind })
            {
                Model.UpdateReceiver(r => r with { NoiseBlanker = kind });
            }
        };
        nb.Children.Add(nbBox);
        var gate = Knob(nb, "localSdr.receiver.gate", KiwiReceiverSettings.GateMin, KiwiReceiverSettings.GateMax, KiwiReceiverSettings.GateStep,
                        v => Model.UpdateReceiver(r => r with { Gate = (int)v }), r => r.Gate, v => $"{v:0}");
        var blankerThreshold = Knob(nb, "localSdr.receiver.threshold", KiwiReceiverSettings.BlankerThresholdMin, KiwiReceiverSettings.BlankerThresholdMax, 1,
                                    v => Model.UpdateReceiver(r => r with { BlankerThreshold = (int)v }), r => r.BlankerThreshold, v => $"{v:0}");
        var wild = Knob(nb, "localSdr.receiver.threshold", KiwiReceiverSettings.WildThresholdMin, KiwiReceiverSettings.WildThresholdMax, KiwiReceiverSettings.WildThresholdStep,
                        v => Model.UpdateReceiver(r => r with { WildThreshold = Math.Round(v, 2) }), r => r.WildThreshold, v => v.ToString("0.00", CultureInfo.InvariantCulture));
        _receiverRefreshers.Add(() =>
        {
            foreach (var item in nbBox.Items.OfType<ComboBoxItem>().Where(i => (KiwiNoiseBlanker)i.Tag == Model.Receiver.NoiseBlanker))
            {
                nbBox.SelectedItem = item;
            }
            gate.Visibility = blankerThreshold.Visibility = Model.Receiver.NoiseBlanker == KiwiNoiseBlanker.Standard ? Visibility.Visible : Visibility.Collapsed;
            wild.Visibility = Model.Receiver.NoiseBlanker == KiwiNoiseBlanker.Wild ? Visibility.Visible : Visibility.Collapsed;
        });
        _receiverPanel.Children.Add(nb);

        // Noise filter.
        var nr = Row();
        nr.Children.Add(Label("NR"));
        var nrBox = new ComboBox { MinWidth = 120 };
        nrBox.Items.Add(new ComboBoxItem { Content = Loc.S("localSdr.receiver.off"), Tag = KiwiNoiseFilter.Off });
        nrBox.Items.Add(new ComboBoxItem { Content = "WDSP", Tag = KiwiNoiseFilter.Wdsp });
        nrBox.Items.Add(new ComboBoxItem { Content = "LMS", Tag = KiwiNoiseFilter.Lms });
        nrBox.Items.Add(new ComboBoxItem { Content = "Spectral", Tag = KiwiNoiseFilter.Spectral });
        ToolTipService.SetToolTip(nrBox, Loc.S("localSdr.receiver.noiseFilterHelp"));
        nrBox.SelectionChanged += (_, _) =>
        {
            if (!_suppress && nrBox.SelectedItem is ComboBoxItem { Tag: KiwiNoiseFilter filter })
            {
                Model.UpdateReceiver(r => r.WithNoiseFilter(filter));
            }
        };
        nr.Children.Add(nrBox);
        var denoise = new CheckBox { Content = Loc.S("localSdr.receiver.denoise"), MinWidth = 0 };
        var autonotch = new CheckBox { Content = Loc.S("localSdr.receiver.autonotch"), MinWidth = 0 };
        denoise.Click += (_, _) => Model.UpdateReceiver(r => r with { Denoise = denoise.IsChecked == true });
        autonotch.Click += (_, _) => Model.UpdateReceiver(r => r with { Autonotch = autonotch.IsChecked == true });
        nr.Children.Add(denoise);
        nr.Children.Add(autonotch);
        _receiverRefreshers.Add(() =>
        {
            foreach (var item in nrBox.Items.OfType<ComboBoxItem>().Where(i => (KiwiNoiseFilter)i.Tag == Model.Receiver.NoiseFilter))
            {
                nrBox.SelectedItem = item;
            }
            var separate = Model.Receiver.NoiseFilter is KiwiNoiseFilter.Wdsp or KiwiNoiseFilter.Lms;
            denoise.Visibility = autonotch.Visibility = separate ? Visibility.Visible : Visibility.Collapsed;
            denoise.IsChecked = Model.Receiver.Denoise;
            autonotch.IsChecked = Model.Receiver.Autonotch;
        });
        _receiverPanel.Children.Add(nr);
    }

    private static StackPanel Row() => new() { Orientation = Orientation.Horizontal, Spacing = 14 };

    private static TextBlock Label(string text) => new() { Text = text, Width = 34, VerticalAlignment = VerticalAlignment.Center };

    /// A labelled slider with a readout, added to "row"; commits on every
    /// change (the model throttles what goes out).
    private FrameworkElement Knob(Panel row, string labelKey, double min, double max, double step,
                                  Action<double> set, Func<KiwiReceiverSettings, double> get, Func<double, string> format)
    {
        var box = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        box.Children.Add(new TextBlock { Text = Loc.S(labelKey), VerticalAlignment = VerticalAlignment.Center });
        var slider = new Slider { Minimum = min, Maximum = max, StepFrequency = step, Width = 150, VerticalAlignment = VerticalAlignment.Center };
        var readout = new TextBlock { FontFamily = new FontFamily("Consolas"), MinWidth = 56, VerticalAlignment = VerticalAlignment.Center };
        slider.ValueChanged += (_, e) =>
        {
            readout.Text = format(e.NewValue);
            if (!_suppress)
            {
                set(e.NewValue);
            }
        };
        box.Children.Add(slider);
        box.Children.Add(readout);
        row.Children.Add(box);
        _receiverRefreshers.Add(() => slider.Value = get(Model.Receiver));
        return box;
    }

    // MARK: Refresh

    private void Refresh()
    {
        _suppress = true;
        try
        {
            var hostPort = LocalSdrModel.SavedHostPort;
            _hostText.Text = hostPort.Length == 0 ? Loc.S("localSdr.noHost") : hostPort;
            _hostText.Foreground = hostPort.Length == 0 ? new SolidColorBrush(Colors.Gray) : (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
            _connectButton.Content = Model.IsConnected ? Loc.S("common.disconnect") : Loc.S("common.connect");
            _connectButton.IsEnabled = Model.IsConnected || (!Model.IsLoadingPassword && LocalSdrModel.IsValidHost(hostPort));

            _frequencyText.Text = DottedHz(Model.FrequencyHz);
            if (!_frequencyFocused)
            {
                _frequencyBox.Text = KHzText(Model.FrequencyHz);
            }
            foreach (var (mode, button) in _modeButtons)
            {
                button.IsChecked = mode == Model.Mode;
            }

            _zoomOutButton.IsEnabled = Model.CanZoomOut;
            _zoomInButton.IsEnabled = Model.CanZoomIn;
            _zoomSpanText.Text = Model.View is { } view ? SpanText(Model.Geometry.SpanHz(view.Zoom)) : "";
            _passbandText.Text = $"{Model.Passband.RangeText(Model.Mode)} · {Model.Passband.Width} Hz";
            _resetPassbandButton.IsEnabled = !Model.IsPassbandDefault;

            _volumeSlider.Value = Model.Volume;
            _muteButton.IsChecked = Model.IsMuted;
            _muteButton.Content = Model.IsMuted ? Loc.S("localSdr.muted") : Loc.S("localSdr.mute");
            _muteButton.Foreground = Model.IsMuted ? new SolidColorBrush(Colors.IndianRed) : (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];

            _followSwitch.IsOn = Model.FollowRig;
            _followWidthSwitch.IsOn = Model.FollowRigWidth;
            _followWidthSwitch.IsEnabled = Model.FollowRig;
            _tuneSwitch.IsOn = Model.TuneRig;
            _muteTxSwitch.IsOn = Model.MuteOnTransmit;
            _rigLinkText.Text = RigLinkText();
            _rigLinkText.Foreground = Model.RigLinkNote is null
                ? new SolidColorBrush(Colors.Gray)
                : new SolidColorBrush(Colors.Orange);

            foreach (var refresh in _receiverRefreshers)
            {
                refresh();
            }
            _statusText.Text = Model.RecordingNote is { } note ? $"{StatusText()} · {note}" : StatusText();
            UpdateRecordButton();
        }
        finally
        {
            _suppress = false;
        }
        _waterfall.Refresh();
    }

    private void UpdateRecordButton()
    {
        if (Model.IsRecording)
        {
            var elapsed = Model.SegmentStartedAt is { } started
                ? " " + (DateTime.Now - started).ToString(@"m\:ss")
                : "";
            _recordButton.Content = Loc.S("common.stop") + elapsed;
            _recordButton.Foreground = new SolidColorBrush(Colors.Red);
            _recordButton.IsEnabled = true;
            ToolTipService.SetToolTip(_recordButton, Loc.S("localSdr.stopRecordingHelp"));
            if (!_elapsedTimer.IsRunning)
            {
                _elapsedTimer.Start();
            }
        }
        else
        {
            var ready = Model.State == LocalSdrModel.ConnectionState.Connected;
            _recordButton.Content = Loc.S("localSdr.record");
            _recordButton.ClearValue(Control.ForegroundProperty);
            _recordButton.IsEnabled = ready;
            ToolTipService.SetToolTip(_recordButton, Loc.S(ready ? "localSdr.recordHelp" : "localSdr.recordNeedsConnection"));
            _elapsedTimer.Stop();
        }
    }

    private void RefreshMeter()
    {
        if (Model.MeterDbm is { } dbm)
        {
            _meterBar.Value = Math.Clamp(dbm, -130, -20);
            _meterText.Text = $"{SUnits(dbm)}  {dbm:0} dBm";
        }
        else
        {
            _meterBar.Value = -130;
            _meterText.Text = "—";
        }
        _overloadText.Text = Model.MeterOverload ? Loc.S("localSdr.adcOverload") : "";
    }

    /// S-units with S9 = −73 dBm and 6 dB a unit, then dB over S9.
    private static string SUnits(double dbm)
    {
        if (dbm >= -73)
        {
            var over = (int)Math.Round(dbm + 73);
            return over <= 0 ? "S9" : $"S9+{over}";
        }
        return $"S{Math.Max(0, (int)Math.Round((dbm + 127) / 6))}";
    }

    private string RigLinkText()
    {
        var active = Model.FollowRig switch
        {
            true when Model.TuneRig => Loc.S("localSdr.rigLink.both"),
            true => Loc.S("localSdr.rigLink.followOnly"),
            false when Model.TuneRig => Loc.S("localSdr.rigLink.tuneOnly"),
            _ => Loc.S("localSdr.rigLink.off"),
        };
        if (!Model.IsConnected && (Model.FollowRig || Model.TuneRig))
        {
            return Loc.F("localSdr.rigLink.whenConnected", active);
        }
        return Model.RigLinkNote is { } note ? Loc.F("localSdr.rigLink.withNote", active, note) : active;
    }

    private string StatusText() => Model.State switch
    {
        LocalSdrModel.ConnectionState.Disconnected => Model.IsLoadingPassword
            ? Loc.S("localSdr.status.readingPassword")
            : Loc.S("localSdr.status.disconnected"),
        LocalSdrModel.ConnectionState.Connecting => Loc.F("localSdr.status.connecting", Model.ConnectedHostPort),
        LocalSdrModel.ConnectionState.Connected => Loc.F("localSdr.status.connected", Model.ConnectedHostPort,
                                                         Model.SampleRate.ToString("F1", CultureInfo.InvariantCulture)),
        _ => Message(Model.Error),
    };

    public static string Message(KiwiSdrError? error) => error?.Kind switch
    {
        KiwiErrorKind.InvalidHost => Loc.S("localSdr.error.invalidHost"),
        KiwiErrorKind.BadPassword => Loc.S("localSdr.error.badPassword"),
        KiwiErrorKind.Busy => Loc.S("localSdr.error.busy"),
        KiwiErrorKind.Down => Loc.S("localSdr.error.down"),
        KiwiErrorKind.Redirect => Loc.F("localSdr.error.redirect", error.Detail),
        KiwiErrorKind.Refused => Loc.F("localSdr.error.refused", error.Code),
        KiwiErrorKind.Unreachable => Loc.F("localSdr.error.unreachable", error.Detail),
        KiwiErrorKind.NoResponse => Loc.S("localSdr.error.noResponse"),
        _ => "",
    };

    // MARK: Helpers

    private void CommitFrequency()
    {
        var text = _frequencyBox.Text.Trim().Replace(',', '.');
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var kHz) && kHz > 0)
        {
            Model.SetFrequency((int)Math.Round(kHz * 1000, MidpointRounding.AwayFromZero));
        }
        _frequencyBox.Text = KHzText(Model.FrequencyHz);
    }

    private static string KHzText(int hz)
    {
        var text = (hz / 1000.0).ToString("F3", CultureInfo.InvariantCulture).TrimEnd('0');
        return text.EndsWith('.') ? text[..^1] : text;
    }

    /// "14.074.000" — frequencies never follow the locale.
    private static string DottedHz(int hz) => hz.ToString("N0", CultureInfo.InvariantCulture).Replace(',', '.');

    private static string SpanText(double hz) => hz >= 1_000_000
        ? $"{(hz / 1e6).ToString(hz >= 10_000_000 ? "F0" : "F1", CultureInfo.InvariantCulture)} MHz"
        : $"{(hz / 1000).ToString("F1", CultureInfo.InvariantCulture)} kHz";

    private static void AutomationProperties_Name(DependencyObject element, string name) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}

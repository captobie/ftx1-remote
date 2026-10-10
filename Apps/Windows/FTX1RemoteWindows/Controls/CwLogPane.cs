using System.Globalization;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace FTX1RemoteWindows.Controls;

/// The side the rig transmits on, as the Log QSO pane logs it: frequency,
/// mode (C4FM is a flag, as in RigState) and the RF power setting (0–1).
public readonly record struct CwTransmitter(long FrequencyHz, RigMode? Mode, bool IsC4fm, double? PowerLevel);

/// The CW window's Log QSO pane, under the send pane — the Mac's CWLogPane
/// (Apps/Mac/FTX1RemoteMac/CWLogPane.swift): logs the contact to the
/// logbook chosen in Settings → Logbook through <see cref="QsoLogger"/>.
/// The call is <see cref="CwSender.TheirCall"/> — the same field {CALL}
/// macros read and a click on a decoded callsign fills. Frequency, mode and
/// power come from the rig's transmitting side when Log QSO is clicked.
///
/// Time on is set when the call goes from empty to filled (or by the reset
/// button); time off is the moment Log QSO is clicked. After the logbook
/// confirms the QSO the fields clear for the next one (the Mac's user
/// decision); anything short of that keeps them so it can be checked and
/// retried. No Lookup button, unlike the Mac's: HRD Logbook has no way
/// found to be asked for one, and looks the call up itself on receipt.
public sealed class CwLogPane : UserControl
{
    private const string DefaultRst = "599";

    private readonly CwSender _sender;
    private readonly CwWindowLink _link;
    private readonly WorkedStationsStore _worked;

    private readonly TextBlock _destinationText = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox _theirCallBox = new() { Width = 120, PlaceholderText = "Their call", CharacterCasing = CharacterCasing.Upper };
    private readonly TextBlock _timeOnText = new() { FontFamily = new FontFamily("Consolas"), MinWidth = 100, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _workedText = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBox _rstSentBox = new() { Width = 64, Text = DefaultRst };
    private readonly TextBox _rstReceivedBox = new() { Width = 64, Text = DefaultRst };
    private readonly TextBox _nameBox = new() { Width = 140, PlaceholderText = "Name" };
    private readonly TextBox _commentBox = new() { PlaceholderText = "Comment" };
    private readonly TextBlock _rigText = new() { FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center };
    private readonly FontIcon _resultIcon = new() { FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _resultRing = new() { Width = 14, Height = 14, IsActive = false };
    private readonly TextBlock _resultText = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Button _logButton = new();

    private readonly DispatcherQueueTimer _rigTimer;
    private DateTimeOffset? _timeOn;
    private string _shownCall = "";
    private bool _isLogging;
    private bool _updating;

    private enum ResultKind { Success, Warning, Failure }

    public CwLogPane(CwSender sender, CwWindowLink link, WorkedStationsStore worked)
    {
        _sender = sender;
        _link = link;
        _worked = worked;

        var root = new StackPanel { Spacing = 8, Padding = new Thickness(16, 8, 16, 10) };
        root.Children.Add(BuildHeader());
        root.Children.Add(BuildCallRow());
        root.Children.Add(BuildFieldsRow());
        root.Children.Add(BuildActionRow());
        Content = root;

        _sender.Changed += SyncCall;
        _worked.Changed += RefreshWorked;
        _rigTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _rigTimer.Interval = TimeSpan.FromMilliseconds(500);
        _rigTimer.Tick += (_, _) => RefreshRig();
        _rigTimer.Start();
        Unloaded += (_, _) =>
        {
            _rigTimer.Stop();
            _sender.Changed -= SyncCall;
            _worked.Changed -= RefreshWorked;
        };
        SetResult(null, null);
        RefreshTimeOn();
        SyncCall();
        RefreshRig();
    }

    /// Theme-dependent brushes, called by the window after a theme change.
    public void ApplyTheme()
    {
        RefreshRig();
        RefreshWorked();
    }

    /// Fills Their call — a click on a callsign in the decoded text.
    public void FillTheirCall(string call)
    {
        _sender.TheirCall = call;
        SyncCall();
    }

    /// Green worked on this band, orange worked on other bands only, null
    /// never (then NewStationBrush) — shared with the decoded text and legend.
    public static Brush? WorkedBrush(WorkedStations.Status status) => status switch
    {
        WorkedStations.Status.ThisBand => (Brush)Application.Current.Resources["SystemFillColorSuccessBrush"],
        WorkedStations.Status.OtherBand => new SolidColorBrush(Microsoft.UI.Colors.DarkOrange),
        _ => null,
    };

    /// A fixed link blue (the Mac's linkColor) rather than the accent color,
    /// which can be close enough to orange to blur the two.
    public static Brush NewStationBrush => new SolidColorBrush(Windows.UI.Color.FromArgb(255, 0x3B, 0x8E, 0xEA));

    private Grid BuildHeader()
    {
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = "Log QSO", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(_destinationText, 1);
        header.Children.Add(_destinationText);
        return header;
    }

    private StackPanel BuildCallRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        ToolTipService.SetToolTip(_theirCallBox, "The station you're working — also {CALL} in macros. Click a callsign in the decoded text to fill it in.");
        AutomationProperties.SetName(_theirCallBox, "Their call");
        _theirCallBox.TextChanged += (_, _) =>
        {
            if (!_updating)
            {
                _sender.TheirCall = _theirCallBox.Text.Trim();
                SyncCall();
            }
        };
        row.Children.Add(_theirCallBox);

        var timeOn = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        timeOn.Children.Add(Secondary("On"));
        timeOn.Children.Add(_timeOnText);
        var reset = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(6, 4, 6, 4) };
        ToolTipService.SetToolTip(reset, "Set the time on to now");
        AutomationProperties.SetName(reset, "Set the time on to now");
        reset.Click += (_, _) =>
        {
            _timeOn = DateTimeOffset.UtcNow;
            RefreshTimeOn();
        };
        timeOn.Children.Add(reset);
        row.Children.Add(timeOn);
        row.Children.Add(_workedText);
        return row;
    }

    private Grid BuildFieldsRow()
    {
        var row = new Grid { ColumnSpacing = 8 };
        foreach (var width in new[] { GridLength.Auto, GridLength.Auto, GridLength.Auto, GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star) })
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }
        AutomationProperties.SetName(_rstSentBox, "RST sent");
        AutomationProperties.SetName(_rstReceivedBox, "RST received");
        AutomationProperties.SetName(_nameBox, "Name");
        AutomationProperties.SetName(_commentBox, "Comment");
        var items = new FrameworkElement[] { Secondary("RST sent"), _rstSentBox, Secondary("rcvd"), _rstReceivedBox, _nameBox, _commentBox };
        for (var i = 0; i < items.Length; i++)
        {
            Grid.SetColumn(items[i], i);
            row.Children.Add(items[i]);
        }
        return row;
    }

    private Grid BuildActionRow()
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ToolTipService.SetToolTip(_rigText, "Logged from the transmitting side: frequency, mode and RF power setting");
        row.Children.Add(_rigText);

        var result = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        result.Children.Add(_resultIcon);
        result.Children.Add(_resultRing);
        result.Children.Add(_resultText);
        Grid.SetColumn(result, 1);
        row.Children.Add(result);

        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        panel.Children.Add(new FontIcon { Glyph = "", FontSize = 14 });
        panel.Children.Add(new TextBlock { Text = "Log QSO" });
        _logButton.Content = panel;
        _logButton.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        AutomationProperties.SetName(_logButton, "Log QSO");
        ToolTipService.SetToolTip(_logButton, "Log this QSO (Ctrl+L)");
        _logButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.L, Modifiers = VirtualKeyModifiers.Control });
        _logButton.Click += async (_, _) => await LogAsync();
        Grid.SetColumn(_logButton, 2);
        row.Children.Add(_logButton);
        return row;
    }

    private static TextBlock Secondary(string text) => new()
    {
        Text = text,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };

    private string NormalizedCall => _sender.TheirCall.Trim().ToUpperInvariant();

    /// Their call changed (typed, filled, cleared, or from the sender):
    /// the box follows it, and the time on starts when it goes from empty
    /// to filled.
    private void SyncCall()
    {
        var call = NormalizedCall;
        if (_theirCallBox.Text.Trim().ToUpperInvariant() != call)
        {
            _updating = true;
            _theirCallBox.Text = call;
            _theirCallBox.SelectionStart = call.Length;
            _updating = false;
        }
        _logButton.IsEnabled = !_isLogging && call.Length > 0;
        if (call == _shownCall)
        {
            return;
        }
        if (call.Length == 0)
        {
            _timeOn = null;
        }
        else if (_shownCall.Length == 0)
        {
            _timeOn = DateTimeOffset.UtcNow;
            SetResult(null, null);
        }
        _shownCall = call;
        RefreshTimeOn();
        RefreshWorked();
    }

    private void RefreshTimeOn() =>
        _timeOnText.Text = _timeOn is { } on ? on.UtcDateTime.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + " UTC" : "—";

    /// Worked-before for the call being entered: how often, the last QSO,
    /// and whether the band the rig transmits on is new for this station.
    private void RefreshWorked()
    {
        var call = NormalizedCall;
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        string text;
        Brush brush;
        string? tip = null;
        if (call.Length == 0)
        {
            text = "";
            brush = secondary;
        }
        else if (_worked.Problem is { } problem)
        {
            text = $"Worked before: {problem}";
            brush = secondary;
        }
        else if (_worked.Worked.SummaryOf(call) is { } summary)
        {
            var last = summary.Last;
            text = $"Worked {summary.Count}× · last {last.Date.UtcDateTime:yyyy-MM-dd} {last.Band.ToLowerInvariant()} {last.Mode}";
            var newBand = _worked.Band is { } band && !summary.Bands.Contains(band.ToLowerInvariant());
            if (newBand)
            {
                text += $" · new on {_worked.Band}";
            }
            brush = WorkedBrush(newBand ? WorkedStations.Status.OtherBand : WorkedStations.Status.ThisBand)!;
            tip = string.Join(", ", summary.Bands.Order());
        }
        else
        {
            text = "New station";
            brush = NewStationBrush;
        }
        _workedText.Text = text;
        _workedText.Foreground = brush;
        ToolTipService.SetToolTip(_workedText, tip ?? (text.Length > 0 ? text : null));
    }

    /// The readout, the destination line and the band worked-before
    /// compares against — every half second, from the rig's polled state.
    private void RefreshRig()
    {
        var tx = _link.Transmitter();
        _rigText.Text = tx is { } t
            ? $"{(t.FrequencyHz > 0 ? (t.FrequencyHz / 1_000_000.0).ToString("0.0000", CultureInfo.InvariantCulture) : "—")} MHz  "
              + $"{(t.IsC4fm ? "C4FM" : t.Mode?.DisplayName() ?? "—")}  {(t.PowerLevel is { } p ? $"{Math.Round(p * 100):0} W" : "— W")}"
            : "— MHz  —  — W";
        _rigText.Foreground = (Brush)Application.Current.Resources[tx is null ? "TextFillColorTertiaryBrush" : "TextFillColorPrimaryBrush"];
        _worked.SetBand(tx is { FrequencyHz: > 0 } f ? BandPlan.BandContaining(f.FrequencyHz)?.Name : null);

        var none = AppSettings.Logbook == LogbookKind.None;
        _destinationText.Text = none ? "No logbook — choose one in Settings → Logbook" : "To HRD Logbook";
        _destinationText.Foreground = none
            ? new SolidColorBrush(Microsoft.UI.Colors.DarkOrange)
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
    }

    private void SetResult(ResultKind? kind, string? text)
    {
        _resultRing.IsActive = _isLogging;
        _resultRing.Visibility = _isLogging ? Visibility.Visible : Visibility.Collapsed;
        _resultIcon.Visibility = kind is null ? Visibility.Collapsed : Visibility.Visible;
        (_resultIcon.Glyph, _resultIcon.Foreground) = kind switch
        {
            ResultKind.Success => ("", WorkedBrush(WorkedStations.Status.ThisBand)!),
            ResultKind.Warning => ("", new SolidColorBrush(Microsoft.UI.Colors.DarkOrange)),
            _ => ("", new SolidColorBrush(Microsoft.UI.Colors.Red)),
        };
        _resultText.Text = text ?? "";
        ToolTipService.SetToolTip(_resultText, text);
    }

    private async Task LogAsync()
    {
        var call = NormalizedCall;
        if (call.Length == 0 || _isLogging)
        {
            return;
        }
        if (_link.Transmitter() is not { } tx)
        {
            SetResult(ResultKind.Failure, "Not connected to the rig — frequency and mode unknown");
            return;
        }
        if (tx.FrequencyHz <= 0)
        {
            SetResult(ResultKind.Failure, "The transmitting side's frequency isn't known yet");
            return;
        }
        if (AdifMode.For(tx.Mode, tx.IsC4fm) is not { } mode)
        {
            SetResult(ResultKind.Failure, $"Can't log in {tx.Mode?.DisplayName() ?? "an unknown mode"}");
            return;
        }
        var end = DateTimeOffset.UtcNow;
        // To the second: what the ADIF record carries, and what the log is
        // searched for to confirm it.
        var start = TruncateToSecond(_timeOn ?? end);
        var qso = new LoggedQso
        {
            Call = call,
            Start = start,
            End = TruncateToSecond(end),
            FrequencyHz = tx.FrequencyHz,
            Mode = mode.Mode,
            Submode = mode.Submode,
            RstSent = _rstSentBox.Text.Trim(),
            RstReceived = _rstReceivedBox.Text.Trim(),
            TxPower = tx.PowerLevel is { } p ? Math.Round(p * 100).ToString("0", CultureInfo.InvariantCulture) : "",
            Comments = _commentBox.Text.Trim(),
            Name = _nameBox.Text.Trim(),
            MyCall = AppSettings.Callsign,
            MyGrid = AppSettings.GridSquare,
        };
        _isLogging = true;
        _logButton.IsEnabled = false;
        SetResult(null, "Logging…");
        var outcome = await QsoLogger.LogAsync(qso);
        _isLogging = false;
        _logButton.IsEnabled = NormalizedCall.Length > 0;
        switch (outcome)
        {
            case QsoLogOutcome.Logged:
                SetResult(ResultKind.Success, $"{call} logged");
                _worked.Reload();
                // Only clear if nothing was typed for a new QSO meanwhile.
                if (NormalizedCall == call)
                {
                    Clear();
                }
                break;
            case QsoLogOutcome.SentUnconfirmed(var reason):
                SetResult(ResultKind.Warning, $"{reason} — check HRD Logbook before logging {call} again");
                break;
            case QsoLogOutcome.Failed(var reason):
                SetResult(ResultKind.Failure, reason);
                break;
        }
    }

    private static DateTimeOffset TruncateToSecond(DateTimeOffset date) =>
        new(date.UtcTicks - date.UtcTicks % TimeSpan.TicksPerSecond, TimeSpan.Zero);

    private void Clear()
    {
        _sender.TheirCall = "";
        SyncCall();
        _rstSentBox.Text = DefaultRst;
        _rstReceivedBox.Text = DefaultRst;
        _nameBox.Text = "";
        _commentBox.Text = "";
    }
}

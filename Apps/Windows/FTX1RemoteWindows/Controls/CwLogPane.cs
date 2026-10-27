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
/// button); time off is the moment Log QSO is clicked. After every logbook
/// it went to (HRD/Log4OM and/or Wavelog) confirms the QSO the fields clear
/// for the next one (the Mac's user decision); anything short of that keeps
/// them so it can be checked and retried. If the primary logbook took it
/// but Wavelog didn't, "Retry Wavelog" resends that same QSO to Wavelog
/// alone (the Mac's user decision), so the primary never gets a second
/// copy; it stays offered until it works or is dismissed. The Lookup button
/// (left of Their call, as on the Mac) shows only for Log4OM, through its remote control; HRD Logbook has no way found to
/// be asked for one, and looks the call up itself on receipt.
public sealed class CwLogPane : UserControl
{
    private const string DefaultRst = "599";

    private readonly CwSender _sender;
    private readonly CwWindowLink _link;
    private readonly WorkedStationsStore _worked;

    private readonly TextBlock _destinationText = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox _theirCallBox = new() { Width = 120, PlaceholderText = Loc.S("common.theirCall"), CharacterCasing = CharacterCasing.Upper };
    private readonly TextBlock _timeOnText = new() { FontFamily = new FontFamily("Consolas"), MinWidth = 100, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _workedText = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBox _rstSentBox = new() { Width = 64, Text = DefaultRst };
    private readonly TextBox _rstReceivedBox = new() { Width = 64, Text = DefaultRst };
    private readonly TextBox _nameBox = new() { Width = 140, PlaceholderText = Loc.S("common.name") };
    private readonly TextBox _commentBox = new() { PlaceholderText = Loc.S("common.comment") };
    private readonly TextBlock _rigText = new() { FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center };
    private readonly FontIcon _resultIcon = new() { FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _resultRing = new() { Width = 14, Height = 14, IsActive = false };
    private readonly TextBlock _resultText = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Button _logButton = new();
    private readonly Button _lookupButton = new() { Padding = new Thickness(8, 4, 8, 4) };
    private readonly StackPanel _retryPanel = new() { Orientation = Orientation.Horizontal, Spacing = 4, Visibility = Visibility.Collapsed };
    private readonly Button _retryButton = new();
    private readonly TextBlock _retryText = new();
    private readonly Button _retryDismissButton = new() { Padding = new Thickness(6, 4, 6, 4) };

    private readonly DispatcherQueueTimer _rigTimer;
    private DateTimeOffset? _timeOn;
    private string _shownCall = "";
    private bool _isLogging;
    private bool _isLookingUp;
    private bool _updating;
    /// A QSO the primary logbook took and Wavelog didn't.
    private LoggedQso? _wavelogRetry;

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
        header.Children.Add(new TextBlock { Text = Loc.S("cwLogPane.logQSO"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(_destinationText, 1);
        header.Children.Add(_destinationText);
        return header;
    }

    private StackPanel BuildCallRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var lookup = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        lookup.Children.Add(new FontIcon { Glyph = "", FontSize = 12 });
        lookup.Children.Add(new TextBlock { Text = Loc.S("cwLogPane.lookup") });
        _lookupButton.Content = lookup;
        _lookupButton.Visibility = Visibility.Collapsed;
        ToolTipService.SetToolTip(_lookupButton, Loc.S("cwLogPane.lookTheCallUp"));
        AutomationProperties.SetName(_lookupButton, Loc.S("cwLogPane.lookup"));
        _lookupButton.Click += async (_, _) => await LookUpAsync();
        row.Children.Add(_lookupButton);

        ToolTipService.SetToolTip(_theirCallBox, Loc.S("cwLogPane.theStationYoureWorking"));
        AutomationProperties.SetName(_theirCallBox, Loc.S("common.theirCall"));
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
        timeOn.Children.Add(Secondary(Loc.S("cwLogPane.on")));
        timeOn.Children.Add(_timeOnText);
        var reset = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(6, 4, 6, 4) };
        ToolTipService.SetToolTip(reset, Loc.S("cwLogPane.setTheTimeOn"));
        AutomationProperties.SetName(reset, Loc.S("cwLogPane.setTheTimeOn"));
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
        AutomationProperties.SetName(_rstSentBox, Loc.S("cwLogPane.rSTSent"));
        AutomationProperties.SetName(_rstReceivedBox, Loc.S("cwLogPane.rSTReceived"));
        AutomationProperties.SetName(_nameBox, Loc.S("common.name"));
        AutomationProperties.SetName(_commentBox, Loc.S("common.comment"));
        var items = new FrameworkElement[] { Secondary(Loc.S("cwLogPane.rSTSent")), _rstSentBox, Secondary("rcvd"), _rstReceivedBox, _nameBox, _commentBox };
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
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ToolTipService.SetToolTip(_rigText, Loc.S("cwLogPane.loggedFromTheTransmitting"));
        row.Children.Add(_rigText);

        var result = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        result.Children.Add(_resultIcon);
        result.Children.Add(_resultRing);
        result.Children.Add(_resultText);
        Grid.SetColumn(result, 1);
        row.Children.Add(result);

        var retry = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        retry.Children.Add(new FontIcon { Glyph = "\uE72C", FontSize = 12 });
        retry.Children.Add(_retryText);
        _retryButton.Content = retry;
        _retryButton.Click += async (_, _) => await RetryWavelogAsync();
        _retryPanel.Children.Add(_retryButton);
        _retryDismissButton.Content = new FontIcon { Glyph = "\uE711", FontSize = 10 };
        _retryDismissButton.Click += (_, _) => SetWavelogRetry(null);
        _retryPanel.Children.Add(_retryDismissButton);
        Grid.SetColumn(_retryPanel, 2);
        row.Children.Add(_retryPanel);

        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        panel.Children.Add(new FontIcon { Glyph = "", FontSize = 14 });
        panel.Children.Add(new TextBlock { Text = Loc.S("cwLogPane.logQSO") });
        _logButton.Content = panel;
        _logButton.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        AutomationProperties.SetName(_logButton, Loc.S("cwLogPane.logQSO"));
        ToolTipService.SetToolTip(_logButton, Loc.S("cwLogPane.logThisQSOCtrl"));
        _logButton.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.L, Modifiers = VirtualKeyModifiers.Control });
        _logButton.Click += async (_, _) => await LogAsync();
        Grid.SetColumn(_logButton, 3);
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
        _lookupButton.IsEnabled = !_isLookingUp && call.Length > 0;
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
            text = Loc.F("cwLogPane.workedBeforeX", problem);
            brush = secondary;
        }
        else if (_worked.Worked.SummaryOf(call) is { } summary)
        {
            var last = summary.Last;
            text = Loc.F("cwLogPane.workedXLastX", summary.Count, last.Date.UtcDateTime, last.Band.ToLowerInvariant(), last.Mode);
            var newBand = _worked.Band is { } band && !summary.Bands.Contains(band.ToLowerInvariant());
            if (newBand)
            {
                text += Loc.F("cwLogPane.newOnX", _worked.Band);
            }
            brush = WorkedBrush(newBand ? WorkedStations.Status.OtherBand : WorkedStations.Status.ThisBand)!;
            tip = string.Join(", ", summary.Bands.Order());
        }
        else
        {
            text = Loc.S("cwLogPane.newStation");
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

        var program = LogbookPrograms.Current;
        var targets = new List<string>();
        if (program is not null) targets.Add(program.Name);
        if (AppSettings.WavelogEnabled) targets.Add("Wavelog");
        _destinationText.Text = targets.Count == 0 ? Loc.S("cwLogPane.noLogbookChooseOne") : Loc.F("cwLogPane.toX", string.Join(" + ", targets));
        _destinationText.Foreground = targets.Count == 0
            ? new SolidColorBrush(Microsoft.UI.Colors.DarkOrange)
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        _lookupButton.Visibility = program is { SupportsLookup: true } ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task LookUpAsync()
    {
        var call = NormalizedCall;
        if (call.Length == 0 || _isLookingUp)
        {
            return;
        }
        _isLookingUp = true;
        _lookupButton.IsEnabled = false;
        var problem = await QsoLogger.LookUpAsync(call);
        _isLookingUp = false;
        _lookupButton.IsEnabled = NormalizedCall.Length > 0;
        // A log in progress owns the result line.
        if (!_isLogging)
        {
            SetResult(problem is null ? ResultKind.Success : ResultKind.Failure,
                problem ?? Loc.F("cwLogPane.xSentToLog4OM", call));
        }
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
        if (!QsoLogger.HasLogbook)
        {
            SetResult(ResultKind.Failure, Loc.S("cwLogPane.noLogbookIsSelected"));
            return;
        }
        if (_link.Transmitter() is not { } tx)
        {
            SetResult(ResultKind.Failure, Loc.S("cwLogPane.notConnectedToThe"));
            return;
        }
        if (tx.FrequencyHz <= 0)
        {
            SetResult(ResultKind.Failure, Loc.S("cwLogPane.theTransmittingSidesFrequency"));
            return;
        }
        if (AdifMode.For(tx.Mode, tx.IsC4fm) is not { } mode)
        {
            SetResult(ResultKind.Failure, Loc.F("cwLogPane.cantLogInX", tx.Mode?.DisplayName() ?? Loc.S("common.anUnknownMode")));
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
        _retryButton.IsEnabled = false;
        SetResult(null, Loc.S("cwLogPane.logging"));
        var outcomes = await QsoLogger.LogAsync(qso);
        _isLogging = false;
        _logButton.IsEnabled = NormalizedCall.Length > 0;
        _retryButton.IsEnabled = true;
        Show(outcomes, qso);
    }

    /// One line for both logbooks: the primary's outcome first, then
    /// Wavelog's when it went wrong (or was a duplicate) — the Mac's
    /// CWLogPane.show.
    private void Show(QsoLogOutcomes outcomes, LoggedQso qso)
    {
        var call = qso.Call;
        var primaryName = LogbookPrograms.Current?.Name ?? Loc.S("cwLogPane.theLogbook");
        string? wavelogNote = null;
        var wavelogOk = true;
        switch (outcomes.Wavelog)
        {
            case QsoLogOutcome.AlreadyLogged:
                wavelogNote = Loc.S("cwLogPane.alreadyInWavelog");
                break;
            case QsoLogOutcome.SentUnconfirmed(var reason):
                wavelogNote = Loc.F("common.wavelogX", reason);
                wavelogOk = false;
                break;
            case QsoLogOutcome.Failed(var reason):
                wavelogNote = Loc.F("common.wavelogX", reason);
                wavelogOk = false;
                break;
        }
        string WithWavelog(string text) => wavelogNote is null ? text : $"{text} · {wavelogNote}";

        switch (outcomes.Primary)
        {
            case null:
                // Wavelog alone: Log QSO again is the retry.
                if (wavelogOk)
                {
                    SetResult(ResultKind.Success, WithWavelog(Loc.F("cwLogPane.xLoggedToWavelog", call)));
                    ClearIfStill(call);
                }
                else
                {
                    SetResult(ResultKind.Failure, WithWavelog(Loc.F("cwLogPane.xNotLogged", call)));
                }
                break;
            case QsoLogOutcome.Logged or QsoLogOutcome.AlreadyLogged:
                _worked.Reload();
                if (wavelogOk)
                {
                    var to = outcomes.Wavelog is null ? primaryName : Loc.F("cwLogPane.xAndWavelog", primaryName);
                    SetResult(ResultKind.Success, WithWavelog(Loc.F("cwLogPane.xLoggedToX", call, to)));
                    ClearIfStill(call);
                }
                else
                {
                    SetWavelogRetry(qso);
                    SetResult(ResultKind.Warning, WithWavelog(Loc.F("cwLogPane.xLoggedToX", call, primaryName)));
                }
                break;
            case QsoLogOutcome.SentUnconfirmed(var reason):
                if (!wavelogOk)
                {
                    SetWavelogRetry(qso);
                }
                SetResult(ResultKind.Warning, WithWavelog(Loc.F("cwLogPane.xCheckXBefore", reason, primaryName, call)));
                break;
            case QsoLogOutcome.Failed(var reason):
                // Nothing reached the primary: Log QSO again resends both,
                // and Wavelog's duplicate check absorbs a second copy there.
                SetResult(ResultKind.Failure, WithWavelog(reason));
                break;
        }
    }

    /// Only clears if nothing was typed for a new QSO meanwhile.
    private void ClearIfStill(string call)
    {
        if (NormalizedCall == call)
        {
            Clear();
        }
    }

    private void SetWavelogRetry(LoggedQso? qso)
    {
        _wavelogRetry = qso;
        _retryPanel.Visibility = qso is null ? Visibility.Collapsed : Visibility.Visible;
        if (qso is null)
        {
            return;
        }
        _retryText.Text = Loc.F("cwLogPane.retryWavelogX", qso.Call);
        AutomationProperties.SetName(_retryButton, Loc.F("cwLogPane.retryWavelogX", qso.Call));
        ToolTipService.SetToolTip(_retryButton, Loc.F("cwLogPane.sendXToWavelog", qso.Call, LogbookPrograms.Current?.Name ?? Loc.S("cwLogPane.theOtherLogbook")));
        AutomationProperties.SetName(_retryDismissButton, Loc.F("cwLogPane.dontSendXTo", qso.Call));
        ToolTipService.SetToolTip(_retryDismissButton, Loc.F("cwLogPane.dontSendXTo", qso.Call));
    }

    private async Task RetryWavelogAsync()
    {
        if (_wavelogRetry is not { } qso || _isLogging)
        {
            return;
        }
        _isLogging = true;
        _logButton.IsEnabled = false;
        _retryButton.IsEnabled = false;
        SetResult(null, Loc.S("cwLogPane.logging"));
        var outcome = await QsoLogger.LogToWavelogAsync(qso);
        _isLogging = false;
        _logButton.IsEnabled = NormalizedCall.Length > 0;
        _retryButton.IsEnabled = true;
        switch (outcome)
        {
            case QsoLogOutcome.Logged or QsoLogOutcome.AlreadyLogged:
                SetWavelogRetry(null);
                SetResult(ResultKind.Success, outcome is QsoLogOutcome.Logged ? Loc.F("cwLogPane.xLoggedToWavelog", qso.Call) : Loc.F("cwLogPane.xWasAlreadyIn", qso.Call));
                ClearIfStill(qso.Call);
                break;
            case QsoLogOutcome.SentUnconfirmed(var reason):
                SetResult(ResultKind.Failure, Loc.F("common.wavelogX", reason));
                break;
            case QsoLogOutcome.Failed(var reason):
                SetResult(ResultKind.Failure, Loc.F("common.wavelogX", reason));
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

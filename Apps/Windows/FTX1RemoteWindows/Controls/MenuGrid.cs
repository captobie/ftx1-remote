using System.Diagnostics;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace FTX1RemoteWindows.Controls;

/// Port of the Mac's MENU grid (Sources/FTX1Core/UI/MenuPageView.swift):
/// 7×4 buttons mirroring the FTX-1's own MENU pages, each wired to the raw
/// CAT command the Mac already uses (CommandQueue.swift for the writes,
/// HubService.refreshSlowTier for the reads), sent straight to rigctld.
/// Only page 1 (SSB) is ported so far; CW and FM/C4FM follow as their own
/// steps, so the page-nav button is a disabled placeholder for now.
///
/// Built in code rather than XAML: every cell is a label plus a CAT
/// mapping, and keeping the two side by side is easier to check against
/// MenuPageView than 28 XAML blocks with the wiring elsewhere.
///
/// Button kinds follow the Mac: on/off settings flip on a tap, small choice
/// sets (IPO/AMP, AGC, D-PEAK, ANT) cycle to the next value on a tap, and
/// wide numeric ranges open a flyout stepper (the Mac's popover Stepper),
/// which sends on every step. RF POWER's flyout is a slider that sends on
/// release, like the main window's power slider.
public sealed class MenuGrid : UserControl
{
    private const int Columns = 7;
    private const int Rows = 4;

    /// The rig's own MENU display shows setting values in orange — the
    /// Mac's default ButtonValueColor (not configurable here yet; that's
    /// part of the Settings step).
    private static readonly Brush ValueBrush = new SolidColorBrush(Colors.Orange);
    private static readonly FontFamily ValueFont = new("Consolas");

    private readonly RigState _state;
    private readonly Grid _grid = new() { ColumnSpacing = 6, RowSpacing = 6 };
    /// Re-renders every cell's value line (and open flyouts) from _state.
    private readonly List<Action> _refreshers = [];

    private RigctldClient? _client;

    /// Bumped before and after every command. A slow-tier read that saw it
    /// change was racing that command, so it's thrown away rather than
    /// overwriting the optimistic value with a stale one — the Mac's
    /// commandGeneration check in refreshSlowTier.
    private int _commandGeneration;

    /// A command or read failed; MainWindow shows it on its status line.
    public event Action<string>? StatusMessage;

    /// RF POWER sent a new level (0.0-1.0), so the main window's power
    /// slider can move and hold like it does for its own sends.
    public event Action<double>? PowerLevelSent;

    public MenuGrid(RigState state)
    {
        _state = state;
        for (var c = 0; c < Columns; c++)
        {
            _grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }
        for (var r = 0; r < Rows; r++)
        {
            _grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }
        Content = _grid;
        BuildSsbPage();
        RefreshLabels();
    }

    /// Set on connect, null on disconnect. The grid is disabled while
    /// there's no client.
    public RigctldClient? Client
    {
        get => _client;
        set
        {
            _client = value;
            IsEnabled = value is not null;
        }
    }

    /// Clears the page's values so a new session doesn't show the previous
    /// one's as current until the first read lands.
    public void ClearState()
    {
        _state.DisplayLevel = null;
        _state.DisplayPeak = null;
        _state.DisplayMarker = null;
        _state.DisplayContrast = null;
        _state.DisplayDimmer = null;
        _state.MoxEnabled = null;
        _state.AttEnabled = null;
        _state.PreampMode = null;
        _state.DnfEnabled = null;
        _state.AgcMode = null;
        _state.MicEqEnabled = null;
        _state.ProcLevel = null;
        _state.TunerEnabled = null;
        _state.NbLevel = null;
        _state.DnrLevel = null;
        _state.AntSelect = null;
        _state.MicGain = null;
        _state.AmcLevel = null;
        _state.VoxEnabled = null;
        _state.VoxGain = null;
        _state.VoxDelayMs = null;
        RefreshLabels();
    }

    public void RefreshLabels()
    {
        foreach (var refresh in _refreshers)
        {
            refresh();
        }
    }

    // SSB page (page 1/3). Item numbers are the rig's own, left to right,
    // top to bottom; see MenuPageView.menuButton(for:)'s doc comment for
    // how each one was worked out and hardware-confirmed on the Mac.

    private void BuildSsbPage()
    {
        // 1: the rig's page-select button. A no-op on the Mac too.
        AddCell(1, "PAGE 1/3", () => "SSB");

        AddStepper(2, "D-LEVEL", () => DisplayLevelLabel(_state.DisplayLevel),
            current: () => _state.DisplayLevel ?? 0, min: -30, max: 30, step: 0.5,
            valueLabel: db => DisplayLevelLabel(db),
            set: db => Send("D-LEVEL", () => _state.DisplayLevel = db,
                c => c.SetSpectrumScopeLevelAsync(db)));

        // "SS"'s PEAK/MARKER sub-functions pack P3 ahead of four fixed "0"s.
        AddCycle(3, "D-PEAK", () => _state.DisplayPeak is { } p ? $"LV{p + 1}" : "—", () =>
        {
            var next = ((_state.DisplayPeak ?? 0) + 1) % 5;
            Send("D-PEAK", () => _state.DisplayPeak = next, c => c.SetRawPackedDigitAsync("SS01", next, 4));
        });

        AddToggle(4, "D-MARKER", () => _state.DisplayMarker, on =>
            Send("D-MARKER", () => _state.DisplayMarker = on, c => c.SetRawPackedDigitAsync("SS02", on ? 1 : 0, 4)));

        // No CAT command exists for D-COLOR (checked the whole manual).
        AddDisabled(5, "D-COLOR");

        // "DA" sets contrast and both brightnesses in one command, so each
        // stepper reads the current triple first and writes the other two
        // back unchanged (CommandQueue.swift's .setDisplayContrast).
        AddStepper(6, "D-CONTRAST", () => IntLabel(_state.DisplayContrast),
            current: () => _state.DisplayContrast ?? 10, min: 0, max: 20, step: 1,
            valueLabel: v => $"{v:0}",
            set: v => Send("D-CONTRAST", () => _state.DisplayContrast = (int)v, async c =>
            {
                var current = await ReadOrNull(() => c.GetDisplaySettingsAsync());
                await c.SetDisplaySettingsAsync((int)v, current?.Brightness ?? 10, current?.LedBrightness ?? 10);
            }));

        AddStepper(7, "DIMMER", () => IntLabel(_state.DisplayDimmer),
            current: () => _state.DisplayDimmer ?? 10, min: 0, max: 20, step: 1,
            valueLabel: v => $"{v:0}",
            set: v => Send("DIMMER", () => _state.DisplayDimmer = (int)v, async c =>
            {
                var current = await ReadOrNull(() => c.GetDisplaySettingsAsync());
                await c.SetDisplaySettingsAsync(current?.Contrast ?? 10, (int)v, current?.LedBrightness ?? 10);
            }));

        AddMox(8);

        AddToggle(9, "ATT", () => _state.AttEnabled, on =>
            Send("ATT", () => _state.AttEnabled = on, c => c.SetRawBoolAsync("RA0", on)));

        // "PA0": P1 fixed to HF/50, P2 = IPO/AMP1/AMP2.
        AddCycle(10, "IPO/AMP", () => PreampLabel(_state.PreampMode), () =>
        {
            var next = ((_state.PreampMode ?? 0) + 1) % 3;
            Send("IPO/AMP", () => _state.PreampMode = next, c => c.SetRawIntAsync("PA0", next, 1));
        });

        AddToggle(11, "DNF", () => _state.DnfEnabled, on =>
            Send("DNF", () => _state.DnfEnabled = on, c => c.SetRawBoolAsync("BC0", on)));

        // The read can report AUTO's sub-states (5/6); the set takes 0-4
        // only, so the cycle collapses them to AUTO before stepping.
        AddCycle(12, "AGC", () => AgcLabel(_state.AgcMode), () =>
        {
            var next = (AgcCollapsedMode(_state.AgcMode) + 1) % 5;
            Send("AGC", () => _state.AgcMode = next, c => c.SetRawIntAsync("GT0", next, 1));
        });

        // "PR1": plain 0/1 — the manual's 1/2 is wrong (hardware-confirmed).
        AddToggle(13, "MIC EQ", () => _state.MicEqEnabled, on =>
            Send("MIC EQ", () => _state.MicEqEnabled = on, c => c.SetRawBoolAsync("PR1", on)));

        AddStepper(14, "PROC LEVEL", () => OffOrNumber(_state.ProcLevel),
            current: () => _state.ProcLevel ?? 50, min: 0, max: 100, step: 1,
            valueLabel: v => OffOrNumber((int)v),
            set: v => Send("PROC LEVEL", () => _state.ProcLevel = (int)v, c => c.SetRawIntAsync("PL", (int)v, 3)));

        AddAntennaTune(15);

        // "AC10x": P1=1 is what works on this rig's internal tuner, not the
        // manual's P1=0 (hardware-confirmed on the Mac; don't "fix" it).
        AddToggle(16, "TUNER", () => _state.TunerEnabled, on =>
            Send("TUNER", () => _state.TunerEnabled = on, c => c.SetRawBoolAsync("AC10", on)));

        // 17: no function on this page on the rig; left empty.

        AddStepper(18, "NB", () => OffOrNumber(_state.NbLevel),
            current: () => _state.NbLevel ?? 5, min: 0, max: 10, step: 1,
            valueLabel: v => OffOrNumber((int)v),
            set: v => Send("NB", () => _state.NbLevel = (int)v, c => c.SetRawIntAsync("NL0", (int)v, 3)));

        AddStepper(19, "DNR", () => OffOrNumber(_state.DnrLevel),
            current: () => _state.DnrLevel ?? 5, min: 0, max: 10, step: 1,
            valueLabel: v => OffOrNumber((int)v),
            set: v => Send("DNR", () => _state.DnrLevel = (int)v, c => c.SetRawIntAsync("RL0", (int)v, 2)));

        // No mnemonic: Table 3's HF ANT SELECT through "EX" 03/07/04.
        AddCycle(20, "ANT", () => _state.AntSelect switch { 0 => "ANT1", 1 => "ANT2", _ => "—" }, () =>
        {
            var next = ((_state.AntSelect ?? 0) + 1) % 2;
            Send("ANT", () => _state.AntSelect = next, c => c.SetMenuItemAsync(3, 7, 4, next.ToString()));
        });

        // Works ("TS"), but disabled on the Mac too: nobody knows what it's for.
        AddDisabled(21, "TXW");

        AddRfPower(22);

        AddStepper(23, "MIC GAIN", () => IntLabel(_state.MicGain),
            current: () => _state.MicGain ?? 50, min: 0, max: 100, step: 1,
            valueLabel: v => $"{v:0}",
            set: v => Send("MIC GAIN", () => _state.MicGain = (int)v, c => c.SetRawIntAsync("MG", (int)v, 3)));

        AddStepper(24, "AMC LEVEL", () => IntLabel(_state.AmcLevel),
            current: () => _state.AmcLevel ?? 50, min: 1, max: 100, step: 1,
            valueLabel: v => $"{v:0}",
            set: v => Send("AMC LEVEL", () => _state.AmcLevel = (int)v, c => c.SetRawIntAsync("AO", (int)v, 3)));

        AddToggle(25, "VOX", () => _state.VoxEnabled, on =>
            Send("VOX", () => _state.VoxEnabled = on, c => c.SetRawBoolAsync("VX", on)));

        AddStepper(26, "VOX GAIN", () => IntLabel(_state.VoxGain),
            current: () => _state.VoxGain ?? 50, min: 0, max: 100, step: 1,
            valueLabel: v => $"{v:0}",
            set: v => Send("VOX GAIN", () => _state.VoxGain = (int)v, c => c.SetRawIntAsync("VG", (int)v, 3)));

        // Steps through RigDelayCode's 0-33 codes, shown in ms.
        AddStepper(27, "VOX DELAY", () => _state.VoxDelayMs is { } ms ? $"{ms} ms" : "—",
            current: () => RigDelayCode.Code(_state.VoxDelayMs ?? 300) ?? 6, min: 0, max: RigDelayCode.MaxCode, step: 1,
            valueLabel: code => $"{RigDelayCode.Milliseconds((int)code)} ms",
            set: code =>
            {
                if (RigDelayCode.Milliseconds((int)code) is { } ms)
                {
                    Send("VOX DELAY", () => _state.VoxDelayMs = ms, c => c.SetRawIntAsync("VD", (int)code, 2));
                }
            });

        // 28: "▶ CW" page nav on the rig and the Mac.
        var next = AddCell(28, "▶", () => "CW", colorize: false);
        next.IsEnabled = false;
        ToolTipService.SetToolTip(next, "The CW page isn't ported to Windows yet");
    }

    /// Reads every SSB-page setting, one best-effort read each (a failure
    /// keeps the last value), then applies them all at once — unless a
    /// command landed meanwhile, in which case the whole snapshot is
    /// dropped (see _commandGeneration). Called from MainWindow's slow poll
    /// tier; same reads as HubService.refreshSlowTier.
    public async Task RefreshFromRigAsync(RigctldClient client)
    {
        var generationAtStart = _commandGeneration;

        var displaySettings = await ReadOrNull(() => client.GetDisplaySettingsAsync());
        var displayLevel = await ReadOrNull(() => client.GetSpectrumScopeLevelAsync());
        var displayPeak = await ReadOrNull(() => client.GetRawDigitAsync("SS01"));
        var displayMarker = await ReadOrNull(() => client.GetRawBoolAsync("SS02"));
        var mox = await ReadOrNull(() => client.GetRawBoolAsync("MX"));
        var att = await ReadOrNull(() => client.GetRawBoolAsync("RA0"));
        var preamp = await ReadOrNull(() => client.GetRawIntAsync("PA0"));
        var dnf = await ReadOrNull(() => client.GetRawBoolAsync("BC0"));
        // "GT0"/"PR1" get no reply at all in C4FM, and each unanswered read
        // costs the 1 s timeout plus a reconnect. The Mac skips them in
        // C4FM; this app's RigMode has no C4FM (it reads back as null), so
        // they're skipped whenever the mode isn't one we recognize.
        int? agc = null;
        bool? micEq = null;
        if (_state.Mode is not null)
        {
            agc = await ReadOrNull(() => client.GetRawIntAsync("GT0"));
            micEq = await ReadOrNull(() => client.GetRawBoolAsync("PR1"));
        }
        var procLevel = await ReadOrNull(() => client.GetRawIntAsync("PL"));
        var tuner = await ReadOrNull(() => client.GetTunerEnabledAsync());
        var nbLevel = await ReadOrNull(() => client.GetRawIntAsync("NL0"));
        var dnrLevel = await ReadOrNull(() => client.GetRawIntAsync("RL0"));
        var antSelectRaw = await ReadStringOrNull(() => client.GetMenuItemAsync(3, 7, 4));
        var micGain = await ReadOrNull(() => client.GetRawIntAsync("MG"));
        var amcLevel = await ReadOrNull(() => client.GetRawIntAsync("AO"));
        var vox = await ReadOrNull(() => client.GetRawBoolAsync("VX"));
        var voxGain = await ReadOrNull(() => client.GetRawIntAsync("VG"));
        var voxDelayCode = await ReadOrNull(() => client.GetRawIntAsync("VD"));

        if (generationAtStart != _commandGeneration || !ReferenceEquals(client, _client))
        {
            return;
        }

        _state.DisplayContrast = displaySettings?.Contrast ?? _state.DisplayContrast;
        _state.DisplayDimmer = displaySettings?.Brightness ?? _state.DisplayDimmer;
        _state.DisplayLevel = displayLevel ?? _state.DisplayLevel;
        _state.DisplayPeak = displayPeak ?? _state.DisplayPeak;
        _state.DisplayMarker = displayMarker ?? _state.DisplayMarker;
        _state.MoxEnabled = mox ?? _state.MoxEnabled;
        _state.AttEnabled = att ?? _state.AttEnabled;
        _state.PreampMode = preamp ?? _state.PreampMode;
        _state.DnfEnabled = dnf ?? _state.DnfEnabled;
        _state.AgcMode = agc ?? _state.AgcMode;
        _state.MicEqEnabled = micEq ?? _state.MicEqEnabled;
        _state.ProcLevel = procLevel ?? _state.ProcLevel;
        _state.TunerEnabled = tuner ?? _state.TunerEnabled;
        _state.NbLevel = nbLevel ?? _state.NbLevel;
        _state.DnrLevel = dnrLevel ?? _state.DnrLevel;
        _state.AntSelect = int.TryParse(antSelectRaw, out var ant) ? ant : _state.AntSelect;
        _state.MicGain = micGain ?? _state.MicGain;
        _state.AmcLevel = amcLevel ?? _state.AmcLevel;
        _state.VoxEnabled = vox ?? _state.VoxEnabled;
        _state.VoxGain = voxGain ?? _state.VoxGain;
        _state.VoxDelayMs = voxDelayCode is { } code ? RigDelayCode.Milliseconds(code) ?? _state.VoxDelayMs : _state.VoxDelayMs;
        RefreshLabels();
    }

    private static async Task<T?> ReadOrNull<T>(Func<Task<T?>> read) where T : struct
    {
        try
        {
            return await read();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"menu-grid: read failed: {ex.Message}");
            return null;
        }
    }

    private static async Task<string?> ReadStringOrNull(Func<Task<string?>> read)
    {
        try
        {
            return await read();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"menu-grid: read failed: {ex.Message}");
            return null;
        }
    }

    /// Applies the new value at once (so the button updates without
    /// waiting for the next slow poll, like the Mac's applyOptimistically),
    /// then sends it. A failed send is reported; the next poll puts the
    /// rig's real value back.
    private async void Send(string what, Action applyOptimistic, Func<RigctldClient, Task> command)
    {
        if (_client is not { } client)
        {
            return;
        }
        _commandGeneration++;
        applyOptimistic();
        RefreshLabels();
        try
        {
            await command(client);
        }
        catch (Exception ex)
        {
            StatusMessage?.Invoke($"{what} failed: {ex.Message}");
        }
        _commandGeneration++;
    }

    // Transmit-capable buttons. Both check TransmitGate on click as well as
    // being disabled while it would block, same as PTT and the Mac's
    // HubService.send re-check.

    /// 8: MOX. Only the "on" direction is gated, so it stays clickable
    /// while MOX is on — it's one way to unkey.
    private void AddMox(int item)
    {
        var button = AddCell(item, "MOX", () => OnOff(_state.MoxEnabled));
        button.Click += (_, _) =>
        {
            var on = !(_state.MoxEnabled ?? false);
            if (on && GateReason(TransmitAction.MoxOn) is { } reason)
            {
                Debug.WriteLine($"transmit-gate: blocked MOX on ({reason}) at {_state.FrequencyHz} Hz");
                StatusMessage?.Invoke(reason);
                return;
            }
            Send("MOX", () => _state.MoxEnabled = on, c => c.SetMoxAsync(on));
        };
        _refreshers.Add(() =>
        {
            var reason = _state.MoxEnabled == true ? null : GateReason(TransmitAction.MoxOn);
            button.IsEnabled = reason is null;
            ToolTipService.SetToolTip(button, reason);
        });
    }

    /// 15: ANT TUNE, momentary ("AC103", tuning start). It keys the rig to
    /// tune, hence the gate.
    private void AddAntennaTune(int item)
    {
        var button = AddCell(item, "ANT TUNE", () => "PUSH");
        button.Click += (_, _) =>
        {
            if (GateReason(TransmitAction.TriggerAntennaTune) is { } reason)
            {
                Debug.WriteLine($"transmit-gate: blocked ANT TUNE ({reason}) at {_state.FrequencyHz} Hz");
                StatusMessage?.Invoke(reason);
                return;
            }
            Send("ANT TUNE", () => { }, c => c.SendRawFireAndForgetAsync("AC103"));
        };
        _refreshers.Add(() =>
        {
            var reason = GateReason(TransmitAction.TriggerAntennaTune);
            button.IsEnabled = reason is null;
            ToolTipService.SetToolTip(button, reason);
        });
    }

    private string? GateReason(TransmitAction action) =>
        TransmitGate.BlockReason(action, AppSettings.TransmitEnabled, _state.FrequencyHz);

    /// 22: RF POWER (the "RFPOWER" level, 0-100%). A slider rather than a
    /// stepper, as on the Mac: sends once on release (or per key press),
    /// not per drag tick.
    private void AddRfPower(int item)
    {
        var button = AddCell(item, "RF POWER", () => RfPowerLabel(_state.PowerLevel));
        var valueText = new TextBlock { FontFamily = ValueFont, HorizontalAlignment = HorizontalAlignment.Center };
        var slider = new Slider { Minimum = 0, Maximum = 100, Width = 200 };
        var dragging = false;
        var suppress = false;

        void SendLevel()
        {
            var level = slider.Value / 100.0;
            PowerLevelSent?.Invoke(level);
            Send("RF POWER", () => _state.PowerLevel = level, c => c.SetPowerLevelAsync(level));
        }

        slider.ValueChanged += (_, e) =>
        {
            valueText.Text = RfPowerLabel(e.NewValue / 100.0);
            if (!suppress && !dragging)
            {
                SendLevel();
            }
        };
        // The Thumb marks its own pointer events handled, hence
        // handledEventsToo — same as MainWindow's PowerSlider.
        slider.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => dragging = true), true);
        void Done(object sender, PointerRoutedEventArgs e)
        {
            if (!dragging)
            {
                return;
            }
            dragging = false;
            if (_state.PowerLevel is { } rig && Math.Abs(rig * 100 - slider.Value) < 0.05)
            {
                return;
            }
            SendLevel();
        }
        slider.AddHandler(PointerReleasedEvent, new PointerEventHandler(Done), true);
        slider.AddHandler(PointerCaptureLostEvent, new PointerEventHandler(Done), true);

        var flyout = new Flyout
        {
            Content = new StackPanel { Spacing = 4, Children = { valueText, slider } },
        };
        flyout.Opening += (_, _) =>
        {
            suppress = true;
            slider.Value = (_state.PowerLevel ?? 0) * 100;
            suppress = false;
            valueText.Text = RfPowerLabel(slider.Value / 100.0);
        };
        button.Flyout = flyout;
    }

    // Cell builders.

    /// A button with the rig's two-line label: the function name on top
    /// and its current setting below in orange (the rig's own MENU colors).
    private Button AddCell(int item, string top, Func<string> bottom, bool colorize = true)
    {
        var topText = new TextBlock { Text = top, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center };
        var bottomText = new TextBlock { FontFamily = ValueFont, FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center };
        if (colorize)
        {
            bottomText.Foreground = ValueBrush;
        }
        var button = new Button
        {
            Content = new StackPanel { Spacing = 2, Children = { topText, bottomText } },
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(4, 8, 4, 8),
        };
        Grid.SetRow(button, (item - 1) / Columns);
        Grid.SetColumn(button, (item - 1) % Columns);
        _grid.Children.Add(button);
        _refreshers.Add(() => bottomText.Text = bottom());
        return button;
    }

    private void AddToggle(int item, string top, Func<bool?> get, Action<bool> set)
    {
        var button = AddCell(item, top, () => OnOff(get()));
        button.Click += (_, _) => set(!(get() ?? false));
    }

    private void AddCycle(int item, string top, Func<string> label, Action next)
    {
        var button = AddCell(item, top, label);
        button.Click += (_, _) => next();
    }

    /// The Mac's popover Stepper: − value + in a flyout. Each step sends at
    /// once (holding a button repeats). <paramref name="current"/> falls
    /// back to the Mac's default while the setting hasn't been read yet.
    private void AddStepper(int item, string top, Func<string> label, Func<double> current,
        double min, double max, double step, Func<double, string> valueLabel, Action<double> set)
    {
        var button = AddCell(item, top, label);
        var valueText = new TextBlock
        {
            FontFamily = ValueFont,
            MinWidth = 90,
            TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var minus = new RepeatButton { Content = "−", Width = 40, Delay = 400, Interval = 120 };
        var plus = new RepeatButton { Content = "+", Width = 40, Delay = 400, Interval = 120 };

        void Update()
        {
            var value = current();
            valueText.Text = valueLabel(value);
            minus.IsEnabled = value > min;
            plus.IsEnabled = value < max;
        }

        void Step(double delta)
        {
            // Rounded to the step grid so repeated 0.5 dB steps can't drift.
            var value = Math.Clamp(Math.Round((current() + delta) / step) * step, min, max);
            if (value != current())
            {
                set(value);
            }
            Update();
        }

        minus.Click += (_, _) => Step(-step);
        plus.Click += (_, _) => Step(step);

        var flyout = new Flyout
        {
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { minus, valueText, plus } },
        };
        flyout.Opening += (_, _) => Update();
        button.Flyout = flyout;
        _refreshers.Add(Update);
    }

    /// Known rig label, but not wired (no CAT command, or deprioritized).
    private void AddDisabled(int item, string top)
    {
        var button = AddCell(item, top, () => "—", colorize: false);
        button.IsEnabled = false;
    }

    // Labels, same text as MenuPageView's.

    private static string OnOff(bool? on) => on switch { true => "ON", false => "OFF", null => "—" };

    private static string IntLabel(int? value) => value?.ToString() ?? "—";

    /// PROC LEVEL/NB/DNR read 0 as "OFF".
    private static string OffOrNumber(int? value) => value switch { null => "—", 0 => "OFF", _ => value.Value.ToString() };

    private static string DisplayLevelLabel(double? db) =>
        db is { } v ? v.ToString("+0.0;-0.0;+0.0", System.Globalization.CultureInfo.InvariantCulture) + " dB" : "—";

    private static string RfPowerLabel(double? level) => level is { } l ? $"{Math.Round(l * 100):0}W" : "—";

    private static string PreampLabel(int? mode) => mode switch { 0 => "IPO", 1 => "AMP1", 2 => "AMP2", _ => "—" };

    private static string AgcLabel(int? mode) => mode switch
    {
        0 => "OFF",
        1 => "FAST",
        2 => "MID",
        3 => "SLOW",
        4 or 5 or 6 => "AUTO",
        _ => "—",
    };

    private static int AgcCollapsedMode(int? mode) => mode switch
    {
        5 or 6 => 4,
        >= 0 and <= 4 => mode.Value,
        _ => 0,
    };
}

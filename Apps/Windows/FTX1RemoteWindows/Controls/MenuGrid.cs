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
/// All three pages (SSB, CW, FM/C4FM) are ported. Buttons that need
/// features this app doesn't have yet are disabled placeholders: CW's
/// PLAY/RECORD (audio recorder), FM's APRS S.LIST/M.LIST (APRS decoding)
/// and FM's six Deep Settings buttons (step 8 of the parity plan).
///
/// Only the page on screen is read in the slow poll tier, and switching
/// pages reads the new one at once — so the tier doesn't grow with every
/// page. The Mac reads all pages every tier; nothing here depends on a
/// hidden page's values (Enable Transmit's force-unkey sends MOX off
/// unconditionally).
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
public enum MenuPage
{
    Ssb,
    Cw,
    Fm,
}

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

    private readonly SelectorBar _pageBar = new();
    private MenuPage _page = MenuPage.Ssb;
    /// Keeps the poll's read and a page switch's read from running at
    /// once; a request that arrives mid-read runs when that one finishes.
    private bool _refreshInFlight;
    private bool _refreshPending;

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

    /// HOME wants the Main VFO tuned here. MainWindow owns frequency sets,
    /// since each one also has to reset VFO swap tracking.
    public event Action<long>? FrequencyRequested;

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
        // The Mac's segmented page picker.
        foreach (var (page, name) in new[] { (MenuPage.Ssb, "SSB"), (MenuPage.Cw, "CW"), (MenuPage.Fm, "FM/C4FM") })
        {
            _pageBar.Items.Add(new SelectorBarItem { Text = name, Tag = page });
        }
        _pageBar.SelectedItem = _pageBar.Items[0];
        _pageBar.SelectionChanged += (_, _) =>
        {
            if (_pageBar.SelectedItem is { Tag: MenuPage page })
            {
                ShowPage(page);
            }
        };
        Content = new StackPanel { Spacing = 8, Children = { _pageBar, _grid } };
        BuildPage();
    }

    /// Rebuilds the cells for <paramref name="page"/> and reads its
    /// settings now rather than waiting for the next slow tier. Reached
    /// from both the page bar and the ◀/▶ buttons, which keep each other
    /// in step.
    private void ShowPage(MenuPage page)
    {
        if (page == _page)
        {
            return;
        }
        _page = page;
        if (_pageBar.Items.FirstOrDefault(i => i.Tag is MenuPage p && p == page) is { } item
            && !ReferenceEquals(_pageBar.SelectedItem, item))
        {
            _pageBar.SelectedItem = item;
        }
        BuildPage();
        if (_client is { } client)
        {
            _ = RefreshFromRigAsync(client);
        }
    }

    private void BuildPage()
    {
        _grid.Children.Clear();
        _refreshers.Clear();
        switch (_page)
        {
            case MenuPage.Ssb:
                BuildSsbPage();
                break;
            case MenuPage.Cw:
                BuildCwPage();
                break;
            case MenuPage.Fm:
                BuildFmPage();
                break;
        }
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
        _state.MoniLevel = null;
        _state.KeyerEnabled = null;
        _state.BreakIn = null;
        _state.CwSpeedWpm = null;
        _state.CwPitchHz = null;
        _state.BkDelayMs = null;
        _state.CwSpot = null;
        _state.RepeaterShiftMode = null;
        _state.AprsBeaconType = null;
        _state.FmChannelStep = null;
        _state.SquelchType = null;
        _state.CtcssToneIndex = null;
        _state.DcsCodeIndex = null;
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

        AddNav(28, "▶", MenuPage.Cw);
    }

    // CW page (page 2/3). Items 3-7, 15-18 and 23-27 have no function on
    // this page on the rig and are left empty (the Mac's hiddenCWItems).

    private void BuildCwPage()
    {
        AddCell(1, "PAGE 2/3", () => "CW");

        // "ML1" is MONI's level; "ML0" (its on/off) isn't used — a level of
        // 0 already means off on the rig, so 0 shows as OFF.
        AddStepper(2, "MONI LEVEL", () => OffOrNumber(_state.MoniLevel),
            current: () => _state.MoniLevel ?? 50, min: 0, max: 100, step: 1,
            valueLabel: v => OffOrNumber((int)v),
            set: v => Send("MONI LEVEL", () => _state.MoniLevel = (int)v, c => c.SetRawIntAsync("ML1", (int)v, 3)));

        AddToggle(8, "KEYER", () => _state.KeyerEnabled, on =>
            Send("KEYER", () => _state.KeyerEnabled = on, c => c.SetRawBoolAsync("KR", on)));

        AddToggle(9, "BK-IN", () => _state.BreakIn, on =>
            Send("BK-IN", () => _state.BreakIn = on, c => c.SetRawBoolAsync("BI", on)));

        AddStepper(10, "CW SPEED", () => _state.CwSpeedWpm is { } wpm ? $"{wpm} WPM" : "—",
            current: () => _state.CwSpeedWpm ?? 20, min: 4, max: 60, step: 1,
            valueLabel: v => $"{v:0} WPM",
            set: v => Send("CW SPEED", () => _state.CwSpeedWpm = (int)v, c => c.SetRawIntAsync("KS", (int)v, 3)));

        // "KP" is 00-75: 10 Hz steps above 300 Hz.
        AddStepper(11, "CW PITCH", () => _state.CwPitchHz is { } hz ? $"{hz} Hz" : "—",
            current: () => _state.CwPitchHz ?? 700, min: 300, max: 1050, step: 10,
            valueLabel: v => $"{v:0} Hz",
            set: v => Send("CW PITCH", () => _state.CwPitchHz = (int)v, c => c.SetRawIntAsync("KP", ((int)v - 300) / 10, 2)));

        // "SD" uses the same 00-33 code as VOX DELAY's "VD".
        AddStepper(12, "BK-DELAY", () => _state.BkDelayMs is { } ms ? $"{ms} ms" : "—",
            current: () => RigDelayCode.Code(_state.BkDelayMs ?? 300) ?? 6, min: 0, max: RigDelayCode.MaxCode, step: 1,
            valueLabel: code => $"{RigDelayCode.Milliseconds((int)code)} ms",
            set: code =>
            {
                if (RigDelayCode.Milliseconds((int)code) is { } ms)
                {
                    Send("BK-DELAY", () => _state.BkDelayMs = ms, c => c.SetRawIntAsync("SD", (int)code, 2));
                }
            });

        // Momentary: "ZI0" zero-ins the MAIN side. Receive-only, so not
        // transmit-gated (nor is it on the Mac).
        var zin = AddCell(13, "ZIN", () => "PUSH");
        zin.Click += (_, _) => Send("ZIN", () => { }, c => c.SendRawFireAndForgetAsync("ZI0"));

        AddToggle(14, "CW SPOT", () => _state.CwSpot, on =>
            Send("CW SPOT", () => _state.CwSpot = on, c => c.SetRawBoolAsync("CS", on)));

        // CW MESSAGE memory: wired on the Mac but unreliable there, so it's
        // a disabled placeholder on both. Its play ("KY1") must pass
        // TransmitGate's PlayCwMessage check if it's ever enabled.
        AddDisabled(19, "MESSAGE");

        // On the Mac these play back and record the app's own captured
        // audio (AudioRecorder, Recordings window); this app has no
        // recorder yet.
        AddDisabled(20, "PLAY", "Recording playback isn't built on Windows yet");
        AddDisabled(21, "RECORD", "Audio recording isn't built on Windows yet");

        AddNav(22, "◀", MenuPage.Ssb);
        AddNav(28, "▶", MenuPage.Fm);
    }

    // FM/C4FM page (page 3/3). Items 4, 5, 16 and 17 have no function on
    // this page on the rig and are left empty (the Mac's hiddenFMItems).

    private void BuildFmPage()
    {
        AddCell(1, "PAGE 3/3", () => "FM");

        // Opens a DTMF entry screen on the rig — no CAT path to it, and
        // sending DTMF transmits. A single word on the rig, like HOME.
        AddWord(2, "DTMF", enabled: false);

        // No CAT command anywhere for these (manual, Table 3, hamlib); see
        // MenuPageView's doc comment.
        AddDisabled(3, "T-CALL");

        // "OS0": fixed MAIN-side P1.
        AddCycle(6, "RPT SHIFT", () => RepeaterShiftLabel(_state.RepeaterShiftMode), () =>
        {
            var next = ((_state.RepeaterShiftMode ?? 0) + 1) % 4;
            Send("RPT SHIFT", () => _state.RepeaterShiftMode = next, c => c.SetRawIntAsync("OS0", next, 1));
        });

        AddDisabled(7, "REV");
        AddDisabled(8, "DG-ID TX");
        AddDisabled(9, "DG-ID RX");
        AddDisabled(10, "HRI MODE");

        // The station/message lists come from the Mac's own APRS decoder
        // (off the audio); this app doesn't decode APRS yet.
        AddDisabledPair(11, "APRS", "S.LIST", "APRS decoding isn't built on Windows yet");
        AddDisabledPair(12, "APRS", "M.LIST", "APRS decoding isn't built on Windows yet");

        // A plain rig setting over CAT (Table 3's BEACON TYPE, "EX" 07/01/01),
        // so it works without APRS decoding.
        AddCycle(13, "BEACON", () => _state.AprsBeaconType switch { 0 => "OFF", 1 => "AUTO", 2 => "SMART", _ => "—" }, () =>
        {
            var next = ((_state.AprsBeaconType ?? 0) + 1) % 3;
            Send("BEACON", () => _state.AprsBeaconType = next, c => c.SetMenuItemAsync(7, 1, 1, next.ToString()));
        });

        // Momentary "send beacon now": no mnemonic and no Table 3 entry, and
        // it transmits, so the Mac never probed for one either.
        AddDisabled(14, "BCN-TX");

        // Table 3's FM CH STEP, "EX" 03/06/06.
        AddCycle(15, "CH STEP", () => FmChannelStepLabel(_state.FmChannelStep), () =>
        {
            var next = ((_state.FmChannelStep ?? 0) + 1) % 6;
            Send("CH STEP", () => _state.FmChannelStep = next, c => c.SetMenuItemAsync(3, 6, 6, next.ToString()));
        });

        // "CT0": fixed MAIN-side P1.
        AddCycle(18, "SQL TYPE", () => SqlTypeLabel(_state.SquelchType), () =>
        {
            var next = ((_state.SquelchType ?? 0) + 1) % 6;
            Send("SQL TYPE", () => _state.SquelchType = next, c => c.SetRawIntAsync("CT0", next, 1));
        });

        // "CN00"/"CN01" take an index into the tone/code table. Defaults
        // while unread are the Mac's: 100.0 Hz (index 12) and 023.
        AddStepper(19, "TONE FREQ", () => ToneLabel(_state.CtcssToneIndex),
            current: () => _state.CtcssToneIndex ?? 12, min: 0, max: RigCtcssTone.AllValuesHz.Length - 1, step: 1,
            valueLabel: i => ToneLabel((int)i),
            set: i => Send("TONE FREQ", () => _state.CtcssToneIndex = (int)i, c => c.SetRawIntAsync("CN00", (int)i, 3)));

        AddStepper(20, "DCS", () => RigDcsCode.Code(_state.DcsCodeIndex ?? -1) ?? "—",
            current: () => _state.DcsCodeIndex ?? 0, min: 0, max: RigDcsCode.AllValues.Length - 1, step: 1,
            valueLabel: i => RigDcsCode.Code((int)i) ?? "—",
            set: i => Send("DCS", () => _state.DcsCodeIndex = (int)i, c => c.SetRawIntAsync("CN01", (int)i, 3)));

        // No CAT for the rig's own HOME channels: tunes to the current band
        // group's HOME frequency instead (see HomeBand). Does nothing
        // between groups.
        var home = AddWord(21, "HOME", enabled: true);
        home.Click += (_, _) =>
        {
            if (HomeBand.Containing(_state.FrequencyHz) is { } band)
            {
                FrequencyRequested?.Invoke(band.FrequencyHz);
            }
        };

        AddNav(22, "◀", MenuPage.Cw);

        // The rig's page-3 bottom row opens the SET-mode (Deep Settings)
        // screens — not ported yet (parity plan step 8). "SOON", like iPad.
        var deepSettings = new[] { "RADIO", "CW", "OPERATION", "DISPLAY", "EXTENSION", "APRS" };
        for (var i = 0; i < deepSettings.Length; i++)
        {
            AddDisabledPair(23 + i, deepSettings[i], "SOON", "Deep Settings aren't ported to Windows yet");
        }
    }

    /// Reads the settings of the page on screen, one best-effort read each
    /// (a failure keeps the last value), then applies them all at once —
    /// unless a command landed or the page changed meanwhile, in which case
    /// the snapshot is dropped (see _commandGeneration). Called from
    /// MainWindow's slow poll tier and on a page switch; same reads as
    /// HubService.refreshSlowTier.
    public async Task RefreshFromRigAsync(RigctldClient client)
    {
        if (_refreshInFlight)
        {
            _refreshPending = true;
            return;
        }
        _refreshInFlight = true;
        try
        {
            do
            {
                _refreshPending = false;
                var generationAtStart = _commandGeneration;
                var pageAtStart = _page;
                var apply = pageAtStart switch
                {
                    MenuPage.Ssb => await ReadSsbPageAsync(client),
                    MenuPage.Cw => await ReadCwPageAsync(client),
                    MenuPage.Fm => await ReadFmPageAsync(client),
                    _ => null,
                };
                if (apply is not null && generationAtStart == _commandGeneration
                    && pageAtStart == _page && ReferenceEquals(client, _client))
                {
                    apply();
                    RefreshLabels();
                }
            }
            while (_refreshPending && ReferenceEquals(client, _client));
        }
        finally
        {
            _refreshInFlight = false;
        }
    }

    private async Task<Action> ReadCwPageAsync(RigctldClient client)
    {
        var moniLevel = await ReadOrNull(() => client.GetRawIntAsync("ML1"));
        var keyer = await ReadOrNull(() => client.GetRawBoolAsync("KR"));
        var breakIn = await ReadOrNull(() => client.GetRawBoolAsync("BI"));
        var speed = await ReadOrNull(() => client.GetRawIntAsync("KS"));
        var pitchCode = await ReadOrNull(() => client.GetRawIntAsync("KP"));
        var delayCode = await ReadOrNull(() => client.GetRawIntAsync("SD"));
        var spot = await ReadOrNull(() => client.GetRawBoolAsync("CS"));

        return () =>
        {
            _state.MoniLevel = moniLevel ?? _state.MoniLevel;
            _state.KeyerEnabled = keyer ?? _state.KeyerEnabled;
            _state.BreakIn = breakIn ?? _state.BreakIn;
            _state.CwSpeedWpm = speed ?? _state.CwSpeedWpm;
            _state.CwPitchHz = pitchCode is { } p ? 300 + p * 10 : _state.CwPitchHz;
            _state.BkDelayMs = delayCode is { } code ? RigDelayCode.Milliseconds(code) ?? _state.BkDelayMs : _state.BkDelayMs;
            _state.CwSpot = spot ?? _state.CwSpot;
        };
    }

    private async Task<Action> ReadFmPageAsync(RigctldClient client)
    {
        // "OS0"/"CT0" answers are read as one digit, like the Mac's.
        var repeaterShift = await ReadOrNull(() => client.GetRawDigitAsync("OS0"));
        var beaconRaw = await ReadStringOrNull(() => client.GetMenuItemAsync(7, 1, 1));
        var channelStepRaw = await ReadStringOrNull(() => client.GetMenuItemAsync(3, 6, 6));
        var squelchType = await ReadOrNull(() => client.GetRawDigitAsync("CT0"));
        var toneIndex = await ReadOrNull(() => client.GetRawIntAsync("CN00"));
        var dcsIndex = await ReadOrNull(() => client.GetRawIntAsync("CN01"));

        return () =>
        {
            _state.RepeaterShiftMode = repeaterShift ?? _state.RepeaterShiftMode;
            _state.AprsBeaconType = int.TryParse(beaconRaw, out var beacon) ? beacon : _state.AprsBeaconType;
            _state.FmChannelStep = int.TryParse(channelStepRaw, out var step) ? step : _state.FmChannelStep;
            _state.SquelchType = squelchType ?? _state.SquelchType;
            _state.CtcssToneIndex = toneIndex ?? _state.CtcssToneIndex;
            _state.DcsCodeIndex = dcsIndex ?? _state.DcsCodeIndex;
        };
    }

    private async Task<Action> ReadSsbPageAsync(RigctldClient client)
    {
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

        return () =>
        {
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
        };
    }

    private static async Task<T?> ReadOrNull<T>(Func<Task<T?>> read) where T : struct
    {
        try
        {
            return await read();
        }
        catch (Exception ex)
        {
            AppLog.Write($"menu-grid: read failed: {ex.Message}");
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
            AppLog.Write($"menu-grid: read failed: {ex.Message}");
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
                AppLog.Write($"transmit-gate: blocked MOX on ({reason}) at {_state.FrequencyHz} Hz");
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
                AppLog.Write($"transmit-gate: blocked ANT TUNE ({reason}) at {_state.FrequencyHz} Hz");
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

    /// Known rig label, but not wired (no CAT command, deprioritized, or not
    /// built on Windows yet — say which in <paramref name="tooltip"/>).
    private void AddDisabled(int item, string top, string? tooltip = null)
    {
        var button = AddCell(item, top, () => "—", colorize: false);
        button.IsEnabled = false;
        if (tooltip is not null)
        {
            ToolTipService.SetToolTip(button, tooltip);
        }
    }

    /// Page nav (22 = previous, 28 = next), labelled with the target page
    /// like the Mac's.
    private void AddNav(int item, string arrow, MenuPage target)
    {
        var name = target switch { MenuPage.Ssb => "SSB", MenuPage.Cw => "CW", _ => "FM" };
        var button = AddCell(item, arrow, () => name, colorize: false);
        button.Click += (_, _) => ShowPage(target);
    }

    /// A disabled button whose two lines are both label words ("APRS" /
    /// "S.LIST"), not a name and a value, so both are caption-sized — the
    /// Mac's disabledPlaceholderButtonEqualSize.
    private void AddDisabledPair(int item, string top, string bottom, string tooltip)
    {
        var button = AddCell(item, top, () => bottom, colorize: false);
        if (button.Content is StackPanel { Children: [_, TextBlock bottomText] })
        {
            bottomText.FontFamily = FontFamily.XamlAutoFontFamily;
            bottomText.FontSize = 11;
        }
        button.IsEnabled = false;
        ToolTipService.SetToolTip(button, tooltip);
    }

    /// A button whose rig label is one word (HOME, DTMF), centered at the
    /// value line's size in the normal text color — the Mac's
    /// singleWordButton. An empty top line keeps it the same height as the
    /// two-line buttons.
    private Button AddWord(int item, string word, bool enabled)
    {
        var button = AddCell(item, " ", () => word, colorize: false);
        button.IsEnabled = enabled;
        return button;
    }

    // Labels, same text as MenuPageView's.

    private static string OnOff(bool? on) => on switch { true => "ON", false => "OFF", null => "—" };

    private static string IntLabel(int? value) => value?.ToString() ?? "—";

    /// PROC LEVEL/NB/DNR/MONI LEVEL read 0 as "OFF".
    private static string OffOrNumber(int? value) => value switch { null => "—", 0 => "OFF", _ => value.Value.ToString() };

    private static string DisplayLevelLabel(double? db) =>
        db is { } v ? v.ToString("+0.0;-0.0;+0.0", System.Globalization.CultureInfo.InvariantCulture) + " dB" : "—";

    private static string RfPowerLabel(double? level) => level is { } l ? $"{Math.Round(l * 100):0}W" : "—";

    private static string RepeaterShiftLabel(int? mode) => mode switch
    {
        0 => "SIMPLEX",
        1 => "+",
        2 => "-",
        3 => "ARS",
        _ => "—",
    };

    private static string FmChannelStepLabel(int? step) => step switch
    {
        0 => "5 kHz",
        1 => "6.25 kHz",
        2 => "10 kHz",
        3 => "12.5 kHz",
        4 => "20 kHz",
        5 => "25 kHz",
        _ => "—",
    };

    private static string SqlTypeLabel(int? mode) => mode switch
    {
        0 => "OFF",
        1 => "ENC",
        2 => "TSQ",
        3 => "DCS",
        4 => "PR FREQ",
        5 => "REV TONE",
        _ => "—",
    };

    private static string ToneLabel(int? index) =>
        index is { } i && RigCtcssTone.Hertz(i) is { } hz
            ? hz.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " Hz"
            : "—";

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

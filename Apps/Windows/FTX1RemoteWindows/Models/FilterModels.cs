namespace FTX1RemoteWindows.Models;

// The Filter row's value spaces, ported from Sources/FTX1Core/RigState/
// (FilterSide.swift, FilterWidthTable.swift, IFShift.swift, IFNotch.swift,
// IFContour.swift, FilterPassbandModel.swift) and Sources/FTX1Core/
// MenuSettings/NarrowWidthPreset.swift. The Swift files stay the source of
// truth: copy any hardware correction made there.
//
// The Swift code keys everything by RigMode, whose .c4fm/.unknown cases
// mean "no IF filter". This app's RigMode has neither, so a null mode
// stands for both here.

/// Which receiver the filter controls and the Filter Function Display
/// address. Every filter command takes P1 = 0 MAIN, 1 SUB (hardware-probed
/// on the Mac 2026-09-19: Sub replies mirror Main's shapes).
public enum FilterSide
{
    Main = 0,
    Sub = 1,
}

public static class FilterSideExtensions
{
    /// The CAT P1 digit: "0" MAIN, "1" SUB.
    public static string P1(this FilterSide side) => ((int)side).ToString();

    public static string DisplayName(this FilterSide side) => side == FilterSide.Sub ? "SUB" : "MAIN";
}

/// The CAT manual's Table 5: what each raw "SH" WIDTH index means in Hz for
/// a mode. The same index is a different bandwidth per mode.
public static class FilterWidthTable
{
    public readonly record struct Entry(int Index, int Hz);

    /// LSB/USB, indices 01-23.
    private static readonly int[] SsbHz =
    [
        300, 400, 600, 850, 1100, 1200, 1500, 1650, 1800, 1950, 2100, 2250,
        2400, 2450, 2500, 2600, 2700, 2800, 2900, 3000, 3200, 3500, 4000,
    ];

    /// CW / DATA / RTTY / PSK, indices 01-21.
    private static readonly int[] CwDataHz =
    [
        50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 600, 800, 1200,
        1400, 1700, 2000, 2400, 3000, 3200, 3500, 4000,
    ];

    private static readonly Entry[] SsbEntries = SsbHz.Select((hz, i) => new Entry(i + 1, hz)).ToArray();
    private static readonly Entry[] CwDataEntries = CwDataHz.Select((hz, i) => new Entry(i + 1, hz)).ToArray();

    /// AM's two fixed widths, one per NARROW state (01 AM-N, 02 AM). Only
    /// NARROW switches between them.
    private static readonly Entry[] AmEntries = [new(1, 6000), new(2, 9000)];

    /// FM/DATA-FM likewise (02 FM-N, 03 FM).
    private static readonly Entry[] FmEntries = [new(2, 9000), new(3, 16000)];

    public static IReadOnlyList<Entry> Entries(RigMode? mode) => mode switch
    {
        RigMode.Usb or RigMode.Lsb => SsbEntries,
        RigMode.Cw or RigMode.Rtty or RigMode.DataUsb => CwDataEntries,
        RigMode.Am => AmEntries,
        RigMode.Fm or RigMode.DataFm => FmEntries,
        _ => [],
    };

    /// Whether the operator can pick among several widths (not AM/FM).
    public static bool IsAdjustable(RigMode? mode) =>
        mode is RigMode.Usb or RigMode.Lsb or RigMode.Cw or RigMode.Rtty or RigMode.DataUsb;

    public static int? Hz(int index, RigMode? mode) =>
        Entries(mode).FirstOrDefault(e => e.Index == index) is { Hz: > 0 } entry ? entry.Hz : null;

    /// "2400 Hz"; "Default" for index 0 (the manual's "default bandwidth"
    /// placeholder); "—" when unknown — typically right after a mode change,
    /// until the next read replaces the previous mode's index.
    public static string Label(int? index, RigMode? mode)
    {
        if (index is not { } i)
        {
            return "—";
        }
        if (i == 0)
        {
            return "Default";
        }
        return Hz(i, mode) is { } hz ? $"{hz} Hz" : "—";
    }

    /// The next row narrower (or wider), or null at that end of the column
    /// or when the index isn't in it. Walks the entries rather than ±1,
    /// since AM/FM have gaps in their numbering.
    public static int? NeighborIndex(int index, RigMode? mode, bool narrower)
    {
        var rows = Entries(mode);
        var position = -1;
        for (var i = 0; i < rows.Count; i++)
        {
            if (rows[i].Index == index)
            {
                position = i;
                break;
            }
        }
        if (position < 0)
        {
            return null;
        }
        var target = narrower ? position - 1 : position + 1;
        return target >= 0 && target < rows.Count ? rows[target].Index : null;
    }
}

/// IF SHIFT ("IS"): ±1200 Hz in 20 Hz steps.
public static class IFShift
{
    public const int Min = -1200;
    public const int Max = 1200;
    public const int StepHz = 20;

    /// Hardware-confirmed on the Mac 2026-09-13: the rig accepts "IS" in
    /// AM/FM but it has no effect there, so the control is disabled.
    public static bool IsSupported(RigMode? mode) => FilterWidthTable.IsAdjustable(mode);

    /// Clamped and rounded to the 20 Hz grid, ties away from zero.
    public static int Snapped(int hz)
    {
        var clamped = Math.Clamp(hz, Min, Max);
        var rounded = (int)Math.Round((double)clamped / StepHz, MidpointRounding.AwayFromZero) * StepHz;
        return Math.Clamp(rounded, Min, Max);
    }

    /// "+240 Hz" / "−240 Hz" (a real minus sign) / "0 Hz"; "—" for null.
    public static string Label(int? hz) => hz switch
    {
        null => "—",
        0 => "0 Hz",
        < 0 => $"−{-hz} Hz",
        _ => $"+{hz} Hz",
    };
}

/// The manual IF NOTCH ("BP"): 10-3200 Hz in 10 Hz steps, carried on the
/// wire as a 3-digit code of 10 Hz units. Its on/off field is 3 digits too
/// (000/001), so it's read with GetRawIntAsync, never GetRawBoolAsync.
public static class IFNotch
{
    public const int MinHz = 10;
    public const int MaxHz = 3200;
    public const int StepHz = 10;

    public static int SnappedHz(int hz)
    {
        var clamped = Math.Clamp(hz, MinHz, MaxHz);
        var rounded = (int)Math.Round((double)clamped / StepHz, MidpointRounding.AwayFromZero) * StepHz;
        return Math.Clamp(rounded, MinHz, MaxHz);
    }

    public static int Code(int hz) => SnappedHz(hz) / StepHz;

    public static int? HzForCode(int code) => code is >= 1 and <= 320 ? code * StepHz : null;

    public static string Label(int? hz) => hz is { } value ? $"{value} Hz" : "—";

    /// Same set as IF SHIFT (same IF-DSP block), pending hardware
    /// confirmation — as on the Mac.
    public static bool IsSupported(RigMode? mode) => IFShift.IsSupported(mode);
}

/// "CO": CONTOUR on/off + frequency (10-3200 Hz, 4-digit Hz) and APF on/off
/// + offset (−250…+250 Hz as a 4-digit code 0000-0050). Every field is 4
/// digits, on/off included. CONTOUR doesn't work in CW and APF only works in
/// CW, so one UI slot shows whichever applies (Face).
public static class IFContour
{
    public enum Face
    {
        Contour,
        Apf,
    }

    public const int ContourMinHz = 10;
    public const int ContourMaxHz = 3200;
    public const int ApfMinHz = -250;
    public const int ApfMaxHz = 250;
    public const int StepHz = 10;

    public static int SnappedContourHz(int hz)
    {
        var clamped = Math.Clamp(hz, ContourMinHz, ContourMaxHz);
        var rounded = (int)Math.Round((double)clamped / StepHz, MidpointRounding.AwayFromZero) * StepHz;
        return Math.Clamp(rounded, ContourMinHz, ContourMaxHz);
    }

    public static int SnappedApfHz(int hz)
    {
        var clamped = Math.Clamp(hz, ApfMinHz, ApfMaxHz);
        var rounded = (int)Math.Round((double)clamped / StepHz, MidpointRounding.AwayFromZero) * StepHz;
        return Math.Clamp(rounded, ApfMinHz, ApfMaxHz);
    }

    /// −250 Hz is 0000, 0 Hz 0025, +250 Hz 0050.
    public static int ApfCode(int hz) => SnappedApfHz(hz) / StepHz + 25;

    public static int? ApfHzForCode(int code) => code is >= 0 and <= 50 ? (code - 25) * StepHz : null;

    public static string ContourLabel(int? hz) => hz is { } value ? $"{value} Hz" : "—";

    public static string ApfLabel(int? hz) => IFShift.Label(hz);

    /// SSB/RTTY/DATA; not CW (per the operating manual), not AM/FM (same
    /// assumption as SHIFT/NOTCH).
    public static bool ContourSupported(RigMode? mode) =>
        mode is RigMode.Usb or RigMode.Lsb or RigMode.Rtty or RigMode.DataUsb;

    public static bool ApfSupported(RigMode? mode) => mode == RigMode.Cw;

    /// APF in CW, CONTOUR in every other mode with an IF filter (shown
    /// disabled in AM/FM), nothing without one.
    public static Face? FaceFor(RigMode? mode) => mode switch
    {
        null => null,
        RigMode.Cw => Face.Apf,
        _ => Face.Contour,
    };
}

/// The per-mode NAR WIDTH menu preset: the bandwidth the rig uses while
/// NARROW is on in SSB/CW/RTTY/DATA, where "SH" keeps reporting the wide
/// setting (hardware-observed on the Mac 2026-09-13). AM/FM have none —
/// "SH" follows NARROW there.
public static class NarrowWidthPreset
{
    /// The Deep Settings item holding the mode's NAR WIDTH, found by tab so
    /// the "EX" address has one source (DeepSettingsCatalog).
    public static DeepSettingItem? Item(RigMode? mode)
    {
        var tab = mode switch
        {
            RigMode.Usb or RigMode.Lsb => "MODE SSB",
            RigMode.DataUsb => "MODE DATA",
            RigMode.Rtty => "MODE RTTY",
            RigMode.Cw => "MODE CW",
            _ => null,
        };
        return tab is null ? null : DeepSettingsCatalog.Items.FirstOrDefault(i => i.Label == "NAR WIDTH" && i.Tab == tab);
    }

    /// Hz for the "EX" read's raw P4 (an index into the item's list).
    public static int? Hz(string raw, RigMode? mode)
    {
        if (Item(mode)?.ValueType is not DeepSettingValueType.Enumeration e || !int.TryParse(raw, out var index))
        {
            return null;
        }
        var label = e.Cases.FirstOrDefault(c => c.Index == index).Label;
        // Labels are "1800 Hz"; take the leading number.
        return label is not null && int.TryParse(label.Split(' ')[0], out var hz) ? hz : null;
    }
}

/// Geometry for the Filter Function Display (operating manual p.21): where
/// the passband, notch, contour/APF and per-mode markers sit on a fixed
/// 0-4000 Hz audio span. An illustration, not a readback — WIDTH, SHIFT,
/// NOTCH, CONTOUR, APF and the CW pitch are the rig's values, but where
/// each mode's passband sits before SHIFT is a convention matching the
/// rig's pictures (SSB ≈ 150-3150 Hz at 3000 Hz, CW centered on the pitch,
/// RTTY between the 2125/2295 Hz tones, DATA around 1500 Hz). AM/FM are
/// drawn centered, scaled against the mode's widest filter so NARROW
/// visibly shrinks them. See FilterPassbandModel.swift.
public sealed class FilterPassbandModel
{
    public const double SpanLowHz = 0;
    public const double SpanHighHz = 4000;

    /// "P" (CW pitch), "M"/"S" (RTTY mark/space), "C" (DATA center); a null
    /// label is the SSB bandwidth dot.
    public readonly record struct Marker(string? Label, double Hz);

    /// Passband edges, clipped to the span; null without an IF filter or
    /// before the width is known.
    public (double Low, double High)? Passband { get; }
    public double? NotchHz { get; }
    public double? ContourHz { get; }
    /// Pitch + offset.
    public double? ApfHz { get; }
    public IReadOnlyList<Marker> Markers { get; }
    public string ModeName { get; }
    public string WidthLabel { get; }

    public FilterPassbandModel(RigState state)
    {
        var mode = state.FilterMode;
        var name = mode?.DisplayName() ?? "—";
        ModeName = state.ActiveFilterSide == FilterSide.Sub ? $"SUB {name}" : name;

        double shift = state.IfShiftHz is { } s ? IFShift.Snapped(s) : 0;
        double pitch = state.CwPitchHz ?? 700;
        var wideWidth = state.FilterWidthIndex is { } index ? FilterWidthTable.Hz(index, mode) : null;
        // NARROW in SSB/CW/RTTY/DATA: the preset wins when known; AM/FM
        // already reflect NARROW through the "SH" index itself.
        var narrowPreset = state.NarrowEnabled == true && NarrowWidthPreset.Item(mode) is not null ? state.NarrowWidthHz : null;
        var width = narrowPreset ?? wideWidth;

        (double, double)? band = null;
        var marks = new List<Marker>();
        switch (mode)
        {
            case RigMode.Am or RigMode.Fm or RigMode.DataFm:
                var widest = FilterWidthTable.Entries(mode).Max(e => e.Hz);
                if (width is { } w && widest > 0)
                {
                    var fraction = Math.Min((double)w / widest, 1);
                    var half = (SpanHighHz - SpanLowHz) * fraction / 2;
                    var mid = (SpanLowHz + SpanHighHz) / 2;
                    band = Clipped(mid - half, mid + half);
                }
                break;
            case null:
                break;
            default:
                if (width is { } bw)
                {
                    var center = DefaultCenterHz(mode.Value, pitch) + shift;
                    band = Clipped(center - bw / 2.0, center + bw / 2.0);
                    switch (mode)
                    {
                        case RigMode.Cw:
                            marks.Add(new Marker("P", pitch + shift));
                            break;
                        case RigMode.Rtty:
                            marks.Add(new Marker("M", 2125 + shift));
                            marks.Add(new Marker("S", 2295 + shift));
                            break;
                        case RigMode.DataUsb:
                            marks.Add(new Marker("C", center));
                            break;
                        default:
                            marks.Add(new Marker(null, center));
                            break;
                    }
                }
                break;
        }
        Passband = band;
        Markers = band is null ? [] : marks;
        WidthLabel = narrowPreset is { } n ? $"{n} Hz N" : FilterWidthTable.Label(state.FilterWidthIndex, mode);

        NotchHz = state.NotchEnabled == true && IFNotch.IsSupported(mode) ? state.NotchHz : null;
        ContourHz = state.ContourEnabled == true && IFContour.ContourSupported(mode) ? state.ContourHz : null;
        ApfHz = state.ApfEnabled == true && IFContour.ApfSupported(mode) && state.ApfHz is { } apf ? pitch + apf : null;
    }

    private static double DefaultCenterHz(RigMode mode, double pitch) => mode switch
    {
        RigMode.Usb or RigMode.Lsb => 1650,
        RigMode.DataUsb => 1500,
        RigMode.Rtty => 2210,
        RigMode.Cw => pitch,
        _ => (SpanLowHz + SpanHighHz) / 2,
    };

    private static (double, double)? Clipped(double low, double high)
    {
        var l = Math.Max(low, SpanLowHz);
        var h = Math.Min(high, SpanHighHz);
        return l < h ? (l, h) : null;
    }

    /// Horizontal position for an audio frequency in a view of the given
    /// width (0 Hz at the left edge, 4000 Hz at the right).
    public static double X(double hz, double width) =>
        (Math.Clamp(hz, SpanLowHz, SpanHighHz) - SpanLowHz) / (SpanHighHz - SpanLowHz) * width;
}

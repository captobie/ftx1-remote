namespace FTX1RemoteWindows.Models;

/// Maps meter readings onto the needle's sweep, as a fraction 0.0 (hard
/// left, needle at rest) ... 1.0 (hard right). Port of SMeterScale in
/// Sources/FTX1Core/UI/SMeterView.swift, same anchors: S1-S9 fill the left
/// ~55% of the sweep (one S unit = 6 dB, evenly spaced), the blue
/// +20/+40/+60 region the rest; the SWR scale compresses toward ∞ like the
/// rig's printed face. Keep the two in step if either is retuned.
public static class SMeterScale
{
    /// Labeled S-scale ticks. Blue marks the over-S9 region.
    public static readonly (string Label, double Fraction, bool Blue)[] STicks =
    [
        ("1", 0.05, false),
        ("3", 0.17, false),
        ("5", 0.29, false),
        ("7", 0.41, false),
        ("9", 0.53, false),
        ("+20", 0.66, true),
        ("+40", 0.79, true),
        ("+60", 0.92, true),
    ];

    public static readonly (string Label, double Fraction)[] SwrTicks =
    [
        ("1.0", 0.10),
        ("1.5", 0.26),
        ("2", 0.38),
        ("3", 0.52),
        ("5", 0.65),
        ("∞", 0.87),
    ];

    /// Raw CAT "RM" S-meter value (0-255) -> dB relative to S9, using the
    /// table hamlib ships for the FT-991 family (the FTX-1 manual gives no
    /// calibration). Used for the Sub meter, since hamlib's STRENGTH only
    /// reads the active (Main) side.
    public static double StrengthDb(int raw) => Piecewise(raw,
    [
        (0, -54), (12, -48), (27, -42), (40, -36), (55, -30), (65, -24),
        (80, -18), (95, -12), (112, -6), (130, 0), (150, 10), (172, 20),
        (190, 30), (220, 40), (240, 50), (255, 60),
    ]);

    /// RX: dB relative to S9 (hamlib's STRENGTH convention) -> fraction.
    /// null (no reading) rests the needle.
    public static double FractionForStrengthDb(double? db) => db is not { } d ? 0 : Piecewise(d,
    [
        (-54, 0.0),
        (-48, 0.05), // S1
        (0, 0.53),   // S9
        (20, 0.66),
        (40, 0.79),
        (60, 0.92),
    ]);

    /// TX: SWR -> fraction on the SWR scale, clamped at the ∞ tick.
    public static double FractionForSwr(double? swr) => swr is not { } s ? 0 : Piecewise(s,
    [
        (1.0, 0.10),
        (1.5, 0.26),
        (2.0, 0.38),
        (3.0, 0.52),
        (5.0, 0.65),
        (20.0, 0.87), // effectively ∞
    ]);

    /// Linear interpolation through sorted (x, y) anchors, clamped to the
    /// first/last y beyond the ends.
    internal static double Piecewise(double x, (double X, double Y)[] anchors)
    {
        if (x <= anchors[0].X)
        {
            return anchors[0].Y;
        }
        for (var i = 1; i < anchors.Length; i++)
        {
            var (ax, ay) = anchors[i - 1];
            var (bx, by) = anchors[i];
            if (x <= bx)
            {
                return ay + (x - ax) / (bx - ax) * (by - ay);
            }
        }
        return anchors[^1].Y;
    }
}

/// The Digital S-meter style's bar scale. Port of BarMeter and
/// BarSMeterView's text helpers (Sources/FTX1Core/UI/BarSMeterView.swift):
/// its own 0…1 scale, S0–S9 filling the first 60% and the over-S9 dB the
/// rest.
public static class BarMeterScale
{
    public const double S9Fraction = 0.6;

    /// No "+40": at strip width it runs into "+60".
    public static readonly (string Label, double Fraction)[] STicks =
    [
        ("1", ForStrengthDb(-48)), ("3", ForStrengthDb(-36)),
        ("5", ForStrengthDb(-24)), ("7", ForStrengthDb(-12)),
        ("9", S9Fraction), ("+20", ForStrengthDb(20)),
        ("+60", 1.0),
    ];

    public static double ForStrengthDb(double? db)
    {
        if (db is not { } d)
        {
            return 0;
        }
        return d <= 0
            ? Math.Max(0, (d + 54) / 54) * S9Fraction
            : S9Fraction + Math.Min(d, 60) / 60 * (1 - S9Fraction);
    }

    /// Maps a position on the analog face's sweep (MeterSelection ticks and
    /// Fraction, whose scales run from ~0.10 to ~0.88) onto the bar.
    public static double FromFace(double face) => Math.Clamp((face - 0.10) / 0.78, 0, 1);

    /// "S7", "S9+12", or "—" with no reading; 6 dB per S unit below S9.
    public static string SUnitText(double? db)
    {
        if (db is not { } d)
        {
            return "—";
        }
        if (d > 0.5)
        {
            return $"S9+{(int)Math.Round(d, MidpointRounding.AwayFromZero)}";
        }
        var s = Math.Clamp((int)Math.Round((d + 54) / 6, MidpointRounding.AwayFromZero), 0, 9);
        return $"S{s}";
    }

    /// A TX meter's readout: "10 W", "1.5", "42%", or "—".
    public static string TxReadout(MeterSelection selection, MeterReadings r) => selection switch
    {
        MeterSelection.Po => r.PowerWatts is { } w ? string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:0} W", w) : "—",
        MeterSelection.Swr => r.Swr is { } s ? string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:0.0}", s) : "—",
        MeterSelection.Comp => Percent(r.Tx?.Comp),
        MeterSelection.Alc => Percent(r.Tx?.Alc),
        MeterSelection.Vdd => Percent(r.Tx?.Vdd),
        MeterSelection.Id => Percent(r.Tx?.Idd),
        _ => "—",
    };

    /// Raw RM (0-255) as a percentage — the CAT manual gives no units.
    private static string Percent(int? raw) =>
        raw is { } v ? $"{Math.Clamp(v, 0, 255) * 100 / 255}%" : "—";
}

/// Which reading the meter's lower scale shows while transmitting — the
/// app-side counterpart of the rig's touch-the-meter METER screen. Port of
/// MeterSelection.swift. A local display choice only: it never sends the
/// rig's own MS (METER SW) setting. TEMP is left out, as on the Mac: CAT's
/// RM has no temperature source.
public enum MeterSelection
{
    Po,
    Comp,
    Alc,
    Vdd,
    Id,
    Swr,
}

public static class MeterSelectionExtensions
{
    public static string Title(this MeterSelection s) => s switch
    {
        MeterSelection.Po => "PO",
        MeterSelection.Comp => "COMP",
        MeterSelection.Alc => "ALC",
        MeterSelection.Vdd => "VDD",
        MeterSelection.Id => "ID",
        MeterSelection.Swr => "SWR",
        _ => "",
    };

    public static string Detail(this MeterSelection s) => s switch
    {
        MeterSelection.Po => Loc.S("meterScale.rFPowerOutput"),
        MeterSelection.Comp => Loc.S("meterScale.speechProcessorCompression"),
        MeterSelection.Alc => Loc.S("meterScale.relativeALCVoltage"),
        MeterSelection.Vdd => Loc.S("meterScale.finalAmplifierDrainVoltage"),
        MeterSelection.Id => Loc.S("meterScale.finalAmplifierDrainCurrent"),
        MeterSelection.Swr => Loc.S("meterScale.standingWaveRatio"),
        _ => "",
    };

    /// Unit label at the scale's right end, if any.
    public static string? Unit(this MeterSelection s) => s == MeterSelection.Po ? "W" : null;

    private static readonly (double X, double Y)[] PoAnchors =
        [(0, 0.11), (1, 0.33), (5, 0.55), (10, 0.72), (15, 0.88)];

    /// PO and SWR mirror the rig's printed scales; COMP/ALC/ID/VDD get a
    /// generic 0-100% scale since the CAT manual gives no calibration from
    /// RM's 0-255 to real units.
    public static (string Label, double Fraction)[] Ticks(this MeterSelection s) => s switch
    {
        MeterSelection.Po => [("0", 0.11), ("1", 0.33), ("5", 0.55), ("10", 0.72), ("15", 0.88)],
        MeterSelection.Swr => SMeterScale.SwrTicks,
        _ => [("0", 0.10), ("25", 0.325), ("50", 0.54), ("75", 0.76), ("100", 0.88)],
    };

    /// Needle fraction for this meter; a missing reading rests the needle.
    public static double Fraction(this MeterSelection s, MeterReadings r) => s switch
    {
        MeterSelection.Po => r.PowerWatts is { } w ? SMeterScale.Piecewise(w, PoAnchors) : 0,
        MeterSelection.Swr => SMeterScale.FractionForSwr(r.Swr),
        MeterSelection.Comp => RawFraction(r.Tx?.Comp),
        MeterSelection.Alc => RawFraction(r.Tx?.Alc),
        MeterSelection.Vdd => RawFraction(r.Tx?.Vdd),
        MeterSelection.Id => RawFraction(r.Tx?.Idd),
        _ => 0,
    };

    private static double RawFraction(int? raw) =>
        raw is { } v ? 0.10 + 0.78 * Math.Clamp(v, 0, 255) / 255.0 : 0;
}

/// The inputs the lower scale can draw from.
public sealed record MeterReadings(double? PowerWatts, double? Swr, TxMeterReadings? Tx);

/// Raw RM (READ METER) values, 0-255, for the meters hamlib has no level
/// for. Only read while transmitting, like the Mac.
public sealed record TxMeterReadings(int? Comp, int? Alc, int? Idd, int? Vdd);

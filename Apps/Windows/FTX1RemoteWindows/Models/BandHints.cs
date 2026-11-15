namespace FTX1RemoteWindows.Models;

/// Port of Sources/FTX1Core/RigState/BandHints.swift, ARRLBandPlan.swift and
/// GMDSSFrequencies.swift (the MyKiwiSDR window's band bar) — keep them in
/// step by hand; Swift is the source of truth.

public enum BandHintKind
{
    Amateur,
    Broadcast,
    Aeronautical,
    Maritime,
    Utility,
}

/// A labelled stretch of spectrum for a waterfall's band bar: an amateur
/// band ("40m"), a broadcast band ("MW", "31m"), an aeronautical or maritime
/// mobile band ("8.8 MHz", "VHF") or another service ("CB"). Label is the
/// short part shown as is; the view adds the kind's localized word. Band is
/// the amateur band, for AmateurBandPlan (null for the others).
public sealed record BandHint(string Label, BandHintKind Kind, long LowerHz, long UpperHz, Band? Band = null);

/// The US license classes, lowest first. Novice HF is the same as
/// Technician's, so it isn't listed apart.
public enum USLicenseClass
{
    Technician,
    General,
    Advanced,
    Extra,
}

/// The band bar's table: BandPlan's amateur bands plus 2200 m and 630 m, LW/MW
/// and the shortwave broadcast bands and utility segments, and the HF
/// aeronautical and maritime mobile bands. Amateur bands win where they
/// overlap another band: SW 41m shows as 7.300–7.450 MHz, and SW 75m and
/// aeronautical 3.9 MHz (inside 80 m) not at all. Region 2 edges.
public static class BandHints
{
    /// Swift's GeneralCoverageSegments (name, range, broadcast?) — the
    /// default frequency and mode, which this app's band picker keeps
    /// elsewhere, aren't needed here.
    private static readonly (string Name, long Low, long High, bool Broadcast)[] Coverage =
    [
        ("AM BCB", 530_000, 1_700_000, true),
        ("FM BCB", 88_000_000, 108_000_000, true),
        ("SW 120m", 2_300_000, 2_495_000, true),
        ("SW 90m", 3_200_000, 3_400_000, true),
        ("SW 75m", 3_900_000, 4_000_000, true),
        ("SW 60m", 4_750_000, 5_060_000, true),
        ("SW 49m", 5_900_000, 6_200_000, true),
        ("SW 41m", 7_200_000, 7_450_000, true),
        ("SW 31m", 9_400_000, 9_900_000, true),
        ("SW 25m", 11_600_000, 12_100_000, true),
        ("SW 22m", 13_570_000, 13_870_000, true),
        ("SW 19m", 15_100_000, 15_800_000, true),
        ("SW 16m", 17_480_000, 17_900_000, true),
        ("SW 15m", 18_900_000, 19_020_000, true),
        ("SW 13m", 21_450_000, 21_850_000, true),
        ("SW 11m", 25_670_000, 26_100_000, true),
        ("CB", 26_965_000, 27_405_000, false),
        ("Aircraft", 108_000_000, 137_000_000, false),
        ("Marine VHF", 156_000_000, 162_000_000, false),
        ("NOAA WX", 162_400_000, 162_550_000, false),
    ];

    private static readonly (long, long)[] AeronauticalKHz =
    [
        (2_850, 3_155), (3_400, 3_500), (3_900, 3_950), (4_650, 4_750), (5_450, 5_730), (6_525, 6_765),
        (8_815, 9_040), (10_005, 10_100), (11_175, 11_400), (13_200, 13_360), (15_010, 15_100),
        (17_900, 18_030), (21_924, 22_000),
    ];

    private static readonly (long, long)[] MaritimeKHz =
    [
        (2_045, 2_194), (4_063, 4_438), (6_200, 6_525), (8_195, 8_815), (12_230, 13_200), (16_360, 17_410),
        (18_780, 18_900), (19_680, 19_800), (22_000, 22_855), (25_070, 25_210), (26_100, 26_175),
    ];

    public static readonly IReadOnlyList<BandHint> All = Build();

    private static List<BandHint> Build()
    {
        var amateur = new List<Band>
        {
            new("2200m", 135_700, 137_800, 136_000),
            new("630m", 472_000, 479_000, 475_000),
        }.Concat(BandPlan.All)
            .Select(b => new BandHint(b.Name, BandHintKind.Amateur, b.LowHz, b.HighHz, b))
            .ToList();

        var others = new List<BandHint> { new("LW", BandHintKind.Broadcast, 148_500, 283_500) };
        foreach (var (name, low, high, broadcast) in Coverage)
        {
            others.Add(name switch
            {
                "AM BCB" => new BandHint("MW", BandHintKind.Broadcast, low, high),
                "FM BCB" => new BandHint("FM", BandHintKind.Broadcast, low, high),
                "Aircraft" => new BandHint("VHF", BandHintKind.Aeronautical, low, high),
                "Marine VHF" => new BandHint("VHF", BandHintKind.Maritime, low, high),
                _ => new BandHint(name.StartsWith("SW ", StringComparison.Ordinal) ? name[3..] : name,
                    broadcast ? BandHintKind.Broadcast : BandHintKind.Utility, low, high),
            });
        }
        others.AddRange(Mobile(BandHintKind.Aeronautical, AeronauticalKHz));
        others.AddRange(Mobile(BandHintKind.Maritime, MaritimeKHz));
        // MF maritime mobile, home of NAVTEX (490/518 kHz); 630 m cuts it in two.
        others.Add(new BandHint("MF", BandHintKind.Maritime, 415_000, 526_500));

        var cuts = amateur.Select(a => (a.LowerHz, a.UpperHz)).ToList();
        var clipped = others.SelectMany(hint =>
            Subtract(cuts, (hint.LowerHz, hint.UpperHz)).Select(p => new BandHint(hint.Label, hint.Kind, p.Item1, p.Item2)));
        return amateur.Concat(clipped).OrderBy(h => h.LowerHz).ToList();
    }

    private static IEnumerable<BandHint> Mobile(BandHintKind kind, (long, long)[] kHz) =>
        kHz.Select(r =>
        {
            // Aeronautical bands go by one decimal (2.8, 8.8, 10.0 MHz),
            // maritime ones by whole MHz (4, 8, 12 MHz).
            var mhz = r.Item1 / 1_000.0;
            var label = kind == BandHintKind.Maritime
                ? ((long)mhz).ToString(System.Globalization.CultureInfo.InvariantCulture)
                : mhz.ToString("F1", System.Globalization.CultureInfo.InvariantCulture);
            return new BandHint($"{label} MHz", kind, r.Item1 * 1_000, r.Item2 * 1_000);
        });

    /// The hints overlapping lowHz…highHz.
    public static List<BandHint> Hints(double lowHz, double highHz) =>
        All.Where(h => h.UpperHz > lowHz && h.LowerHz < highHz).ToList();

    /// Whether to show the band's plan (amateur) or its GMDSS frequencies
    /// (maritime) in a view lowHz…highHz wide: once the band covers at least
    /// DetailMinimumFraction of the view. Below that, only the band's name.
    public static bool ShowsPlan(BandHint hint, double lowHz, double highHz)
    {
        var hasDetail = hint.Band is { } band
            ? AmateurBandPlan.Segments(band).Count > 0
            : hint.Kind == BandHintKind.Maritime && GmdssFrequencies.MarkersIn(hint).Count > 0;
        if (!hasDetail || highHz <= lowHz)
        {
            return false;
        }
        var visible = Math.Min(hint.UpperHz, highHz) - Math.Max(hint.LowerHz, lowHz);
        if (visible <= 0)
        {
            return false;
        }
        return (hint.UpperHz - hint.LowerHz) / (highHz - lowHz) >= DetailMinimumFraction;
    }

    public const double DetailMinimumFraction = 1.0 / 3.0;

    private static List<(long, long)> Subtract(List<(long Lower, long Upper)> cuts, (long Lower, long Upper) range)
    {
        var pieces = new List<(long Lower, long Upper)> { range };
        foreach (var cut in cuts)
        {
            var next = new List<(long Lower, long Upper)>();
            foreach (var piece in pieces)
            {
                if (cut.Upper <= piece.Lower || cut.Lower >= piece.Upper)
                {
                    next.Add(piece);
                    continue;
                }
                if (cut.Lower > piece.Lower)
                {
                    next.Add((piece.Lower, cut.Lower));
                }
                if (cut.Upper < piece.Upper)
                {
                    next.Add((cut.Upper, piece.Upper));
                }
            }
            pieces = next;
        }
        return pieces;
    }
}

public enum AmateurBandUsage
{
    /// CW and data (RTTY, digital); no phone.
    CwData,
    /// Phone and image, CW too.
    Phone,
    /// Every mode (160 m, 6 m above 50.1, 2 m above 144.1, 70 cm).
    AllModes,
    /// CW only (bottom of 6 m and 2 m).
    CwOnly,
    /// One of 60 m's five channels (USB, CW, data).
    Channel,
}

/// A piece of a US amateur band's plan: what may be sent there (by an Extra,
/// who may send everything anyone may) and the lowest class with any
/// privileges there.
public sealed record AmateurBandPlanSegment(long LowerHz, long UpperHz, AmateurBandUsage Usage, USLicenseClass LowestClass);

/// The US band plan of an amateur band, derived from the license tables the
/// transmit guardrail uses (PrivilegePresets, 47 CFR §97.301/305), so the two
/// can't disagree. The legal sub-bands only — not the ARRL's voluntary plan.
public static class AmateurBandPlan
{
    private static readonly string[] ClassPresets = ["us.technician", "us.general", "us.advanced", "us.extra"];

    private static readonly Lazy<Dictionary<string, List<AmateurBandPlanSegment>>> Cache = new(BuildCache);

    /// With showsTechnician false (the operator isn't a Technician or Novice),
    /// Technician-and-up parts are labelled General, the lowest class that
    /// matters to them, and merge with their General neighbours.
    public static List<AmateurBandPlanSegment> Segments(Band band, bool showsTechnician = true)
    {
        var plan = Cache.Value.GetValueOrDefault(band.Name) ?? [];
        if (showsTechnician)
        {
            return plan;
        }
        var merged = new List<AmateurBandPlanSegment>();
        foreach (var segment in plan)
        {
            var lowest = (USLicenseClass)Math.Max((int)segment.LowestClass, (int)USLicenseClass.General);
            if (merged.Count > 0 && merged[^1] is var last && last.UpperHz == segment.LowerHz && last.Usage == segment.Usage
                && last.LowestClass == lowest && segment.Usage != AmateurBandUsage.Channel)
            {
                merged[^1] = last with { UpperHz = segment.UpperHz };
            }
            else
            {
                merged.Add(segment with { LowestClass = lowest });
            }
        }
        return merged;
    }

    private static Dictionary<string, List<AmateurBandPlanSegment>> BuildCache()
    {
        var profiles = ClassPresets.Select(raw => PrivilegePresets.ByRawValue(raw)!.Segments).ToList();
        var extra = profiles[^1];
        var result = new Dictionary<string, List<AmateurBandPlanSegment>>();
        foreach (var band in BandPlan.All)
        {
            long low = band.LowHz, high = band.HighHz;
            var edges = new SortedSet<long> { low, high };
            foreach (var segments in profiles)
            {
                foreach (var segment in segments)
                {
                    foreach (var edge in new[] { segment.LowerHz, segment.UpperHz })
                    {
                        if (edge > low && edge < high)
                        {
                            edges.Add(edge);
                        }
                    }
                }
            }
            var sorted = edges.ToList();
            var plan = new List<AmateurBandPlanSegment>();
            for (var i = 0; i + 1 < sorted.Count; i++)
            {
                long a = sorted[i], b = sorted[i + 1], mid = (a + b) / 2;
                var here = extra.Where(s => s.LowerHz <= mid && mid < s.UpperHz).ToList();
                if (UsageOf(here) is not { } usage)
                {
                    continue;
                }
                var lowestIndex = profiles.FindIndex(segments => segments.Any(s => s.LowerHz <= mid && mid < s.UpperHz));
                if (lowestIndex < 0)
                {
                    continue;
                }
                var lowest = (USLicenseClass)lowestIndex;
                if (plan.Count > 0 && plan[^1] is var last && last.UpperHz == a && last.Usage == usage
                    && last.LowestClass == lowest && usage != AmateurBandUsage.Channel)
                {
                    plan[^1] = last with { UpperHz = b };
                }
                else
                {
                    plan.Add(new AmateurBandPlanSegment(a, b, usage, lowest));
                }
            }
            result[band.Name] = plan;
        }
        return result;
    }

    private static AmateurBandUsage? UsageOf(List<PrivilegeSegment> segments)
    {
        if (segments.Count == 0)
        {
            return null;
        }
        if (segments.Any(s => s.OnlyModes is not null))
        {
            return AmateurBandUsage.Channel;
        }
        var emissions = segments.SelectMany(s => s.Emissions).ToHashSet();
        if (emissions.Count == 1 && emissions.Contains(TransmitEmission.Cw))
        {
            return AmateurBandUsage.CwOnly;
        }
        if (emissions.Contains(TransmitEmission.Phone))
        {
            return emissions.Contains(TransmitEmission.Data) ? AmateurBandUsage.AllModes : AmateurBandUsage.Phone;
        }
        return AmateurBandUsage.CwData;
    }
}

public enum BandPlanMarkerKind
{
    Data, DataDX, Packet, DxWindow, QrpCW, QrpSSB, Sstv, AmCalling, Am, Beacons, NcdxfBeacons, Experimental,
    Satellite, RepeaterInputs, RepeaterOutputs, FmSimplex, Ft8, Ft4, Js8, Wspr, Psk31,
    DscDistress, VoiceDistress, NbdpDistress, Navtex, Msi,
}

public static class BandPlanMarkerKindExtensions
{
    /// Which spot label gets its place first when they crowd: the busiest
    /// digital modes, then the ARRL's spots, then the rest.
    public static int LabelPriority(this BandPlanMarkerKind kind) => kind switch
    {
        BandPlanMarkerKind.Ft8 or BandPlanMarkerKind.DscDistress or BandPlanMarkerKind.VoiceDistress => 0,
        BandPlanMarkerKind.Ft4 or BandPlanMarkerKind.NbdpDistress or BandPlanMarkerKind.Navtex => 1,
        BandPlanMarkerKind.Js8 or BandPlanMarkerKind.Wspr or BandPlanMarkerKind.Psk31 => 3,
        _ => 2,
    };
}

/// A mark on the band bar's third line: a range (RTTY/data, packet, DX
/// window…) or a single frequency (LowerHz == UpperHz: SSTV, calling
/// frequencies, beacons, digital-mode dials).
public sealed record BandPlanMarker(long LowerHz, long UpperHz, BandPlanMarkerKind Kind)
{
    public bool IsSpot => LowerHz == UpperHz;
}

/// The ARRL's voluntary HF band plan (arrl.org/band-plan, read 2026-11-15)
/// plus the usual FT8/FT4/JS8Call/WSPR/PSK31 dial frequencies, 160–10 m.
public static class ArrlBandPlan
{
    /// The band's marks, ranges first (so spots draw on top) by frequency,
    /// then spots by label priority and frequency.
    public static List<BandPlanMarker> MarkersFor(Band band)
    {
        var marks = All.Where(m => band.Contains(m.LowerHz) && band.Contains(m.UpperHz)).ToList();
        return
        [
            .. marks.Where(m => !m.IsSpot).OrderBy(m => m.LowerHz),
            .. marks.Where(m => m.IsSpot).OrderBy(m => m.Kind.LabelPriority()).ThenBy(m => m.LowerHz),
        ];
    }

    internal static BandPlanMarker Range(double lowKHz, double highKHz, BandPlanMarkerKind kind) =>
        new((long)Math.Round(lowKHz * 1_000, MidpointRounding.AwayFromZero),
            (long)Math.Round(highKHz * 1_000, MidpointRounding.AwayFromZero), kind);

    internal static BandPlanMarker Spot(double kHz, BandPlanMarkerKind kind) => Range(kHz, kHz, kind);

    public static readonly IReadOnlyList<BandPlanMarker> All = Build();

    private static List<BandPlanMarker> Build()
    {
        var m = new List<BandPlanMarker>();
        void R(double a, double b, BandPlanMarkerKind k) => m.Add(Range(a, b, k));
        void S(double a, BandPlanMarkerKind k) => m.Add(Spot(a, k));
        // 160 m
        R(1_800, 1_810, BandPlanMarkerKind.Data); S(1_810, BandPlanMarkerKind.QrpCW); S(1_910, BandPlanMarkerKind.QrpSSB);
        R(1_995, 2_000, BandPlanMarkerKind.Experimental); R(1_999, 2_000, BandPlanMarkerKind.Beacons);
        // 80 m
        R(3_500, 3_510, BandPlanMarkerKind.DxWindow); S(3_560, BandPlanMarkerKind.QrpCW); R(3_570, 3_600, BandPlanMarkerKind.Data);
        S(3_590, BandPlanMarkerKind.DataDX); R(3_790, 3_800, BandPlanMarkerKind.DxWindow); S(3_845, BandPlanMarkerKind.Sstv);
        S(3_885, BandPlanMarkerKind.AmCalling); S(3_985, BandPlanMarkerKind.QrpSSB);
        // 40 m
        S(7_030, BandPlanMarkerKind.QrpCW); S(7_040, BandPlanMarkerKind.DataDX); R(7_080, 7_125, BandPlanMarkerKind.Data);
        S(7_171, BandPlanMarkerKind.Sstv); S(7_285, BandPlanMarkerKind.QrpSSB); S(7_290, BandPlanMarkerKind.AmCalling);
        // 30 m
        R(10_130, 10_140, BandPlanMarkerKind.Data); R(10_140, 10_150, BandPlanMarkerKind.Packet);
        // 20 m
        S(14_060, BandPlanMarkerKind.QrpCW); R(14_070, 14_095, BandPlanMarkerKind.Data); R(14_095, 14_099.5, BandPlanMarkerKind.Packet);
        S(14_100, BandPlanMarkerKind.NcdxfBeacons); R(14_100.5, 14_112, BandPlanMarkerKind.Packet); S(14_230, BandPlanMarkerKind.Sstv);
        S(14_285, BandPlanMarkerKind.QrpSSB); S(14_286, BandPlanMarkerKind.AmCalling);
        // 17 m
        R(18_100, 18_105, BandPlanMarkerKind.Data); R(18_105, 18_110, BandPlanMarkerKind.Packet); S(18_110, BandPlanMarkerKind.NcdxfBeacons);
        // 15 m
        S(21_060, BandPlanMarkerKind.QrpCW); R(21_070, 21_110, BandPlanMarkerKind.Data); S(21_150, BandPlanMarkerKind.NcdxfBeacons);
        S(21_340, BandPlanMarkerKind.Sstv); S(21_385, BandPlanMarkerKind.QrpSSB);
        // 12 m
        R(24_920, 24_925, BandPlanMarkerKind.Data); R(24_925, 24_930, BandPlanMarkerKind.Packet); S(24_930, BandPlanMarkerKind.NcdxfBeacons);
        // 10 m
        S(28_060, BandPlanMarkerKind.QrpCW); R(28_070, 28_150, BandPlanMarkerKind.Data); R(28_200, 28_300, BandPlanMarkerKind.Beacons);
        S(28_200, BandPlanMarkerKind.NcdxfBeacons); S(28_385, BandPlanMarkerKind.QrpSSB); S(28_680, BandPlanMarkerKind.Sstv);
        R(29_000, 29_200, BandPlanMarkerKind.Am); R(29_300, 29_510, BandPlanMarkerKind.Satellite);
        R(29_520, 29_590, BandPlanMarkerKind.RepeaterInputs); S(29_600, BandPlanMarkerKind.FmSimplex);
        R(29_610, 29_700, BandPlanMarkerKind.RepeaterOutputs);

        // Digital modes (USB dial frequencies).
        foreach (var k in new[] { 1_840, 3_573, 5_357, 7_074, 10_136, 14_074, 18_100, 21_074, 24_915, 28_074, 50_313 })
        {
            S(k, BandPlanMarkerKind.Ft8);
        }
        foreach (var k in new[] { 3_575, 7_047.5, 10_140, 14_080, 18_104, 21_140, 24_919, 28_180, 50_318 })
        {
            S(k, BandPlanMarkerKind.Ft4);
        }
        foreach (var k in new[] { 1_842, 3_578, 7_078, 10_130, 14_078, 18_104, 21_078, 24_922, 28_078 })
        {
            S(k, BandPlanMarkerKind.Js8);
        }
        foreach (var k in new[] { 1_836.6, 3_568.6, 7_038.6, 10_138.7, 14_095.6, 18_104.6, 21_094.6, 24_924.6, 28_124.6, 50_293 })
        {
            S(k, BandPlanMarkerKind.Wspr);
        }
        foreach (var k in new[] { 3_580, 7_070, 10_142, 14_070, 18_100, 21_070, 24_920, 28_120 })
        {
            S(k, BandPlanMarkerKind.Psk31);
        }
        return m;
    }
}

/// The GMDSS distress and safety frequencies (ITU Radio Regulations Appendix
/// 15) and the maritime safety information broadcasts, for the band bar's
/// marker line inside the maritime bands. Assigned (carrier) frequencies.
public static class GmdssFrequencies
{
    public static readonly IReadOnlyList<BandPlanMarker> All = Build();

    private static List<BandPlanMarker> Build()
    {
        var list = new List<BandPlanMarker>();
        list.AddRange(new[] { 2_187.5, 4_207.5, 6_312, 8_414.5, 12_577, 16_804.5 }.Select(k => ArrlBandPlan.Spot(k, BandPlanMarkerKind.DscDistress)));
        list.AddRange(new[] { 2_182, 4_125, 6_215, 8_291, 12_290, 16_420 }.Select(k => ArrlBandPlan.Spot(k, BandPlanMarkerKind.VoiceDistress)));
        list.AddRange(new[] { 2_174.5, 4_177.5, 6_268, 8_376.5, 12_520, 16_695 }.Select(k => ArrlBandPlan.Spot(k, BandPlanMarkerKind.NbdpDistress)));
        list.AddRange(new[] { 490, 518, 4_209.5 }.Select(k => ArrlBandPlan.Spot(k, BandPlanMarkerKind.Navtex)));
        list.AddRange(new[] { 4_210, 6_314, 8_416.5, 12_579, 16_806.5, 19_680.5, 22_376, 26_100.5 }.Select(k => ArrlBandPlan.Spot(k, BandPlanMarkerKind.Msi)));
        list.Add(ArrlBandPlan.Spot(156_800, BandPlanMarkerKind.VoiceDistress));
        list.Add(ArrlBandPlan.Spot(156_525, BandPlanMarkerKind.DscDistress));
        return list;
    }

    /// The frequencies inside hint, by label priority (distress first) then
    /// frequency, the order their labels are placed in.
    public static List<BandPlanMarker> MarkersIn(BandHint hint) =>
        All.Where(m => m.LowerHz >= hint.LowerHz && m.LowerHz <= hint.UpperHz)
            .OrderBy(m => m.Kind.LabelPriority()).ThenBy(m => m.LowerHz).ToList();
}

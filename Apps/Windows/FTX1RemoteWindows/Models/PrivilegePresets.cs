namespace FTX1RemoteWindows.Models;

/// One built-in privilege table — the Mac's PrivilegePreset.
public sealed record PrivilegePreset(string RawValue, string DisplayName, bool IsUS, IReadOnlyList<PrivilegeSegment> Segments)
{
    /// A fresh copy each time, so editing a Custom copy never touches the
    /// preset.
    public PrivilegeProfile Profile => new(DisplayName, Segments.Select(s => s.Copy()));
}

/// Port of Sources/FTX1Core/Licensing/PrivilegePresets.swift — keep the
/// two in step by hand. The US license classes (47 CFR §97.301 and
/// §97.305, as of 2026-10; power limits left out, the FTX-1 can't exceed
/// them) and each ITU region's amateur allocations as outer band edges
/// with every mode allowed — the latter a starting point for a country's
/// own table (Custom), not that country's rules.
///
/// Only the bands the FTX-1 transmits on (160 m–70 cm). US 70 cm is
/// 420–450 MHz without the Line A / Canadian-border exclusions, and US
/// 60 m is the five 2.8 kHz channels (USB, CW, data; centres 5332, 5348,
/// 5358.5, 5373, 5405 kHz).
public static class PrivilegePresets
{
    private static readonly TransmitEmission[] CwData = [TransmitEmission.Cw, TransmitEmission.Data];
    private static readonly TransmitEmission[] CwPhone = [TransmitEmission.Cw, TransmitEmission.Phone];
    private static readonly TransmitEmission[] CwOnly = [TransmitEmission.Cw];
    private static readonly TransmitEmission[] AllEmissions = [TransmitEmission.Cw, TransmitEmission.Phone, TransmitEmission.Data];

    private static PrivilegeSegment Segment(double lowerKHz, double upperKHz, TransmitEmission[] emissions, string[]? onlyModes = null) =>
        new((long)Math.Round(lowerKHz * 1_000), (long)Math.Round(upperKHz * 1_000), emissions, onlyModes);

    private static List<PrivilegeSegment> AllModes(params (double Lower, double Upper)[] kHz) =>
        [.. kHz.Select(r => Segment(r.Lower, r.Upper, AllEmissions))];

    /// Each channel's 2.8 kHz around its centre: USB with the dial 1.5 kHz
    /// below the centre, CW and data at the centre.
    private static readonly PrivilegeSegment[] Us60mChannels =
        [.. new[] { 5_332, 5_348, 5_358.5, 5_373, 5_405 }.Select(c => Segment(c - 1.4, c + 1.4, AllEmissions, ["USB", "CW", "PKTUSB"]))];

    /// General, Advanced and Extra HF: the four bands whose sub-band edges
    /// differ by class are passed in (kHz: start of CW/data, start of
    /// phone), the rest are the same for all three.
    private static List<PrivilegeSegment> UsHF((double CwData, double Phone) band80, (double CwData, double Phone) band40,
        (double CwData, double Phone) band20, (double CwData, double Phone) band15) =>
    [
        Segment(1_800, 2_000, AllEmissions),
        Segment(band80.CwData, 3_600, CwData), Segment(band80.Phone, 4_000, CwPhone),
        .. Us60mChannels,
        Segment(band40.CwData, 7_125, CwData), Segment(band40.Phone, 7_300, CwPhone),
        Segment(10_100, 10_150, CwData),
        Segment(band20.CwData, 14_150, CwData), Segment(band20.Phone, 14_350, CwPhone),
        Segment(18_068, 18_110, CwData), Segment(18_110, 18_168, CwPhone),
        Segment(band15.CwData, 21_200, CwData), Segment(band15.Phone, 21_450, CwPhone),
        Segment(24_890, 24_930, CwData), Segment(24_930, 24_990, CwPhone),
        Segment(28_000, 28_300, CwData), Segment(28_300, 29_700, CwPhone),
    ];

    /// Novice and Technician HF (the same for both).
    private static List<PrivilegeSegment> UsNoviceHF() =>
    [
        Segment(3_525, 3_600, CwOnly),
        Segment(7_025, 7_125, CwOnly),
        Segment(21_025, 21_200, CwOnly),
        Segment(28_000, 28_300, CwData),
        Segment(28_300, 28_500, CwPhone, ["USB", "LSB", "CW"]),
    ];

    /// Technician and up, 6 m–70 cm: CW only at the bottom of 6 m and 2 m.
    private static List<PrivilegeSegment> UsVHF() =>
    [
        Segment(50_000, 50_100, CwOnly), Segment(50_100, 54_000, AllEmissions),
        Segment(144_000, 144_100, CwOnly), Segment(144_100, 148_000, AllEmissions),
        Segment(420_000, 450_000, AllEmissions),
    ];

    public static readonly IReadOnlyList<PrivilegePreset> All =
    [
        new("us.extra", "US Amateur Extra", true,
            [.. UsHF((3_500, 3_600), (7_000, 7_125), (14_000, 14_150), (21_000, 21_200)), .. UsVHF()]),
        new("us.advanced", "US Advanced", true,
            [.. UsHF((3_525, 3_700), (7_025, 7_125), (14_025, 14_175), (21_025, 21_225)), .. UsVHF()]),
        new("us.general", "US General", true,
            [.. UsHF((3_525, 3_800), (7_025, 7_175), (14_025, 14_225), (21_025, 21_275)), .. UsVHF()]),
        new("us.technician", "US Technician", true, [.. UsNoviceHF(), .. UsVHF()]),
        // Novice VHF/UHF is 222 MHz and 1.25 GHz, neither on the FTX-1.
        new("us.novice", "US Novice", true, UsNoviceHF()),
        new("itu.region1", "ITU Region 1 allocation", false, AllModes(
            (1_810, 2_000), (3_500, 3_800), (5_351.5, 5_366.5), (7_000, 7_200),
            (10_100, 10_150), (14_000, 14_350), (18_068, 18_168), (21_000, 21_450),
            (24_890, 24_990), (28_000, 29_700), (50_000, 50_500), (144_000, 146_000),
            (430_000, 440_000))),
        new("itu.region2", "ITU Region 2 allocation", false, AllModes(
            (1_800, 2_000), (3_500, 4_000), (5_351.5, 5_366.5), (7_000, 7_300),
            (10_100, 10_150), (14_000, 14_350), (18_068, 18_168), (21_000, 21_450),
            (24_890, 24_990), (28_000, 29_700), (50_000, 54_000), (144_000, 148_000),
            (420_000, 450_000))),
        new("itu.region3", "ITU Region 3 allocation", false, AllModes(
            (1_800, 2_000), (3_500, 3_900), (5_351.5, 5_366.5), (7_000, 7_200),
            (10_100, 10_150), (14_000, 14_350), (18_068, 18_168), (21_000, 21_450),
            (24_890, 24_990), (28_000, 29_700), (50_000, 54_000), (144_000, 148_000),
            (430_000, 440_000))),
    ];

    public static PrivilegePreset? ByRawValue(string? raw) => All.FirstOrDefault(p => p.RawValue == raw);
}

namespace FTX1RemoteWindows.Models;

public sealed record Band(string Name, long LowHz, long HighHz, long DefaultFrequencyHz)
{
    public bool Contains(long hz) => hz >= LowHz && hz <= HighHz;
}

/// Direct port of Sources/FTX1Core/RigState/BandPlan.swift — same band
/// list, same ranges, same default (calling-frequency) values. Keep this
/// in sync with the Swift source by hand; there's no shared code between
/// the two app targets (see Apps/Windows/README.md).
public static class BandPlan
{
    public static readonly IReadOnlyList<Band> All = new List<Band>
    {
        new("160m", 1_800_000, 2_000_000, 1_900_000),
        new("80m", 3_500_000, 4_000_000, 3_985_000),
        new("60m", 5_330_000, 5_410_000, 5_358_500),
        new("40m", 7_000_000, 7_300_000, 7_200_000),
        new("30m", 10_100_000, 10_150_000, 10_130_000),
        new("20m", 14_000_000, 14_350_000, 14_200_000),
        new("17m", 18_068_000, 18_168_000, 18_130_000),
        new("15m", 21_000_000, 21_450_000, 21_300_000),
        new("12m", 24_890_000, 24_990_000, 24_950_000),
        new("10m", 28_000_000, 29_700_000, 28_400_000),
        new("6m", 50_000_000, 54_000_000, 52_525_000),
        new("2m", 144_000_000, 148_000_000, 146_520_000),
        new("70cm", 420_000_000, 450_000_000, 446_000_000),
    };

    public static Band? BandContaining(long hz) => All.FirstOrDefault(b => b.Contains(hz));

    public static Band? BandNamed(string name) => All.FirstOrDefault(b => b.Name == name);
}

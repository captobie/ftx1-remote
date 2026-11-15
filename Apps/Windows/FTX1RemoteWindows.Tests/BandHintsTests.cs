using FTX1RemoteWindows.Models;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// The MyKiwiSDR band bar's tables: Tests/FTX1CoreTests/BandHintsTests.swift,
/// case for case.
public class BandHintsTests
{
    private static AmateurBandPlanSegment Seg(long lower, long upper, AmateurBandUsage usage, USLicenseClass lowest) =>
        new(lower, upper, usage, lowest);

    private static List<AmateurBandPlanSegment> Plan(string name, bool showsTechnician = true) =>
        AmateurBandPlan.Segments(BandPlan.BandNamed(name)!, showsTechnician);

    [Fact]
    public void FortyMetres() => Assert.Equal(
    [
        Seg(7_000_000, 7_025_000, AmateurBandUsage.CwData, USLicenseClass.Extra),
        Seg(7_025_000, 7_125_000, AmateurBandUsage.CwData, USLicenseClass.Technician),
        Seg(7_125_000, 7_175_000, AmateurBandUsage.Phone, USLicenseClass.Advanced),
        Seg(7_175_000, 7_300_000, AmateurBandUsage.Phone, USLicenseClass.General),
    ], Plan("40m"));

    [Fact]
    public void TechnicianFoldsIntoGeneral()
    {
        var forty = Plan("40m", showsTechnician: false);
        Assert.Equal(Seg(7_025_000, 7_125_000, AmateurBandUsage.CwData, USLicenseClass.General), forty[1]);
        Assert.DoesNotContain(forty, s => s.LowestClass == USLicenseClass.Technician);
        // 10 m: Tech CW/data and phone become General; the two phone parts merge.
        Assert.Equal(
        [
            Seg(28_000_000, 28_300_000, AmateurBandUsage.CwData, USLicenseClass.General),
            Seg(28_300_000, 29_700_000, AmateurBandUsage.Phone, USLicenseClass.General),
        ], Plan("10m", showsTechnician: false));
        // 60 m channels stay apart.
        Assert.Equal(5, Plan("60m", showsTechnician: false).Count);
    }

    [Fact]
    public void TwentyMetres() => Assert.Equal(
    [
        Seg(14_000_000, 14_025_000, AmateurBandUsage.CwData, USLicenseClass.Extra),
        Seg(14_025_000, 14_150_000, AmateurBandUsage.CwData, USLicenseClass.General),
        Seg(14_150_000, 14_175_000, AmateurBandUsage.Phone, USLicenseClass.Extra),
        Seg(14_175_000, 14_225_000, AmateurBandUsage.Phone, USLicenseClass.Advanced),
        Seg(14_225_000, 14_350_000, AmateurBandUsage.Phone, USLicenseClass.General),
    ], Plan("20m"));

    [Fact]
    public void TenMetresTechnicianPhone()
    {
        var ten = Plan("10m");
        Assert.Equal(Seg(28_000_000, 28_300_000, AmateurBandUsage.CwData, USLicenseClass.Technician), ten.First());
        Assert.Contains(Seg(28_300_000, 28_500_000, AmateurBandUsage.Phone, USLicenseClass.Technician), ten);
        Assert.Equal(Seg(28_500_000, 29_700_000, AmateurBandUsage.Phone, USLicenseClass.General), ten.Last());
    }

    [Fact]
    public void SixtyMetresIsFiveChannels()
    {
        var sixty = Plan("60m");
        Assert.Equal(5, sixty.Count);
        Assert.All(sixty, s =>
        {
            Assert.Equal(AmateurBandUsage.Channel, s.Usage);
            Assert.Equal(USLicenseClass.General, s.LowestClass);
        });
        Assert.Equal(5_330_600, sixty[0].LowerHz);
    }

    [Fact]
    public void OtherBands()
    {
        Assert.Equal([Seg(1_800_000, 2_000_000, AmateurBandUsage.AllModes, USLicenseClass.General)], Plan("160m"));
        Assert.Equal([Seg(10_100_000, 10_150_000, AmateurBandUsage.CwData, USLicenseClass.General)], Plan("30m"));
        Assert.Equal(Seg(50_000_000, 50_100_000, AmateurBandUsage.CwOnly, USLicenseClass.Technician), Plan("6m")[0]);
    }

    [Fact]
    public void BroadcastBandsGiveWayToAmateurBands()
    {
        var fortyOne = BandHints.All.Where(h => h.Label == "41m").ToList();
        Assert.Equal([(7_300_000L, 7_450_000L)], fortyOne.Select(h => (h.LowerHz, h.UpperHz)));
        Assert.DoesNotContain(BandHints.All, h => h.Label == "75m");
        Assert.Equal(BandHintKind.Broadcast, BandHints.All.First(h => h.Label == "MW").Kind);
        Assert.Equal(["40m", "41m"], BandHints.Hints(7_100_000, 7_400_000).Select(h => h.Label));
    }

    [Fact]
    public void PlanShowsOnceTheBandFillsAThirdOfTheView()
    {
        var twenty = BandHints.All.First(h => h.Label == "20m");
        // 30 MHz span: name only.
        Assert.False(BandHints.ShowsPlan(twenty, 0, 30_000_000));
        // ~0.94 MHz span around the band: 350/937 ≥ 1/3.
        Assert.True(BandHints.ShowsPlan(twenty, 13_700_000, 14_637_500));
        // Zoomed inside the band.
        Assert.True(BandHints.ShowsPlan(twenty, 14_050_000, 14_080_000));
        // Not in view.
        Assert.False(BandHints.ShowsPlan(twenty, 14_400_000, 14_500_000));
        var mw = BandHints.All.First(h => h.Label == "MW");
        Assert.False(BandHints.ShowsPlan(mw, 500_000, 1_000_000));
    }

    [Fact]
    public void ArrlMarkersForTwentyMetres()
    {
        var marks = ArrlBandPlan.MarkersFor(BandPlan.BandNamed("20m")!);
        Assert.Equal(new BandPlanMarker(14_070_000, 14_095_000, BandPlanMarkerKind.Data), marks[0]);
        Assert.Contains(new BandPlanMarker(14_230_000, 14_230_000, BandPlanMarkerKind.Sstv), marks);
        // Ranges before spots.
        var firstSpot = marks.FindIndex(m => m.IsSpot);
        Assert.All(marks.Skip(firstSpot), m => Assert.True(m.IsSpot));
        Assert.All(marks.Take(firstSpot), m => Assert.False(m.IsSpot));
    }

    [Fact]
    public void EveryArrlMarkerSitsInsideItsBand()
    {
        var covered = BandPlan.All.SelectMany(ArrlBandPlan.MarkersFor).ToList();
        Assert.Equal(ArrlBandPlan.All.Count, covered.Count);
        Assert.Equal([BandPlanMarkerKind.Ft8], ArrlBandPlan.MarkersFor(BandPlan.BandNamed("60m")!).Select(m => m.Kind));
    }

    [Fact]
    public void DigitalModeSpotsLabelFt8First()
    {
        var spots = ArrlBandPlan.MarkersFor(BandPlan.BandNamed("20m")!).Where(m => m.IsSpot).ToList();
        Assert.Equal(new BandPlanMarker(14_074_000, 14_074_000, BandPlanMarkerKind.Ft8), spots[0]);
        Assert.Contains(new BandPlanMarker(14_095_600, 14_095_600, BandPlanMarkerKind.Wspr), spots);
        var priorities = spots.Select(m => m.Kind.LabelPriority()).ToList();
        Assert.Equal(priorities.Order(), priorities);
    }

    [Fact]
    public void AeronauticalAndMaritimeBands()
    {
        var aero = BandHints.All.Where(h => h.Kind == BandHintKind.Aeronautical).ToList();
        Assert.Contains(new BandHint("8.8 MHz", BandHintKind.Aeronautical, 8_815_000, 9_040_000), aero);
        Assert.Contains(new BandHint("VHF", BandHintKind.Aeronautical, 108_000_000, 137_000_000), aero);
        // 3.9 MHz aeronautical lies inside 80 m: dropped.
        Assert.DoesNotContain(aero, h => h.LowerHz == 3_900_000);
        var maritime = BandHints.All.Where(h => h.Kind == BandHintKind.Maritime).ToList();
        Assert.Contains(new BandHint("12 MHz", BandHintKind.Maritime, 12_230_000, 13_200_000), maritime);
        Assert.Equal([BandHintKind.Maritime], BandHints.Hints(2_100_000, 2_200_000).Select(h => h.Kind));
        // Nothing but amateur bands get a plan.
        Assert.False(BandHints.ShowsPlan(aero[0], 8_800_000, 9_000_000));
    }

    [Fact]
    public void GmdssFrequenciesInMaritimeBands()
    {
        var mf = BandHints.All.First(h => h.Kind == BandHintKind.Maritime && h.LowerHz == 2_045_000);
        var marks = GmdssFrequencies.MarkersIn(mf);
        Assert.Equal(new HashSet<long> { 2_174_500, 2_182_000, 2_187_500 }, marks.Select(m => m.LowerHz).ToHashSet());
        Assert.Equal(0, marks[0].Kind.LabelPriority());
        // Every HF/MF GMDSS frequency sits inside one of the maritime hints.
        var maritime = BandHints.All.Where(h => h.Kind == BandHintKind.Maritime).ToList();
        foreach (var mark in GmdssFrequencies.All)
        {
            Assert.True(maritime.Any(h => h.LowerHz <= mark.LowerHz && mark.LowerHz <= h.UpperHz),
                $"{mark.LowerHz} Hz is outside every maritime band");
        }
        // NAVTEX 490/518 kHz: in the part of the MF band above 630 m.
        var navtexBand = maritime.First(h => h.LowerHz == 479_000);
        Assert.Equal([490_000L, 518_000L], GmdssFrequencies.MarkersIn(navtexBand).Select(m => m.LowerHz));
        Assert.True(BandHints.ShowsPlan(mf, 2_000_000, 2_234_000));
    }
}

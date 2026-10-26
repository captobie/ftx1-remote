using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Hub;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// Settings → License (the license-class guardrail): the Mac's
/// Tests/FTX1CoreTests/TransmitPrivilegesTests.swift, case for case, plus
/// the Mac's JSON format and the hub gate.
public class TransmitPrivilegesTests
{
    private static PrivilegeProfile P(string raw) => PrivilegePresets.ByRawValue(raw)!.Profile;

    private static bool Allows(string preset, long hz, RigMode mode) => P(preset).Allows(new TransmitSignal(hz, mode));

    private static bool AllowsC4fm(string preset, long hz) => P(preset).Allows(new TransmitSignal(hz, null, IsC4fm: true));

    // Sub-band edges.

    [Fact]
    public void GeneralTwentyMetrePhoneEdge()
    {
        Assert.True(Allows("us.general", 14_225_000, RigMode.Usb));
        Assert.False(Allows("us.general", 14_224_000, RigMode.Usb));
        Assert.True(Allows("us.extra", 14_150_000, RigMode.Usb));
        Assert.False(Allows("us.extra", 14_149_000, RigMode.Usb));
        Assert.True(Allows("us.advanced", 14_175_000, RigMode.Usb));
        Assert.False(Allows("us.advanced", 14_174_000, RigMode.Usb));
        // Top of the band: USB at 14.3475 reaches 14.3504.
        Assert.True(Allows("us.general", 14_347_000, RigMode.Usb));
        Assert.False(Allows("us.general", 14_348_000, RigMode.Usb));
    }

    /// LSB reaches 2.9 kHz below the dial, so General's 7.175 edge needs
    /// the dial at 7.178 or above.
    [Fact]
    public void LowerSidebandHasToClearTheEdge()
    {
        Assert.False(Allows("us.general", 7_175_000, RigMode.Lsb));
        Assert.False(Allows("us.general", 7_177_000, RigMode.Lsb));
        Assert.True(Allows("us.general", 7_178_000, RigMode.Lsb));
        Assert.True(Allows("us.extra", 7_128_000, RigMode.Lsb));
        Assert.False(Allows("us.extra", 7_126_000, RigMode.Lsb));
        Assert.False(Allows("us.general", 1_801_000, RigMode.Lsb));
        Assert.True(Allows("us.general", 1_803_000, RigMode.Lsb));
    }

    [Fact]
    public void CwAndDataSegments()
    {
        Assert.True(Allows("us.general", 14_025_500, RigMode.Cw));
        Assert.False(Allows("us.general", 14_020_000, RigMode.Cw));
        Assert.True(Allows("us.extra", 14_001_000, RigMode.Cw));
        Assert.True(Allows("us.general", 14_250_000, RigMode.Cw));
        Assert.True(Allows("us.extra", 14_150_000, RigMode.Cw));
        Assert.True(Allows("us.general", 14_074_000, RigMode.DataUsb));
        Assert.True(Allows("us.general", 14_080_000, RigMode.Rtty));
        Assert.False(Allows("us.extra", 14_200_000, RigMode.DataUsb));
        Assert.False(Allows("us.extra", 14_148_000, RigMode.DataUsb));
        Assert.False(Allows("us.extra", 14_100_000, RigMode.Usb));
        Assert.True(Allows("us.general", 10_136_000, RigMode.DataUsb));
        Assert.False(Allows("us.extra", 10_130_000, RigMode.Usb));
    }

    [Fact]
    public void TechnicianHF()
    {
        Assert.True(Allows("us.technician", 7_030_000, RigMode.Cw));
        Assert.False(Allows("us.technician", 7_030_000, RigMode.DataUsb));
        Assert.False(Allows("us.technician", 7_200_000, RigMode.Lsb));
        Assert.False(Allows("us.technician", 14_050_000, RigMode.Cw));
        Assert.True(Allows("us.technician", 28_074_000, RigMode.DataUsb));
        Assert.True(Allows("us.technician", 28_400_000, RigMode.Usb));
        Assert.False(Allows("us.technician", 28_400_000, RigMode.Am));
        Assert.False(Allows("us.technician", 28_498_000, RigMode.Usb));
        Assert.False(Allows("us.technician", 29_600_000, RigMode.Fm));
        Assert.True(Allows("us.general", 29_600_000, RigMode.Fm));
    }

    [Theory]
    [InlineData("us.technician")]
    [InlineData("us.general")]
    [InlineData("us.extra")]
    public void VhfAndUhf(string preset)
    {
        Assert.True(Allows(preset, 146_520_000, RigMode.Fm));
        Assert.True(Allows(preset, 144_390_000, RigMode.DataFm));
        Assert.True(AllowsC4fm(preset, 446_000_000));
        Assert.True(Allows(preset, 144_050_000, RigMode.Cw));
        Assert.False(Allows(preset, 144_050_000, RigMode.Usb));
        Assert.True(Allows(preset, 144_200_000, RigMode.Usb));
        Assert.True(Allows(preset, 50_125_000, RigMode.Usb));
        Assert.False(Allows(preset, 50_090_000, RigMode.Usb));
        // FM's ±8 kHz runs past 148 MHz.
        Assert.False(Allows(preset, 147_995_000, RigMode.Fm));
    }

    [Fact]
    public void NoviceHasNoVhf()
    {
        Assert.False(Allows("us.novice", 146_520_000, RigMode.Fm));
        Assert.False(Allows("us.novice", 50_125_000, RigMode.Usb));
    }

    [Fact]
    public void SixtyMetreChannels()
    {
        foreach (var centre in new long[] { 5_332_000, 5_348_000, 5_358_500, 5_373_000, 5_405_000 })
        {
            Assert.True(Allows("us.general", centre - 1_500, RigMode.Usb));
            Assert.True(Allows("us.general", centre, RigMode.Cw));
            Assert.False(Allows("us.general", centre, RigMode.Usb));
            Assert.False(Allows("us.general", centre + 1_500, RigMode.Lsb));
            Assert.False(Allows("us.technician", centre, RigMode.Cw));
        }
        Assert.True(Allows("us.general", 5_357_000, RigMode.DataUsb));
        Assert.False(Allows("us.general", 5_340_000, RigMode.Cw));
        Assert.False(Allows("us.general", 5_332_000, RigMode.Rtty));
    }

    [Fact]
    public void RegionPresets()
    {
        Assert.True(Allows("itu.region1", 7_150_000, RigMode.Lsb));
        Assert.False(Allows("itu.region1", 7_250_000, RigMode.Lsb));
        Assert.False(Allows("itu.region1", 147_000_000, RigMode.Fm));
        Assert.True(Allows("itu.region1", 145_500_000, RigMode.Fm));
        Assert.True(Allows("itu.region2", 7_250_000, RigMode.Lsb));
        Assert.True(Allows("itu.region3", 3_850_000, RigMode.Lsb));
        Assert.False(Allows("itu.region3", 3_950_000, RigMode.Lsb));
        Assert.True(Allows("itu.region1", 5_355_000, RigMode.Cw));
    }

    [Fact]
    public void UnknownModeNeverPasses() =>
        Assert.False(P("itu.region2").Allows(new TransmitSignal(14_200_000, null)));

    // Custom segments.

    [Fact]
    public void CustomSegmentsAndOnlyModes()
    {
        var profile = new PrivilegeProfile("Custom",
        [
            new PrivilegeSegment(14_000_000, 14_100_000, [TransmitEmission.Cw]),
            new PrivilegeSegment(14_100_000, 14_350_000, [TransmitEmission.Phone], ["USB"]),
        ]);
        Assert.True(profile.Allows(new TransmitSignal(14_050_000, RigMode.Cw)));
        Assert.False(profile.Allows(new TransmitSignal(14_200_000, RigMode.Cw)));
        Assert.True(profile.Allows(new TransmitSignal(14_200_000, RigMode.Usb)));
        Assert.False(profile.Allows(new TransmitSignal(14_200_000, RigMode.Lsb)));
        Assert.False(profile.Allows(new TransmitSignal(14_200_000, RigMode.Am)));
    }

    [Fact]
    public void ProfileRoundTripsThroughJson()
    {
        var profile = P("us.general");
        var decoded = PrivilegeProfile.FromJson(profile.ToJson())!;
        Assert.Equal(profile.Name, decoded.Name);
        Assert.Equal(profile.Segments.Count, decoded.Segments.Count);
        for (var i = 0; i < profile.Segments.Count; i++)
        {
            Assert.Equal(profile.Segments[i].Id, decoded.Segments[i].Id);
            Assert.Equal(profile.Segments[i].LowerHz, decoded.Segments[i].LowerHz);
            Assert.Equal(profile.Segments[i].UpperHz, decoded.Segments[i].UpperHz);
            Assert.Equal(profile.Segments[i].Emissions, decoded.Segments[i].Emissions);
            Assert.Equal(profile.Segments[i].OnlyModes, decoded.Segments[i].OnlyModes);
        }
    }

    /// What the Mac's Export… writes (Swift's JSONEncoder, sorted keys,
    /// an uppercase UUID, no onlyModes key when there are none).
    [Fact]
    public void ReadsTheMacsExport()
    {
        const string json = """
            {
              "name" : "UK Full",
              "segments" : [
                {
                  "emissions" : [ "cw", "data" ],
                  "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
                  "lowerHz" : 14000000,
                  "upperHz" : 14070000
                },
                {
                  "emissions" : [ "phone", "cw" ],
                  "id" : "7F9619FF-8B86-D011-B42D-00C04FC964FF",
                  "lowerHz" : 14101000,
                  "onlyModes" : [ "USB", "C4FM" ],
                  "upperHz" : 14350000
                }
              ]
            }
            """;
        var profile = PrivilegeProfile.FromJson(json)!;
        Assert.Equal("UK Full", profile.Name);
        Assert.Null(profile.Segments[0].OnlyModes);
        Assert.True(profile.Allows(new TransmitSignal(14_200_000, RigMode.Usb)));
        Assert.False(profile.Allows(new TransmitSignal(14_200_000, RigMode.Lsb)));
        Assert.True(profile.Allows(new TransmitSignal(14_030_000, RigMode.Cw)));
        // Written back without an onlyModes key where there are none.
        Assert.DoesNotContain("\"onlyModes\": null", profile.ToJson());
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("not json")]
    [InlineData("""{"name":"x","segments":[{"lowerHz":1,"upperHz":2,"emissions":["morse"]}]}""")]
    public void RejectsWhatIsNotAPrivilegesFile(string json)
    {
        var profile = PrivilegeProfile.FromJson(json);
        Assert.True(profile is null || profile.Segments.Count == 0);
    }

    [Fact]
    public void ChoiceRawValues()
    {
        foreach (var raw in PrivilegePresets.All.Select(p => p.RawValue).Append(PrivilegeChoice.Off).Append(PrivilegeChoice.Custom))
        {
            Assert.Equal(raw, PrivilegeChoice.Normalize(raw));
        }
        Assert.Equal(PrivilegeChoice.Off, PrivilegeChoice.Normalize("nonsense"));
        Assert.Equal(PrivilegeChoice.Off, PrivilegeChoice.Normalize(null));
        Assert.Null(PrivilegeChoice.Profile(PrivilegeChoice.Off, new PrivilegeProfile()));
        Assert.Equal("US General", PrivilegeChoice.Profile("us.general", new PrivilegeProfile())!.Name);
    }

    // Gate.

    [Fact]
    public void GateUsesTheSignalsModeAndFrequency()
    {
        var general = P("us.general");
        Assert.Null(TransmitGate.BlockReason(TransmitAction.PttOn, true, new TransmitSignal(14_250_000, RigMode.Usb), general));
        Assert.Equal("Transmit disabled: USB on 14.200.000 MHz is outside US General privileges",
            TransmitGate.BlockReason(TransmitAction.PttOn, true, new TransmitSignal(14_200_000, RigMode.Usb), general));
        // Without privileges only the band counts.
        Assert.Null(TransmitGate.BlockReason(TransmitAction.PttOn, true, new TransmitSignal(14_200_000, RigMode.Usb)));
        Assert.Equal("Transmit disabled: the transmitting side's mode isn't known yet",
            TransmitGate.BlockReason(TransmitAction.PttOn, true, new TransmitSignal(14_030_000, null), general));
        Assert.Equal("Transmit disabled: C4FM on 446.000.000 MHz is outside US Novice privileges",
            TransmitGate.BlockReason(TransmitAction.PttOn, true, new TransmitSignal(446_000_000, null, true), P("us.novice")));
    }

    [Fact]
    public void GateKeepsTheBandCheckAsTheOuterLimit()
    {
        var wide = new PrivilegeProfile("Wide", [new PrivilegeSegment(5_000_000, 10_000_000, TransmitEmissionExtensions.All)]);
        Assert.Equal("Transmit disabled: outside an amateur band",
            TransmitGate.BlockReason(TransmitAction.PttOn, true, new TransmitSignal(9_650_000, RigMode.Am), wide));
    }

    [Fact]
    public void HubGateAppliesThePrivilegesButNeverToUnkeying()
    {
        var general = P("us.general");
        var outside = new TransmitSignal(14_200_000, RigMode.Usb);
        Assert.NotNull(HubCommandPolicy.RefusalReason(new SetPtt(true), true, outside, general));
        Assert.NotNull(HubCommandPolicy.RefusalReason(new PlayCwTextMemory(1), true, new TransmitSignal(14_020_000, RigMode.Cw), general));
        Assert.Null(HubCommandPolicy.RefusalReason(new SetPtt(false), true, outside, general));
        Assert.Null(HubCommandPolicy.RefusalReason(new PlayCwTextMemory(0), true, outside, general));
        Assert.Null(HubCommandPolicy.RefusalReason(new SetPtt(true), true, new TransmitSignal(14_250_000, RigMode.Usb), general));
    }

    [Fact]
    public void FormatsLikeTheVfoBoxes()
    {
        Assert.Equal("14.074.000", TransmitGate.FormatMHz(14_074_000));
        Assert.Equal("1.800.500", TransmitGate.FormatMHz(1_800_500));
        Assert.Equal("446.000.000", TransmitGate.FormatMHz(446_000_000));
    }
}

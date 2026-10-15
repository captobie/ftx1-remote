using System.Net;
using System.Text.Encodings.Web;
using System.Text.Json;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services.Hub;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// The hub's wire contract, through Tests/WireFixtures (see its README):
/// the Swift-made pushes must survive a C# decode/encode unchanged, and a
/// C#-made push is committed to Tests/WireFixtures/windows/ for the Mac's
/// HubWireFixtureTests to decode the way the iPad does.
public class HubWireTests
{
    private static readonly string[] RequiredStateKeys =
        ["frequencyHz", "mode", "ptt", "lastUpdated", "aprsActive", "aprsSubActive", "transmitEnabled"];

    private static string FixturesDir
    {
        get
        {
            for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            {
                var candidate = Path.Combine(dir.FullName, "Tests", "WireFixtures");
                if (Directory.Exists(candidate))
                {
                    return candidate;
                }
            }
            throw new DirectoryNotFoundException("Tests/WireFixtures not found above " + AppContext.BaseDirectory);
        }
    }

    public static IEnumerable<object[]> SwiftFixtures() =>
        Directory.GetFiles(FixturesDir, "rig-state-push.*.json").Select(f => new object[] { Path.GetFileName(f) });

    [Theory]
    [MemberData(nameof(SwiftFixtures))]
    public void SwiftFixtureRoundTrips(string fileName)
    {
        var original = File.ReadAllText(Path.Combine(FixturesDir, fileName));
        var push = HubWire.Deserialize(original);
        Assert.NotNull(push);
        var reencoded = HubWire.Serialize(push!);
        using var a = JsonDocument.Parse(original);
        using var b = JsonDocument.Parse(reencoded);
        AssertJsonEqual(a.RootElement, b.RootElement, "$");
    }

    [Fact]
    public void SwiftFixturesCoverEveryWireField()
    {
        // `full` sets every field once, so a property this side lacks (and
        // would silently drop) shows up as a round-trip difference above;
        // this checks the opposite direction — no C# property Swift lacks.
        using var full = JsonDocument.Parse(File.ReadAllText(Path.Combine(FixturesDir, "rig-state-push.full.json")));
        var swiftKeys = full.RootElement.GetProperty("state").EnumerateObject().Select(p => p.Name).ToHashSet();
        var wireKeys = typeof(RigStateWire).GetProperties()
            .Select(p => p.GetCustomAttributes(typeof(System.Text.Json.Serialization.JsonPropertyNameAttribute), false)
                .Cast<System.Text.Json.Serialization.JsonPropertyNameAttribute>().Single().Name)
            .ToHashSet();
        Assert.Empty(wireKeys.Except(swiftKeys));
        Assert.Empty(swiftKeys.Except(wireKeys));
    }

    [Fact]
    public void LastUpdatedIsSecondsSince2001()
    {
        var date = new DateTimeOffset(2026, 10, 15, 12, 0, 0, TimeSpan.Zero);
        Assert.Equal(813758400.0, HubWire.SwiftDate(date));
        Assert.Equal(date.ToUnixTimeSeconds() - 978307200, (long)HubWire.SwiftDate(date));
    }

    [Fact]
    public void UnreadStateHasOnlyTheRequiredFieldsAndFilterSide()
    {
        var state = new RigState { LastUpdated = new DateTimeOffset(2026, 10, 15, 12, 0, 0, TimeSpan.Zero) };
        var json = HubWire.Serialize(RigStateWireMapper.Push(state, new HubStateExtras(TransmitEnabled: false)));
        using var doc = JsonDocument.Parse(json);
        var keys = doc.RootElement.GetProperty("state").EnumerateObject().Select(p => p.Name).Order().ToArray();
        Assert.Equal(RequiredStateKeys.Append("filterSide").Order().ToArray(), keys);
        Assert.Equal("UNKNOWN", doc.RootElement.GetProperty("state").GetProperty("mode").GetString());
    }

    [Fact]
    public void WritesWindowsFixture()
    {
        var push = RigStateWireMapper.Push(PopulatedState(), new HubStateExtras(
            TransmitEnabled: true,
            AudioChannelsSwapped: true,
            SingleReceive: false,
            SplitEnabled: false,
            TxSideSub: false,
            AprsActive: false,
            AprsLastCallsign: "W1AW-9", // dropped: Main isn't on the APRS frequency
            AprsSubActive: true,
            AprsSubLastCallsign: "K6NA-7"));
        var compact = HubWire.Serialize(push);

        using var doc = JsonDocument.Parse(compact);
        var state = doc.RootElement.GetProperty("state");
        Assert.Equal("state", doc.RootElement.GetProperty("type").GetString());
        foreach (var key in RequiredStateKeys)
        {
            Assert.True(state.TryGetProperty(key, out _), $"missing required {key}");
        }
        Assert.Equal("PKTUSB", state.GetProperty("mode").GetString());
        Assert.Equal("C4FM", state.GetProperty("secondaryMode").GetString());
        Assert.Equal("20m", state.GetProperty("band").GetString());
        Assert.Equal(813758400.0, state.GetProperty("lastUpdated").GetDouble());
        Assert.True(state.GetProperty("vfoMemoryMode").TryGetProperty("vfo", out _));
        Assert.Equal(2, state.GetProperty("subVfoMemoryMode").GetProperty("other").GetProperty("rawP2").GetInt32());
        Assert.Equal("paused", state.GetProperty("memoryScan").GetString());
        Assert.Equal(1, state.GetProperty("memoryScanSide").GetInt32());
        Assert.Equal(1, state.GetProperty("filterSide").GetInt32());
        Assert.Equal(0, state.GetProperty("txSide").GetInt32());
        Assert.False(state.TryGetProperty("aprsLastCallsign", out _));
        Assert.Equal("K6NA-7", state.GetProperty("aprsSubLastCallsign").GetString());
        Assert.False(state.TryGetProperty("cwMessageStatus", out _));
        Assert.False(state.TryGetProperty("txwEnabled", out _));

        // Decodes back to the same JSON, like the Swift fixtures.
        var again = HubWire.Serialize(HubWire.Deserialize(compact)!);
        using var b = JsonDocument.Parse(again);
        AssertJsonEqual(doc.RootElement, b.RootElement, "$");

        var indented = JsonSerializer.Serialize(push, new JsonSerializerOptions(HubWire.JsonOptions)
        {
            WriteIndented = true,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
        var dir = Path.Combine(FixturesDir, "windows");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "windows-state-push.json"), indented + "\n");
    }

    /// A state with most fields read, as after a few polls with Main on
    /// 20 m DATA-U and SUB in C4FM on a memory sub-mode.
    private static RigState PopulatedState() => new()
    {
        FrequencyHz = 14_074_000,
        Mode = RigMode.DataUsb,
        MainIsC4fm = false,
        PowerWatts = 0,
        Swr = 1.1,
        Ptt = true,
        LastUpdated = new DateTimeOffset(2026, 10, 15, 12, 0, 0, TimeSpan.Zero),
        SecondaryFrequencyHz = 430_000_000,
        SubMode = RigMode.Fm,
        SubIsC4fm = true,
        PowerLevel = 0.25,
        SmeterDb = -12.5,
        SubSmeterDb = 3.25,
        TxMeters = new TxMeterReadings(Comp: 5, Alc: 10, Idd: 120, Vdd: 138),
        VfoMemoryRaw = 0,
        SubVfoMemoryRaw = 2, // a sub-mode other than VFO/Memory
        SubMemoryChannel = 100,
        SubMemoryChannelTag = "NOAA",
        MemoryScan = MemoryScanState.Paused,
        MemoryScanSub = true,
        C4fmCallsign = "W1AW",
        C4fmReflector = "AMERICA-LINK",
        DisplayLevel = -5.5,
        DisplayPeak = 2,
        DisplayMarker = true,
        DisplayContrast = 10,
        DisplayDimmer = 15,
        MoxEnabled = false,
        AttEnabled = false,
        PreampMode = 1,
        DnfEnabled = false,
        AgcMode = 2,
        MicEqEnabled = false,
        ProcLevel = 25,
        TunerEnabled = true,
        NbLevel = 3,
        DnrLevel = 4,
        AntSelect = 1,
        MicGain = 50,
        AmcLevel = 30,
        VoxEnabled = false,
        VoxGain = 40,
        VoxDelayMs = 500,
        MoniLevel = 50,
        KeyerEnabled = true,
        BreakIn = true,
        CwSpeedWpm = 18,
        CwPitchHz = 700,
        BkDelayMs = 300,
        CwSpot = false,
        RepeaterShiftMode = 2,
        AprsBeaconType = 0,
        FmChannelStep = 5,
        SquelchType = 1,
        CtcssToneIndex = 12,
        DcsCodeIndex = 3,
        FilterSide = FilterSide.Sub,
        FilterWidthIndex = 9,
        IfShiftHz = -120,
        NotchEnabled = true,
        NotchHz = 1500,
        ContourEnabled = false,
        ContourHz = 800,
        ApfEnabled = true,
        ApfHz = -20,
        NarrowEnabled = false,
        NarrowWidthHz = 500,
    };

    // The address filter (user decision: loopback, Tailscale, private only).

    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("127.5.6.7")]
    [InlineData("::1")]
    [InlineData("100.64.0.1")]
    [InlineData("100.104.255.14")]
    [InlineData("100.127.255.255")]
    [InlineData("10.1.2.3")]
    [InlineData("172.16.0.1")]
    [InlineData("172.31.255.255")]
    [InlineData("192.168.1.20")]
    [InlineData("169.254.10.10")]
    [InlineData("fd7a:115c:a1e0::1234")]
    [InlineData("fd7a:115c:a1e0:ab12::1")]
    [InlineData("fc00::1")]
    [InlineData("fdff:ffff::1")]
    [InlineData("fe80::1")]
    [InlineData("febf::1")]
    [InlineData("::ffff:192.168.1.20")]
    [InlineData("::ffff:100.100.1.1")]
    [InlineData("::ffff:127.0.0.1")]
    public void AllowsLocalAndTailscale(string address) =>
        Assert.True(HubAddressFilter.IsAllowed(IPAddress.Parse(address)), address);

    [Theory]
    [InlineData("8.8.8.8")]
    [InlineData("100.63.255.255")]
    [InlineData("100.128.0.1")]
    [InlineData("172.15.255.255")]
    [InlineData("172.32.0.1")]
    [InlineData("192.169.0.1")]
    [InlineData("169.255.0.1")]
    [InlineData("11.0.0.1")]
    [InlineData("0.0.0.0")]
    [InlineData("2001:4860:4860::8888")]
    [InlineData("fec0::1")]
    [InlineData("fe00::1")]
    [InlineData("::ffff:8.8.8.8")]
    [InlineData("::")]
    public void RefusesEverythingElse(string address) =>
        Assert.False(HubAddressFilter.IsAllowed(IPAddress.Parse(address)), address);

    [Fact]
    public void RefusesNoAddress() => Assert.False(HubAddressFilter.IsAllowed(null));

    /// Structural JSON equality, ignoring key order; numbers compared by
    /// value (813758400 == 813758400.0).
    private static void AssertJsonEqual(JsonElement expected, JsonElement actual, string path)
    {
        Assert.True(expected.ValueKind == actual.ValueKind, $"{path}: {expected.ValueKind} vs {actual.ValueKind}");
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var e = expected.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
                var a = actual.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
                Assert.True(e.Keys.Order().SequenceEqual(a.Keys.Order()),
                    $"{path}: keys differ — missing [{string.Join(", ", e.Keys.Except(a.Keys))}], extra [{string.Join(", ", a.Keys.Except(e.Keys))}]");
                foreach (var (key, value) in e)
                {
                    AssertJsonEqual(value, a[key], $"{path}.{key}");
                }
                break;
            case JsonValueKind.Array:
                var ea = expected.EnumerateArray().ToArray();
                var aa = actual.EnumerateArray().ToArray();
                Assert.True(ea.Length == aa.Length, $"{path}: array length");
                for (var i = 0; i < ea.Length; i++)
                {
                    AssertJsonEqual(ea[i], aa[i], $"{path}[{i}]");
                }
                break;
            case JsonValueKind.Number:
                Assert.True(expected.GetDecimal() == actual.GetDecimal(), $"{path}: {expected} vs {actual}");
                break;
            case JsonValueKind.String:
                Assert.True(expected.GetString() == actual.GetString(), $"{path}: {expected} vs {actual}");
                break;
        }
    }
}

using System.Text.Json;
using System.Text.Json.Serialization;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services.Hub;

/// The Mac hub's state push, `{"type":"state","state":{…}}` —
/// Sources/FTX1Core/Networking/WireMessage.swift's RigStatePush. The iPad
/// decodes it with Swift's synthesized Codable, so the shapes here are
/// copied from Swift, not designed: see Tests/WireFixtures/README.md for the
/// ones that are easy to get wrong. Compiled into the test project too
/// (Apps/Windows/FTX1RemoteWindows.Tests), so keep it free of WinUI types.
public sealed class RigStatePushWire
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "state";

    [JsonPropertyName("state")]
    public RigStateWire State { get; set; } = new();
}

/// RigState.swift's RigState, field for field. The non-nullable properties
/// are the ones Swift requires (`frequencyHz`, `mode`, `ptt`,
/// `lastUpdated`, `aprsActive`, `aprsSubActive`, `transmitEnabled`): a push
/// missing any of them fails to decode on the iPad, which then sits on
/// "Connecting…". Every other field is left out when null, as Swift does.
public sealed class RigStateWire
{
    [JsonPropertyName("frequencyHz")] public long FrequencyHz { get; set; }
    /// RigMode raw values ("USB", "PKTUSB", "FM-D", "C4FM", "UNKNOWN"…).
    [JsonPropertyName("mode")] public string Mode { get; set; } = "UNKNOWN";
    [JsonPropertyName("band")] public string? Band { get; set; }
    [JsonPropertyName("powerWatts")] public double? PowerWatts { get; set; }
    [JsonPropertyName("swr")] public double? Swr { get; set; }
    [JsonPropertyName("ptt")] public bool Ptt { get; set; }
    /// Seconds since 2001-01-01T00:00:00Z (Swift's default Date coding).
    [JsonPropertyName("lastUpdated")] public double LastUpdated { get; set; }
    [JsonPropertyName("secondaryFrequencyHz")] public long? SecondaryFrequencyHz { get; set; }
    [JsonPropertyName("secondaryMode")] public string? SecondaryMode { get; set; }
    [JsonPropertyName("powerLevel")] public double? PowerLevel { get; set; }
    [JsonPropertyName("breakIn")] public bool? BreakIn { get; set; }
    [JsonPropertyName("keyerEnabled")] public bool? KeyerEnabled { get; set; }
    [JsonPropertyName("cwSpeedWpm")] public int? CwSpeedWpm { get; set; }
    [JsonPropertyName("cwPitchHz")] public int? CwPitchHz { get; set; }
    [JsonPropertyName("bkDelayMs")] public int? BkDelayMs { get; set; }
    [JsonPropertyName("cwSpot")] public bool? CwSpot { get; set; }
    [JsonPropertyName("moniLevel")] public int? MoniLevel { get; set; }
    /// 0 stopped, 1 recording, 2 playing.
    [JsonPropertyName("cwMessageStatus")] public int? CwMessageStatus { get; set; }
    [JsonPropertyName("moxEnabled")] public bool? MoxEnabled { get; set; }
    [JsonPropertyName("attEnabled")] public bool? AttEnabled { get; set; }
    [JsonPropertyName("preampMode")] public int? PreampMode { get; set; }
    [JsonPropertyName("tunerEnabled")] public bool? TunerEnabled { get; set; }
    [JsonPropertyName("displayContrast")] public int? DisplayContrast { get; set; }
    [JsonPropertyName("displayDimmer")] public int? DisplayDimmer { get; set; }
    [JsonPropertyName("displayLevel")] public double? DisplayLevel { get; set; }
    [JsonPropertyName("displayPeak")] public int? DisplayPeak { get; set; }
    [JsonPropertyName("displayMarker")] public bool? DisplayMarker { get; set; }
    [JsonPropertyName("micGain")] public int? MicGain { get; set; }
    [JsonPropertyName("amcLevel")] public int? AmcLevel { get; set; }
    [JsonPropertyName("voxEnabled")] public bool? VoxEnabled { get; set; }
    [JsonPropertyName("voxGain")] public int? VoxGain { get; set; }
    [JsonPropertyName("voxDelayMs")] public int? VoxDelayMs { get; set; }
    [JsonPropertyName("smeterDb")] public double? SmeterDb { get; set; }
    [JsonPropertyName("subSmeterDb")] public double? SubSmeterDb { get; set; }
    [JsonPropertyName("singleReceive")] public bool? SingleReceive { get; set; }
    [JsonPropertyName("audioChannelsSwapped")] public bool? AudioChannelsSwapped { get; set; }
    [JsonPropertyName("txMeters")] public TxMetersWire? TxMeters { get; set; }
    [JsonPropertyName("dnfEnabled")] public bool? DnfEnabled { get; set; }
    [JsonPropertyName("agcMode")] public int? AgcMode { get; set; }
    [JsonPropertyName("micEQEnabled")] public bool? MicEqEnabled { get; set; }
    [JsonPropertyName("procLevel")] public int? ProcLevel { get; set; }
    [JsonPropertyName("nbLevel")] public int? NbLevel { get; set; }
    [JsonPropertyName("dnrLevel")] public int? DnrLevel { get; set; }
    [JsonPropertyName("filterWidthIndex")] public int? FilterWidthIndex { get; set; }
    [JsonPropertyName("ifShiftHz")] public int? IfShiftHz { get; set; }
    [JsonPropertyName("notchEnabled")] public bool? NotchEnabled { get; set; }
    [JsonPropertyName("notchHz")] public int? NotchHz { get; set; }
    [JsonPropertyName("contourEnabled")] public bool? ContourEnabled { get; set; }
    [JsonPropertyName("contourHz")] public int? ContourHz { get; set; }
    [JsonPropertyName("apfEnabled")] public bool? ApfEnabled { get; set; }
    [JsonPropertyName("apfHz")] public int? ApfHz { get; set; }
    [JsonPropertyName("narrowEnabled")] public bool? NarrowEnabled { get; set; }
    [JsonPropertyName("narrowWidthHz")] public int? NarrowWidthHz { get; set; }
    /// 0 MAIN, 1 SUB.
    [JsonPropertyName("filterSide")] public int? FilterSide { get; set; }
    [JsonPropertyName("antSelect")] public int? AntSelect { get; set; }
    [JsonPropertyName("txwEnabled")] public bool? TxwEnabled { get; set; }
    [JsonPropertyName("splitEnabled")] public bool? SplitEnabled { get; set; }
    /// 0 MAIN, 1 SUB.
    [JsonPropertyName("txSide")] public int? TxSide { get; set; }
    [JsonPropertyName("squelchType")] public int? SquelchType { get; set; }
    [JsonPropertyName("ctcssToneIndex")] public int? CtcssToneIndex { get; set; }
    [JsonPropertyName("dcsCodeIndex")] public int? DcsCodeIndex { get; set; }
    [JsonPropertyName("repeaterShiftMode")] public int? RepeaterShiftMode { get; set; }
    [JsonPropertyName("aprsBeaconType")] public int? AprsBeaconType { get; set; }
    [JsonPropertyName("fmChannelStep")] public int? FmChannelStep { get; set; }
    [JsonPropertyName("c4fmCallsign")] public string? C4fmCallsign { get; set; }
    [JsonPropertyName("c4fmReflector")] public string? C4fmReflector { get; set; }
    [JsonPropertyName("aprsActive")] public bool AprsActive { get; set; }
    [JsonPropertyName("aprsLastCallsign")] public string? AprsLastCallsign { get; set; }
    [JsonPropertyName("aprsSubActive")] public bool AprsSubActive { get; set; }
    [JsonPropertyName("aprsSubLastCallsign")] public string? AprsSubLastCallsign { get; set; }
    [JsonPropertyName("vfoMemoryMode")] public VfoMemoryModeWire? VfoMemoryMode { get; set; }
    [JsonPropertyName("memoryChannel")] public int? MemoryChannel { get; set; }
    [JsonPropertyName("memoryChannelTag")] public string? MemoryChannelTag { get; set; }
    [JsonPropertyName("subVfoMemoryMode")] public VfoMemoryModeWire? SubVfoMemoryMode { get; set; }
    [JsonPropertyName("subMemoryChannel")] public int? SubMemoryChannel { get; set; }
    [JsonPropertyName("subMemoryChannelTag")] public string? SubMemoryChannelTag { get; set; }
    /// "stopped" / "scanning" / "paused".
    [JsonPropertyName("memoryScan")] public string? MemoryScan { get; set; }
    /// 0 MAIN, 1 SUB.
    [JsonPropertyName("memoryScanSide")] public int? MemoryScanSide { get; set; }
    [JsonPropertyName("transmitEnabled")] public bool TransmitEnabled { get; set; }
}

/// TXMeterReadings (MeterSelection.swift): raw RM values, 0-255.
public sealed class TxMetersWire
{
    [JsonPropertyName("comp")] public int? Comp { get; set; }
    [JsonPropertyName("alc")] public int? Alc { get; set; }
    [JsonPropertyName("idd")] public int? Idd { get; set; }
    [JsonPropertyName("vdd")] public int? Vdd { get; set; }
}

/// VFOMemoryMode in Swift's synthesized enum-with-payload coding:
/// `{"vfo":{}}`, `{"memory":{}}` or `{"other":{"rawP2":n}}`.
[JsonConverter(typeof(VfoMemoryModeWireConverter))]
public sealed record VfoMemoryModeWire(int RawP2)
{
    /// The raw "VM" P2: 0 VFO, 11 Memory, anything else `other`.
    public static VfoMemoryModeWire FromRawP2(int rawP2) => new(rawP2);
}

public sealed class VfoMemoryModeWireConverter : JsonConverter<VfoMemoryModeWire>
{
    public override VfoMemoryModeWire Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("vfoMemoryMode: expected an object");
        }
        foreach (var property in root.EnumerateObject())
        {
            switch (property.Name)
            {
                case "vfo":
                    return new VfoMemoryModeWire(0);
                case "memory":
                    return new VfoMemoryModeWire(11);
                case "other":
                    return new VfoMemoryModeWire(property.Value.GetProperty("rawP2").GetInt32());
            }
        }
        throw new JsonException("vfoMemoryMode: no vfo/memory/other key");
    }

    public override void Write(Utf8JsonWriter writer, VfoMemoryModeWire value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        switch (value.RawP2)
        {
            case 0:
                writer.WriteStartObject("vfo");
                writer.WriteEndObject();
                break;
            case 11:
                writer.WriteStartObject("memory");
                writer.WriteEndObject();
                break;
            default:
                writer.WriteStartObject("other");
                writer.WriteNumber("rawP2", value.RawP2);
                writer.WriteEndObject();
                break;
        }
        writer.WriteEndObject();
    }
}

/// What the hub's state needs from outside Models/RigState: values that
/// live on MainWindow (the slow tier's FR/ST/FT reads, the APRS indicator),
/// the Enable Transmit switch and the swap tracker.
public sealed record HubStateExtras(
    bool TransmitEnabled,
    bool? AudioChannelsSwapped = null,
    bool? SingleReceive = null,
    bool? SplitEnabled = null,
    bool? TxSideSub = null,
    bool AprsActive = false,
    string? AprsLastCallsign = null,
    bool AprsSubActive = false,
    string? AprsSubLastCallsign = null);

public static class HubWire
{
    /// Swift's reference date, 2001-01-01T00:00:00Z.
    public static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static double SwiftDate(DateTimeOffset date) => (date - ReferenceDate).TotalSeconds;

    public static string Serialize(RigStatePushWire push) => JsonSerializer.Serialize(push, JsonOptions);

    public static RigStatePushWire? Deserialize(string json) => JsonSerializer.Deserialize<RigStatePushWire>(json, JsonOptions);

    /// The list pushes and menu replies (HubListWire.cs), same options.
    public static string Serialize<T>(T message) => JsonSerializer.Serialize(message, JsonOptions);

    public static T? Deserialize<T>(string json) => JsonSerializer.Deserialize<T>(json, JsonOptions);

    public static DateTimeOffset FromSwiftDate(double seconds) => ReferenceDate.AddSeconds(seconds);
}

/// Models/RigState (+ <see cref="HubStateExtras"/>) → the wire. A field this
/// app has no value for is left out rather than guessed: `cwMessageStatus`
/// (the CW page's PLAY/RECORD are the app's own recorder, not the rig's
/// "RI" P3) and `txwEnabled` (not read here) are never sent.
public static class RigStateWireMapper
{
    public static RigStatePushWire Push(RigState s, HubStateExtras x) => new() { State = From(s, x) };

    public static RigStateWire From(RigState s, HubStateExtras x)
    {
        // C4FM isn't a RigMode case here; it's tracked beside the mode.
        // Main's mode is required on the wire, so an unread one is UNKNOWN
        // (Swift's own placeholder case) rather than a made-up mode.
        var mode = s.MainIsC4fm == true ? "C4FM" : s.Mode?.RawValue() ?? "UNKNOWN";
        var subMode = s.SubIsC4fm == true ? "C4FM" : s.SubMode?.RawValue();
        return new RigStateWire
        {
            FrequencyHz = s.FrequencyHz,
            Mode = mode,
            Band = s.FrequencyHz > 0 ? BandPlan.BandContaining(s.FrequencyHz)?.Name : null,
            PowerWatts = s.PowerWatts,
            Swr = s.Swr,
            Ptt = s.Ptt,
            LastUpdated = HubWire.SwiftDate(s.LastUpdated),
            SecondaryFrequencyHz = s.SecondaryFrequencyHz,
            SecondaryMode = subMode,
            PowerLevel = s.PowerLevel,
            BreakIn = s.BreakIn,
            KeyerEnabled = s.KeyerEnabled,
            CwSpeedWpm = s.CwSpeedWpm,
            CwPitchHz = s.CwPitchHz,
            BkDelayMs = s.BkDelayMs,
            CwSpot = s.CwSpot,
            MoniLevel = s.MoniLevel,
            MoxEnabled = s.MoxEnabled,
            AttEnabled = s.AttEnabled,
            PreampMode = s.PreampMode,
            TunerEnabled = s.TunerEnabled,
            DisplayContrast = s.DisplayContrast,
            DisplayDimmer = s.DisplayDimmer,
            DisplayLevel = s.DisplayLevel,
            DisplayPeak = s.DisplayPeak,
            DisplayMarker = s.DisplayMarker,
            MicGain = s.MicGain,
            AmcLevel = s.AmcLevel,
            VoxEnabled = s.VoxEnabled,
            VoxGain = s.VoxGain,
            VoxDelayMs = s.VoxDelayMs,
            SmeterDb = s.SmeterDb,
            SubSmeterDb = s.SubSmeterDb,
            SingleReceive = x.SingleReceive,
            AudioChannelsSwapped = x.AudioChannelsSwapped,
            TxMeters = s.TxMeters is { } tx
                ? new TxMetersWire { Comp = tx.Comp, Alc = tx.Alc, Idd = tx.Idd, Vdd = tx.Vdd }
                : null,
            DnfEnabled = s.DnfEnabled,
            AgcMode = s.AgcMode,
            MicEqEnabled = s.MicEqEnabled,
            ProcLevel = s.ProcLevel,
            NbLevel = s.NbLevel,
            DnrLevel = s.DnrLevel,
            FilterWidthIndex = s.FilterWidthIndex,
            IfShiftHz = s.IfShiftHz,
            NotchEnabled = s.NotchEnabled,
            NotchHz = s.NotchHz,
            ContourEnabled = s.ContourEnabled,
            ContourHz = s.ContourHz,
            ApfEnabled = s.ApfEnabled,
            ApfHz = s.ApfHz,
            NarrowEnabled = s.NarrowEnabled,
            NarrowWidthHz = s.NarrowWidthHz,
            FilterSide = (int)s.FilterSide,
            AntSelect = s.AntSelect,
            SplitEnabled = x.SplitEnabled,
            TxSide = x.TxSideSub is { } sub ? (sub ? 1 : 0) : null,
            SquelchType = s.SquelchType,
            CtcssToneIndex = s.CtcssToneIndex,
            DcsCodeIndex = s.DcsCodeIndex,
            RepeaterShiftMode = s.RepeaterShiftMode,
            AprsBeaconType = s.AprsBeaconType,
            FmChannelStep = s.FmChannelStep,
            C4fmCallsign = s.C4fmCallsign,
            C4fmReflector = s.C4fmReflector,
            AprsActive = x.AprsActive,
            AprsLastCallsign = x.AprsActive ? x.AprsLastCallsign : null,
            AprsSubActive = x.AprsSubActive,
            AprsSubLastCallsign = x.AprsSubActive ? x.AprsSubLastCallsign : null,
            VfoMemoryMode = s.VfoMemoryRaw is { } vm ? VfoMemoryModeWire.FromRawP2(vm) : null,
            MemoryChannel = s.MemoryChannel,
            MemoryChannelTag = s.MemoryChannelTag,
            SubVfoMemoryMode = s.SubVfoMemoryRaw is { } svm ? VfoMemoryModeWire.FromRawP2(svm) : null,
            SubMemoryChannel = s.SubMemoryChannel,
            SubMemoryChannelTag = s.SubMemoryChannelTag,
            MemoryScan = s.MemoryScan switch
            {
                MemoryScanState.Stopped => "stopped",
                MemoryScanState.Scanning => "scanning",
                MemoryScanState.Paused => "paused",
                _ => null,
            },
            MemoryScanSide = s.MemoryScan is null ? null : s.MemoryScanSub ? 1 : 0,
            TransmitEnabled = x.TransmitEnabled,
        };
    }
}

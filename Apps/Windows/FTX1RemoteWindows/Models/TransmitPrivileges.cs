using System.Text.Json;
using System.Text.Json.Serialization;

namespace FTX1RemoteWindows.Models;

/// Port of Sources/FTX1Core/Licensing/TransmitPrivileges.swift (the Mac's
/// license-class guardrail) — keep the two in step by hand. What a
/// privilege segment allows, in the FCC's broad terms (47 CFR §97.305's
/// "CW", "phone", "RTTY, data"). Image (SSTV) has no rig mode of its own:
/// sent through DATA-U it counts as data, through USB/LSB as phone.
[JsonConverter(typeof(TransmitEmissionJsonConverter))]
public enum TransmitEmission
{
    Cw,
    Phone,
    Data,
}

public static class TransmitEmissionExtensions
{
    public static readonly IReadOnlyList<TransmitEmission> All = [TransmitEmission.Cw, TransmitEmission.Phone, TransmitEmission.Data];

    public static string DisplayName(this TransmitEmission emission) => emission switch
    {
        TransmitEmission.Cw => "CW",
        TransmitEmission.Phone => Loc.S("common.phone"),
        _ => Loc.S("common.data"),
    };

    /// Swift's raw values ("cw", "phone", "data"), so a profile exported on
    /// the Mac imports here and the other way round.
    public static string RawValue(this TransmitEmission emission) => emission switch
    {
        TransmitEmission.Cw => "cw",
        TransmitEmission.Phone => "phone",
        _ => "data",
    };
}

public sealed class TransmitEmissionJsonConverter : JsonConverter<TransmitEmission>
{
    public override TransmitEmission Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "cw" => TransmitEmission.Cw,
            "phone" => TransmitEmission.Phone,
            "data" => TransmitEmission.Data,
            var other => throw new JsonException($"Unknown emission \"{other}\""),
        };

    public override void Write(Utf8JsonWriter writer, TransmitEmission value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.RawValue());
}

/// The transmitting side's signal: frequency and mode, the gate's input.
/// This app's RigMode has no C4FM (RigState carries MainIsC4fm/SubIsC4fm
/// beside it), so C4FM is a flag here; Swift's RigMode.c4fm.
public readonly record struct TransmitSignal(long FrequencyHz, RigMode? Mode, bool IsC4fm = false)
{
    /// Swift's RigMode raw value — what PrivilegeSegment.OnlyModes holds.
    /// Null while the mode isn't known.
    public string? ModeKey => IsC4fm ? "C4FM" : Mode?.RawValue();

    public string ModeDisplayName => IsC4fm ? "C4FM" : Mode?.DisplayName() ?? Loc.S("common.anUnknownMode");

    /// The emission this mode transmits. C4FM is digital *voice*, which the
    /// FCC counts as phone; DATA-FM and RTTY are data. Null while the mode
    /// isn't known, so nothing keys before it has been read.
    public TransmitEmission? Emission => IsC4fm ? TransmitEmission.Phone : Mode switch
    {
        RigMode.Cw => TransmitEmission.Cw,
        RigMode.Usb or RigMode.Lsb or RigMode.Am or RigMode.Fm => TransmitEmission.Phone,
        RigMode.Rtty or RigMode.DataUsb or RigMode.DataFm => TransmitEmission.Data,
        _ => null,
    };

    /// The spectrum the transmission occupies — what has to fit inside the
    /// privileges, not just the dial frequency (an LSB signal at 7.176 MHz
    /// reaches down to 7.173). Approximations: SSB and DATA-U use the
    /// FTX-1's default SSB TX BPF (100–2900 Hz); CW ±100 Hz of keying
    /// sidebands; RTTY ±300 Hz; AM ±3 kHz; FM and DATA-FM ±8 kHz (16K0F3E);
    /// C4FM ±6.25 kHz (a 12.5 kHz channel). Null while the mode isn't known.
    public (long Lower, long Upper)? OccupiedSpectrum
    {
        get
        {
            var hz = FrequencyHz;
            if (IsC4fm)
            {
                return (hz - 6_250, hz + 6_250);
            }
            return Mode switch
            {
                RigMode.Usb or RigMode.DataUsb => (hz + 100, hz + 2_900),
                RigMode.Lsb => (hz - 2_900, hz - 100),
                RigMode.Cw => (hz - 100, hz + 100),
                RigMode.Rtty => (hz - 300, hz + 300),
                RigMode.Am => (hz - 3_000, hz + 3_000),
                RigMode.Fm or RigMode.DataFm => (hz - 8_000, hz + 8_000),
                _ => null,
            };
        }
    }
}

/// A stretch of spectrum and what may be sent in it. OnlyModes narrows the
/// emissions further where the rules name specific modes (US 60 m: USB, CW
/// and data only; Novice/Technician 28.3–28.5 MHz: SSB and CW), as Swift
/// RigMode raw values ("USB", "PKTUSB", "C4FM"…). JSON keys match the
/// Swift Codable form.
public sealed class PrivilegeSegment
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("lowerHz")] public long LowerHz { get; set; }
    [JsonPropertyName("upperHz")] public long UpperHz { get; set; }
    [JsonPropertyName("emissions")] public HashSet<TransmitEmission> Emissions { get; set; } = [];
    [JsonPropertyName("onlyModes")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public HashSet<string>? OnlyModes { get; set; }

    public PrivilegeSegment()
    {
    }

    public PrivilegeSegment(long lowerHz, long upperHz, IEnumerable<TransmitEmission> emissions, IEnumerable<string>? onlyModes = null)
    {
        LowerHz = lowerHz;
        UpperHz = upperHz;
        Emissions = [.. emissions];
        OnlyModes = onlyModes is null ? null : [.. onlyModes];
    }

    public bool Allows(TransmitSignal signal)
    {
        if (signal.Emission is not { } emission || !Emissions.Contains(emission))
        {
            return false;
        }
        return OnlyModes is null || (signal.ModeKey is { } key && OnlyModes.Contains(key));
    }

    /// A copy with a new Id, for Copy to Custom.
    public PrivilegeSegment Copy() => new(LowerHz, UpperHz, Emissions, OnlyModes);
}

/// A set of transmit privileges: a US license class, an ITU region's
/// allocation, or the operator's own table.
public sealed class PrivilegeProfile
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("segments")] public List<PrivilegeSegment> Segments { get; set; } = [];

    public PrivilegeProfile()
    {
    }

    public PrivilegeProfile(string name, IEnumerable<PrivilegeSegment> segments)
    {
        Name = name;
        Segments = [.. segments];
    }

    /// Whether the signal fits entirely inside segments that allow its
    /// mode. Neighbouring segments that both allow it are treated as one,
    /// so CW right at the US 20 m phone edge (allowed on both sides) passes.
    public bool Allows(TransmitSignal signal)
    {
        if (signal.OccupiedSpectrum is not { } occupied)
        {
            return false;
        }
        var ranges = Segments
            .Where(s => s.Allows(signal) && s.LowerHz <= s.UpperHz)
            .Select(s => (Lower: s.LowerHz, Upper: s.UpperHz))
            .OrderBy(r => r.Lower);
        var merged = new List<(long Lower, long Upper)>();
        foreach (var range in ranges)
        {
            if (merged.Count > 0 && range.Lower <= merged[^1].Upper + 1)
            {
                merged[^1] = (merged[^1].Lower, Math.Max(merged[^1].Upper, range.Upper));
            }
            else
            {
                merged.Add(range);
            }
        }
        return merged.Any(r => r.Lower <= occupied.Lower && occupied.Lower <= r.Upper
                               && r.Lower <= occupied.Upper && occupied.Upper <= r.Upper);
    }

    public PrivilegeProfile Copy(string? name = null) => new(name ?? Name, Segments.Select(s => s.Copy()));

    private static readonly JsonSerializerOptions ExportOptions = new() { WriteIndented = true };

    /// The Mac's export format (Swift Codable keys), so files move between
    /// the two apps.
    public string ToJson() => JsonSerializer.Serialize(this, ExportOptions);

    /// Null if the text isn't a privileges file.
    public static PrivilegeProfile? FromJson(string json)
    {
        try
        {
            var profile = JsonSerializer.Deserialize<PrivilegeProfile>(json);
            return profile is { Segments: not null } && profile.Segments.All(s => s.Emissions is not null) ? profile : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// Which privileges the transmit gate applies, in its stored form (the
/// Mac's PrivilegeChoice.rawValue, so a later preset added in between
/// never shifts what's saved): "off" (just the amateur bands, BandPlan),
/// a PrivilegePreset's raw value, or "custom".
public static class PrivilegeChoice
{
    public const string Off = "off";
    public const string Custom = "custom";

    /// Unknown values read as off, as on the Mac.
    public static string Normalize(string? raw) =>
        raw == Custom || PrivilegePresets.ByRawValue(raw) is not null ? raw! : Off;

    /// What the gate applies for a choice: null = off.
    public static PrivilegeProfile? Profile(string? choice, PrivilegeProfile custom) => Normalize(choice) switch
    {
        Off => null,
        Custom => custom,
        var raw => PrivilegePresets.ByRawValue(raw)!.Profile,
    };
}

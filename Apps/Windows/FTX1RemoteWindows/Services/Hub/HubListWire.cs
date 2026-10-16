using System.Text.Json.Serialization;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services.Hub;

// Phase 4's messages (Apps/Windows/README.md, "Desktop hub for the iPad"):
// the memory list and APRS history pushes and the Deep Settings read pair,
// copied from Sources/FTX1Core/Networking/WireMessage.swift's
// MemoryListPush, APRSListPush, MenuItemReadRequest and MenuItemPush. As
// with the state push, the shapes are Swift's (Tests/WireFixtures has one of
// each); dates are seconds since 2001, nil optionals are left out. Compiled
// into the test project too, so keep it free of WinUI types.

/// `{"type":"memory_list","list":{…}}`.
public sealed class MemoryListPushWire
{
    [JsonPropertyName("type")] public string Type { get; set; } = "memory_list";
    [JsonPropertyName("list")] public MemoryListSnapshotWire List { get; set; } = new();
}

/// MemoryListStore.swift's MemoryListSnapshot.
public sealed class MemoryListSnapshotWire
{
    [JsonPropertyName("entries")] public List<MemoryChannelEntryWire> Entries { get; set; } = [];
    /// When the last full read finished (seconds since 2001); null before
    /// the first.
    [JsonPropertyName("scanned")] public double? Scanned { get; set; }
    /// The channel being read, only while a read runs.
    [JsonPropertyName("scanningChannel")] public int? ScanningChannel { get; set; }
}

/// MemoryChannelEntry.swift — the same fields as Models/MemoryChannelEntry.
public sealed class MemoryChannelEntryWire
{
    [JsonPropertyName("channel")] public int Channel { get; set; }
    [JsonPropertyName("frequencyHz")] public long FrequencyHz { get; set; }
    /// The raw "MR" mode character, as a string.
    [JsonPropertyName("modeCode")] public string ModeCode { get; set; } = "";
    [JsonPropertyName("toneMode")] public int ToneMode { get; set; }
    [JsonPropertyName("shift")] public int Shift { get; set; }
    [JsonPropertyName("tag")] public string? Tag { get; set; }
}

/// `{"type":"aprs_list","stations":[…],"messages":[…]}` — the whole history.
public sealed class AprsListPushWire
{
    [JsonPropertyName("type")] public string Type { get; set; } = "aprs_list";
    [JsonPropertyName("stations")] public List<AprsStationWire> Stations { get; set; } = [];
    [JsonPropertyName("messages")] public List<AprsMessageWire> Messages { get; set; } = [];
}

/// APRSModels.swift's APRSStation.
public sealed class AprsStationWire
{
    [JsonPropertyName("callsign")] public string Callsign { get; set; } = "";
    [JsonPropertyName("latitude")] public double? Latitude { get; set; }
    [JsonPropertyName("longitude")] public double? Longitude { get; set; }
    [JsonPropertyName("symbolTable")] public string? SymbolTable { get; set; }
    [JsonPropertyName("symbolCode")] public string? SymbolCode { get; set; }
    [JsonPropertyName("comment")] public string? Comment { get; set; }
    [JsonPropertyName("lastHeardAt")] public double LastHeardAt { get; set; }
    /// "main" or "sub".
    [JsonPropertyName("source")] public string Source { get; set; } = "main";
}

/// APRSModels.swift's APRSMessage. `id` is the iPad's list identity, so it
/// has to stay the same across pushes: AprsStore's stored AprsMessage.Id.
public sealed class AprsMessageWire
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("from")] public string From { get; set; } = "";
    [JsonPropertyName("to")] public string To { get; set; } = "";
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("messageID")] public string? MessageId { get; set; }
    [JsonPropertyName("receivedAt")] public double ReceivedAt { get; set; }
    [JsonPropertyName("source")] public string Source { get; set; } = "main";
}

/// Client → hub: `{"type":"read_menu_item","p1":…,"p2":…,"p3":…}`.
public sealed class MenuItemReadRequestWire
{
    [JsonPropertyName("type")] public string Type { get; set; } = "read_menu_item";
    [JsonPropertyName("p1")] public int P1 { get; set; }
    [JsonPropertyName("p2")] public int P2 { get; set; }
    [JsonPropertyName("p3")] public int P3 { get; set; }

    /// Each of P1–P3 fits the "EX" command's two digits. Anything else is
    /// answered unreadable without reaching the rig.
    [JsonIgnore]
    public bool IsValidAddress => P1 is >= 0 and <= 99 && P2 is >= 0 and <= 99 && P3 is >= 0 and <= 99;
}

/// Hub → the asking client only: the item's raw P4, as the Deep Settings
/// dialog reads it. `value` is left out entirely when it couldn't be read.
public sealed class MenuItemPushWire
{
    [JsonPropertyName("type")] public string Type { get; set; } = "menu_item";
    [JsonPropertyName("p1")] public int P1 { get; set; }
    [JsonPropertyName("p2")] public int P2 { get; set; }
    [JsonPropertyName("p3")] public int P3 { get; set; }
    [JsonPropertyName("value")] public string? Value { get; set; }
}

/// MemoryListStore / AprsStore contents → the wire.
public static class HubListWireMapper
{
    public static MemoryListPushWire MemoryList(IEnumerable<MemoryChannelEntry> entries, DateTimeOffset? scanned,
        int? scanningChannel) => new()
    {
        List = new MemoryListSnapshotWire
        {
            Entries = entries.Select(e => new MemoryChannelEntryWire
            {
                Channel = e.Channel,
                FrequencyHz = e.FrequencyHz,
                ModeCode = e.ModeCode,
                ToneMode = e.ToneMode,
                Shift = e.Shift,
                Tag = string.IsNullOrWhiteSpace(e.Tag) ? null : e.Tag,
            }).ToList(),
            Scanned = scanned is { } date ? HubWire.SwiftDate(date) : null,
            ScanningChannel = scanningChannel,
        },
    };

    public static AprsListPushWire AprsList(IEnumerable<AprsStation> stations, IEnumerable<AprsMessage> messages) => new()
    {
        Stations = stations.Select(s => new AprsStationWire
        {
            Callsign = s.Callsign,
            Latitude = s.Latitude,
            Longitude = s.Longitude,
            SymbolTable = s.SymbolTable,
            SymbolCode = s.SymbolCode,
            Comment = s.Comment,
            LastHeardAt = HubWire.SwiftDate(s.LastHeardAt),
            Source = Source(s.Source),
        }).ToList(),
        Messages = messages.Select(m => new AprsMessageWire
        {
            Id = m.Id,
            From = m.From,
            To = m.To,
            Text = m.Text,
            MessageId = m.MessageId,
            ReceivedAt = HubWire.SwiftDate(m.ReceivedAt),
            Source = Source(m.Source),
        }).ToList(),
    };

    private static string Source(AprsSource source) => source == AprsSource.Sub ? "sub" : "main";
}

/// "Something changed, push it at most once per interval": the first change
/// goes out at once, later ones within the interval are coalesced into one
/// push when it ends. The caller polls <see cref="TakeDue"/> (MainWindow's
/// 100 ms hub timer), so a trailing push is never lost. One thread only.
public sealed class HubPushThrottle(TimeSpan interval)
{
    private bool _dirty;
    private long? _lastSentMs;

    public void MarkDirty() => _dirty = true;

    /// True when a push is due now (something changed, and the interval has
    /// passed since the last one); counts it as sent.
    public bool TakeDue(long nowMs)
    {
        if (!_dirty || (_lastSentMs is { } last && nowMs - last < interval.TotalMilliseconds))
        {
            return false;
        }
        _dirty = false;
        _lastSentMs = nowMs;
        return true;
    }
}

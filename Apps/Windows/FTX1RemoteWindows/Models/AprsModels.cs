using System.Text.Json.Serialization;

namespace FTX1RemoteWindows.Models;

/// Which audio channel a packet was decoded from — Main and Sub each have
/// their own AprsDecoder, gated on their own VFO's frequency (the Mac's
/// APRSSource, Sources/FTX1Core/APRS/APRSModels.swift).
[JsonConverter(typeof(JsonStringEnumConverter<AprsSource>))]
public enum AprsSource
{
    Main,
    Sub,
}

/// A station heard on APRS, keyed by callsign including SSID. Updated in
/// place by later packets; Source is whichever channel heard it last, not
/// part of the key (one station heard on both is one row) — the Mac's
/// APRSStation.
public sealed class AprsStation
{
    public string Callsign { get; set; } = "";
    public double? Latitude { get; set; }
    public double? Longitude { get; set; }
    public string? SymbolTable { get; set; }
    public string? SymbolCode { get; set; }
    public string? Comment { get; set; }
    public DateTimeOffset LastHeardAt { get; set; }
    public AprsSource Source { get; set; }
}

/// A decoded APRS message. Every one is its own entry, never merged — the
/// Mac's APRSMessage.
public sealed class AprsMessage
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string From { get; set; } = "";
    public string To { get; set; } = "";
    public string Text { get; set; } = "";
    public string? MessageId { get; set; }
    public DateTimeOffset ReceivedAt { get; set; }
    public AprsSource Source { get; set; }
}

using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace FTX1RemoteWindows.Services.FreeDv;

/// FreeDV Reporter's wire format (qso.freedv.org) — the Mac's
/// FreeDVReporterProtocol: Socket.IO v4 over an Engine.IO v4 WebSocket, as
/// freedv-backend's FreeDVReporter/SocketIoClient (BSD-2) speak it. Pure, so
/// the framing and the event shapes are unit-tested apart from the network.
///
/// Engine.IO packets are one type digit + payload: "0" open (JSON with
/// pingInterval/pingTimeout in ms), "2" ping (answer "3"), "1" close, "4"
/// message. A message carries a Socket.IO packet: "0" connect (the client's
/// carries the auth JSON), "2" event (["name", {...}]), "1" disconnect, "4"
/// connect error.
public static class FreeDvReporterProtocol
{
    public const string DefaultHost = "qso.freedv.org";
    /// freedv-backend's FREEDV_REPORTER_PROTOCOL_VERSION.
    public const int ProtocolVersion = 2;
    /// How FreeDV names RADE V1 in tx_report/rx_report.
    public const string RadeModeName = "RADEV1";

    public static Uri Url(string host = DefaultHost, bool secure = true) =>
        new($"{(secure ? "wss" : "ws")}://{host}/socket.io/?EIO=4&transport=websocket");

    public enum Kind
    {
        Open,
        Ping,
        Close,
        /// The Socket.IO namespace connected.
        Connected,
        Disconnected,
        ConnectError,
        Event,
        Unknown,
    }

    /// What the server sent, decoded as far as the client needs: the ping
    /// timing (Open), the error text (ConnectError), or the event's name and
    /// payload.
    public sealed record Incoming(
        Kind Kind,
        double PingInterval = 0,
        double PingTimeout = 0,
        string Name = "",
        JsonElement? Payload = null);

    public static Incoming Parse(string frame)
    {
        if (frame.Length == 0)
        {
            return new Incoming(Kind.Unknown);
        }
        var body = frame[1..];
        switch (frame[0])
        {
            case '0':
                var open = Json(body);
                return new Incoming(Kind.Open,
                    PingInterval: (Number(open, "pingInterval") ?? 25_000) / 1000,
                    PingTimeout: (Number(open, "pingTimeout") ?? 20_000) / 1000);
            case '1':
                return new Incoming(Kind.Close);
            case '2':
                return new Incoming(Kind.Ping);
            case '4':
                return ParseSocketIo(body);
            default:
                return new Incoming(Kind.Unknown);
        }
    }

    private static Incoming ParseSocketIo(string packet)
    {
        if (packet.Length == 0)
        {
            return new Incoming(Kind.Unknown);
        }
        var body = packet[1..];
        switch (packet[0])
        {
            case '0':
                return new Incoming(Kind.Connected);
            case '1':
                return new Incoming(Kind.Disconnected);
            case '4':
                return new Incoming(Kind.ConnectError, Name: Text(Json(body), "message") ?? body);
            case '2':
                if (Json(body) is { ValueKind: JsonValueKind.Array } array && array.GetArrayLength() > 0
                    && array[0].ValueKind == JsonValueKind.String)
                {
                    return new Incoming(Kind.Event, Name: array[0].GetString()!,
                        Payload: array.GetArrayLength() > 1 ? array[1] : null);
                }
                return new Incoming(Kind.Unknown);
            default:
                return new Incoming(Kind.Unknown);
        }
    }

    public const string Pong = "3";

    /// The namespace connect with the station's auth: role "report".
    public static string ConnectFrame(string callsign, string gridSquare, string version, bool receiveOnly, string os) =>
        "40" + Serialize(new Dictionary<string, object>
        {
            ["callsign"] = callsign,
            ["grid_square"] = gridSquare,
            ["os"] = os,
            ["protocol_version"] = ProtocolVersion,
            ["role"] = "report",
            ["rx_only"] = receiveOnly,
            ["version"] = version,
        });

    /// A read-only connect (the website's role): nothing about us is sent.
    /// Used by the live test only.
    public static string ViewConnectFrame() => "40" + Serialize(new Dictionary<string, object>
    {
        ["protocol_version"] = ProtocolVersion,
        ["role"] = "view",
    });

    private static string EventFrame(string name, Dictionary<string, object> payload) =>
        "42" + Serialize(new object[] { name, payload });

    public static string FrequencyChange(long hz) =>
        EventFrame("freq_change", new() { ["freq"] = Math.Max(0, hz) });

    public static string TransmitReport(bool transmitting, string mode = RadeModeName) =>
        EventFrame("tx_report", new() { ["mode"] = mode, ["transmitting"] = transmitting });

    public static string ReceiveReport(string callsign, int snrDb, string mode = RadeModeName) =>
        EventFrame("rx_report", new() { ["callsign"] = callsign, ["mode"] = mode, ["snr"] = snrDb });

    public static string Message(string text) => EventFrame("message_update", new() { ["message"] = text });

    private static readonly JsonSerializerOptions Options = new()
    {
        // This goes into a WebSocket frame, not into HTML: keep "+" and
        // accented characters as they are.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static string Serialize(object value) => JsonSerializer.Serialize(value, Options);

    private static JsonElement? Json(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            return document.RootElement.Clone();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    internal static double? Number(JsonElement? json, string name) =>
        json is { ValueKind: JsonValueKind.Object } o && o.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : null;

    internal static string? Text(JsonElement? json, string name) =>
        json is { ValueKind: JsonValueKind.Object } o && o.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    internal static bool? Flag(JsonElement? json, string name) =>
        json is { ValueKind: JsonValueKind.Object } o && o.TryGetProperty(name, out var value)
            && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : null;

    /// The server's timestamps are ISO 8601, with or without fractions or a
    /// zone (none: UTC, as Python's isoformat writes it).
    public static DateTime? Timestamp(string? text) =>
        text is not null && DateTimeOffset.TryParseExact(text,
            ["yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK", "yyyy-MM-dd'T'HH:mm:ssK"],
            CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
            ? parsed.UtcDateTime
            : null;
}

/// One station on FreeDV Reporter, as the station list shows it.
public sealed record FreeDvReporterStation
{
    /// The server's session id.
    public required string Id { get; init; }
    public required string Callsign { get; init; }
    public string GridSquare { get; init; } = "";
    public string Version { get; init; } = "";
    public bool ReceiveOnly { get; init; }
    public long? FrequencyHz { get; init; }
    public string? Mode { get; init; }
    public bool Transmitting { get; init; }
    /// The station's free-text status message.
    public string Message { get; init; } = "";
    /// The last callsign this station reported hearing, with the SNR.
    public string? LastHeardCallsign { get; init; }
    public double? LastHeardSnr { get; init; }
    /// When the server last changed anything about this station.
    public DateTime? LastUpdateUtc { get; init; }
}

/// Applies FreeDV Reporter events to the station list — the Mac's
/// FreeDVReporterStations.
public sealed class FreeDvReporterStations
{
    private readonly Dictionary<string, FreeDvReporterStation> _stations = [];

    public IReadOnlyDictionary<string, FreeDvReporterStation> Stations => _stations;

    public void Clear() => _stations.Clear();

    /// Most recently updated first.
    public List<FreeDvReporterStation> Sorted() =>
        [.. _stations.Values
            .OrderByDescending(s => s.LastUpdateUtc ?? DateTime.MinValue)
            .ThenBy(s => s.Callsign, StringComparer.Ordinal)];

    /// Returns true when something changed.
    public bool Apply(string name, JsonElement? payload)
    {
        if (name == "bulk_update")
        {
            if (payload is not { ValueKind: JsonValueKind.Array } events)
            {
                return false;
            }
            var changed = false;
            foreach (var item in events.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Array || item.GetArrayLength() == 0
                    || item[0].ValueKind != JsonValueKind.String)
                {
                    continue;
                }
                changed |= Apply(item[0].GetString()!, item.GetArrayLength() > 1 ? item[1] : null);
            }
            return changed;
        }
        if (FreeDvReporterProtocol.Text(payload, "sid") is not { } sid)
        {
            return false;
        }
        var lastUpdate = FreeDvReporterProtocol.Timestamp(FreeDvReporterProtocol.Text(payload, "last_update"));
        _stations.TryGetValue(sid, out var known);
        FreeDvReporterStation station;
        switch (name)
        {
            case "new_connection":
                if (FreeDvReporterProtocol.Text(payload, "callsign") is not { } callsign)
                {
                    return false;
                }
                station = (known ?? new FreeDvReporterStation { Id = sid, Callsign = callsign }) with
                {
                    Callsign = callsign,
                    GridSquare = FreeDvReporterProtocol.Text(payload, "grid_square") ?? known?.GridSquare ?? "",
                    Version = FreeDvReporterProtocol.Text(payload, "version") ?? known?.Version ?? "",
                    ReceiveOnly = FreeDvReporterProtocol.Flag(payload, "rx_only") ?? known?.ReceiveOnly ?? false,
                };
                break;
            case "remove_connection":
                return _stations.Remove(sid);
            case "freq_change" when known is not null:
                var hz = FreeDvReporterProtocol.Number(payload, "freq");
                station = known with { FrequencyHz = hz is > 0 ? (long)hz.Value : null };
                break;
            case "tx_report" when known is not null:
                station = known with
                {
                    Mode = FreeDvReporterProtocol.Text(payload, "mode") ?? known.Mode,
                    Transmitting = FreeDvReporterProtocol.Flag(payload, "transmitting") ?? false,
                };
                break;
            case "rx_report" when known is not null:
                station = known with
                {
                    LastHeardCallsign = FreeDvReporterProtocol.Text(payload, "callsign"),
                    LastHeardSnr = FreeDvReporterProtocol.Number(payload, "snr"),
                };
                break;
            case "message_update" when known is not null:
                station = known with { Message = FreeDvReporterProtocol.Text(payload, "message") ?? "" };
                break;
            default:
                return false;
        }
        _stations[sid] = station with { LastUpdateUtc = lastUpdate ?? station.LastUpdateUtc };
        return true;
    }
}

using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// A Wavelog server's REST API v2 — the Mac's Wavelog
/// (Sources/FTX1Core/Logbook/Wavelog.swift), which stays the source of
/// truth for the request and reply shapes (read there from Wavelog's
/// Api_v2.php, Api_v2_response.php and api_v2/*_resource.php, not docs).
/// The requests the app makes: log one QSO, check a token + station
/// location without writing (the API's own dry run), list the station
/// locations a token can see, and report the rig as a CAT radio.
///
/// - Auth: `Authorization: Bearer wl2_…`. v1 keys ("wl…" without the 2_)
///   are refused with 401 invalid_token.
/// - Replies: {"data": …, "meta": …} on success; {"error": {"code",
///   "message", "details"?}} otherwise, the HTTP status carrying the
///   meaning. Rate limiting is the exception: 429 with v1's {"status":
///   "failed", "reason"}.
/// - POST &lt;base&gt;/index.php/api/v2/qso with {station_profile_id,
///   import_type: "adif", adif, dryrun} → 201 {parsed, imported, skipped,
///   messages} (skipped = duplicates: a resend is safe); 400
///   validation_error when nothing imported; 403 forbidden for a location
///   that isn't the token owner's, insufficient_scope without qso:write. A
///   dry run answers 200 {dryrun: true, parsed} and writes nothing.
/// - GET &lt;base&gt;/index.php/api/v2/station → [{id, name, callsign,
///   gridsquare, active, …}] (needs station:read).
/// - POST &lt;base&gt;/index.php/api/v2/radio with {radio, frequency, mode,
///   frequency_rx?, mode_rx?, power?} (needs radio:write) → 200/201: an
///   upsert by radio name, the row WaveLogGate writes too. Hz, watts, modes
///   ≤10 characters.
///
/// Unlike v1, v2 doesn't refuse a record whose station_callsign differs
/// from the location's: it files it under the location's callsign.
/// `index.php/` is in every URL so servers without URL rewriting work too.
public static class Wavelog
{
    public sealed record Station(string Id, string Name, string Callsign, string Gridsquare, bool IsActive);

    public abstract record LogResult
    {
        /// Written (or, for a dry run, would be).
        public sealed record Created : LogResult;
        /// Already in the log — Wavelog's own duplicate check.
        public sealed record Duplicate : LogResult;
        /// Refused; the server's reason, as plain text.
        public sealed record Rejected(string Reason) : LogResult;
    }

    /// Anything short of an answer about the QSO itself: a bad URL, the
    /// server refusing the token (bad, missing scope, rate limit), an
    /// unusable reply or no reply. Message is the text the window shows.
    public sealed class ApiException(string message) : Exception(message)
    {
        public static ApiException BadUrl() => new(Loc.S("wavelog.theWavelogURLIsnt"));

        public static ApiException Refused(string message) => new(Loc.F("common.wavelogX", message));

        public static ApiException UnexpectedReply(int status, string body) => new(body.Length == 0
            ? Loc.F("wavelog.unexpectedReplyFromWavelog2", status)
            : Loc.F("wavelog.unexpectedReplyFromWavelog", status, body));
    }

    /// What a CAT client reports about the rig: the transmit frequency and
    /// mode, and the receive side's only when it differs (split).
    public sealed record RadioStatus(long FrequencyHz, string? Mode, long? FrequencyRxHz = null, string? ModeRx = null, double? PowerWatts = null);

    /// The CAT mode string Wavelog's QSO form understands (its
    /// radiohelpers.js: USB/LSB/CW/AM/FM/RTTY, PKTUSB for data; digital
    /// voice is FM there). DATA-FM has no entry of its own, so it's FM too.
    /// C4FM is a flag here, not a RigMode.
    public static string? CatMode(RigMode? mode, bool isC4fm = false)
    {
        if (isC4fm)
        {
            return "FM";
        }
        return mode switch
        {
            RigMode.Usb => "USB",
            RigMode.Lsb => "LSB",
            RigMode.Cw => "CW",
            RigMode.Am => "AM",
            RigMode.Fm or RigMode.DataFm => "FM",
            RigMode.Rtty => "RTTY",
            RigMode.DataUsb => "PKTUSB",
            _ => null,
        };
    }

    /// v2 tokens start with this; v1 keys don't.
    public const string TokenPrefix = "wl2_";

    /// Requests time out after this long; a QSO send is one small POST.
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    private static readonly HttpClient Http = new(new SocketsHttpHandler { PooledConnectionLifetime = TimeSpan.FromMinutes(5) })
    {
        Timeout = System.Threading.Timeout.InfiniteTimeSpan,
    };

    // Requests.

    /// &lt;base&gt;/index.php/api/v2/&lt;path&gt;. `baseUrl` is what the user typed:
    /// the Wavelog root, with or without a trailing slash or index.php; no
    /// scheme means https.
    public static Uri? ApiUrl(string baseUrl, string path)
    {
        var root = baseUrl.Trim();
        if (root.Length == 0)
        {
            return null;
        }
        if (!root.Contains("://", StringComparison.Ordinal))
        {
            root = "https://" + root;
        }
        root = root.TrimEnd('/');
        if (root.EndsWith("/index.php", StringComparison.OrdinalIgnoreCase))
        {
            root = root[..^"/index.php".Length].TrimEnd('/');
        }
        if (!Uri.TryCreate(root + "/index.php/api/v2/" + path, UriKind.Absolute, out var url)
            || url.Scheme is not ("http" or "https")
            || url.Host.Length == 0)
        {
            return null;
        }
        return url;
    }

    public static HttpRequestMessage? QsoRequest(string baseUrl, string token, string stationId, string adif, bool dryRun = false)
    {
        if (ApiUrl(baseUrl, "qso") is not { } url || !int.TryParse(stationId, out var station))
        {
            return null;
        }
        var body = new JsonObject
        {
            ["adif"] = adif,
            ["dryrun"] = dryRun,
            ["import_type"] = "adif",
            ["station_profile_id"] = station,
        };
        return JsonRequest(HttpMethod.Post, url, token, body);
    }

    public static HttpRequestMessage? StationsRequest(string baseUrl, string token) =>
        ApiUrl(baseUrl, "station") is { } url ? Request(HttpMethod.Get, url, token) : null;

    public static HttpRequestMessage? RadioRequest(string baseUrl, string token, string radio, RadioStatus status)
    {
        if (ApiUrl(baseUrl, "radio") is not { } url)
        {
            return null;
        }
        var body = new JsonObject { ["frequency"] = status.FrequencyHz };
        if (status.FrequencyRxHz is { } rx) body["frequency_rx"] = rx;
        if (status.Mode is { } mode) body["mode"] = mode;
        if (status.ModeRx is { } modeRx) body["mode_rx"] = modeRx;
        if (status.PowerWatts is { } power) body["power"] = power;
        body["radio"] = radio;
        return JsonRequest(HttpMethod.Post, url, token, body);
    }

    /// ADIF's &lt;…&gt; goes out as is, as the Mac's JSONSerialization sends it,
    /// rather than as < escapes.
    private static readonly JsonSerializerOptions BodyOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private static HttpRequestMessage JsonRequest(HttpMethod method, Uri url, string token, JsonObject body)
    {
        var request = Request(method, url, token);
        request.Content = new StringContent(body.ToJsonString(BodyOptions), Encoding.UTF8, "application/json");
        // The Mac's exact Content-Type, without "; charset=utf-8".
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        return request;
    }

    private static HttpRequestMessage Request(HttpMethod method, Uri url, string token)
    {
        var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        return request;
    }

    // Replies.

    public static LogResult ParseLogReply(int status, string body)
    {
        var obj = Envelope(status, body);
        if (ErrorMessage(obj) is { } message)
        {
            // Refusals of this QSO (bad ADIF, a location that isn't the
            // token's) are rejections; anything about the token or the
            // server's state is an error the user has to fix in Settings.
            if (status == 400 || (status == 403 && ErrorCode(obj) == "forbidden"))
            {
                return new LogResult.Rejected(message);
            }
            throw ApiException.Refused(message);
        }
        if (obj["data"] is not JsonObject data)
        {
            throw ApiException.UnexpectedReply(status, Snippet(body));
        }
        if (Bool(data["dryrun"]) == true) return new LogResult.Created();
        if (Int(data["imported"]) > 0) return new LogResult.Created();
        if (Int(data["skipped"]) > 0) return new LogResult.Duplicate();
        var messages = (data["messages"] as JsonArray ?? [])
            .Select(m => m is JsonValue v && v.TryGetValue<string>(out var s) ? PlainText(s) : "")
            .Where(m => m.Length > 0)
            .ToList();
        return new LogResult.Rejected(messages.Count == 0 ? Loc.S("common.wavelogDidntImportThe") : string.Join("; ", messages));
    }

    public static List<Station> ParseStations(int status, string body)
    {
        var obj = Envelope(status, body);
        if (ErrorMessage(obj) is { } message)
        {
            throw ApiException.Refused(message);
        }
        if (status is < 200 or >= 300 || obj["data"] is not JsonArray rows)
        {
            throw ApiException.UnexpectedReply(status, Snippet(body));
        }
        var stations = new List<Station>();
        foreach (var row in rows.OfType<JsonObject>())
        {
            if (Text(row["id"]) is not { Length: > 0 } id)
            {
                continue;
            }
            stations.Add(new Station(id, Text(row["name"]) ?? "", Text(row["callsign"]) ?? "",
                Text(row["gridsquare"]) ?? "", Bool(row["active"]) ?? false));
        }
        return stations;
    }

    /// A radio update's reply: nothing to return on success.
    public static void ParseRadioReply(int status, string body)
    {
        var obj = Envelope(status, body);
        if (ErrorMessage(obj) is { } message)
        {
            throw ApiException.Refused(message);
        }
        if (status is < 200 or >= 300 || obj["data"] is null)
        {
            throw ApiException.UnexpectedReply(status, Snippet(body));
        }
    }

    private static JsonObject Envelope(int status, string body)
    {
        try
        {
            if (JsonNode.Parse(body) is JsonObject obj)
            {
                return obj;
            }
        }
        catch (JsonException)
        {
        }
        throw ApiException.UnexpectedReply(status, Snippet(body));
    }

    /// v2's {"error": {"message"}}, or v1's {"status": "failed", "reason"}
    /// (the rate limiter's 429).
    private static string? ErrorMessage(JsonObject obj)
    {
        if (obj["error"] is JsonObject error)
        {
            var message = Text(error["message"]) is { } m ? PlainText(m) : "";
            return message.Length == 0 ? Text(error["code"]) ?? "error" : message;
        }
        if (obj["data"] is null && Text(obj["reason"]) is { Length: > 0 } reason)
        {
            return PlainText(reason);
        }
        return null;
    }

    private static string? ErrorCode(JsonObject obj) => obj["error"] is JsonObject error ? Text(error["code"]) : null;

    private static string? Text(JsonNode? node) => node is JsonValue value
        ? value.GetValueKind() switch
        {
            JsonValueKind.String => value.GetValue<string>(),
            JsonValueKind.Number => value.ToJsonString(),
            _ => null,
        }
        : null;

    private static int Int(JsonNode? node) => node is JsonValue value
        ? value.GetValueKind() switch
        {
            JsonValueKind.Number => value.TryGetValue<int>(out var i) ? i : (int)value.GetValue<double>(),
            JsonValueKind.String => int.TryParse(value.GetValue<string>(), out var i) ? i : 0,
            _ => 0,
        }
        : 0;

    private static bool? Bool(JsonNode? node) => node is JsonValue value
        ? value.GetValueKind() switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        }
        : null;

    /// Server text as one line of plain text: &lt;br&gt; ends a message, other
    /// tags go, the entities htmlentities makes are decoded. (v2 strips
    /// tags itself; an error page or proxy reply may not.)
    public static string PlainText(string html)
    {
        var text = Regex.Replace(html, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, "<[^>]*>", "");
        foreach (var (entity, character) in new[] { ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&") })
        {
            text = text.Replace(entity, character, StringComparison.Ordinal);
        }
        return string.Join("; ", text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0));
    }

    private static string Snippet(string body) => PlainText(body.Length > 200 ? body[..200] : body).Trim();

    // Sending.

    /// Logs one QSO (or, with dryRun, checks that it could be). Throws
    /// ApiException.
    public static async Task<LogResult> LogAsync(LoggedQso qso, string baseUrl, string token, string stationId, bool dryRun = false)
    {
        using var request = QsoRequest(baseUrl, token, stationId, AdifRecord.Record(qso), dryRun) ?? throw ApiException.BadUrl();
        var (status, body) = await PerformAsync(request);
        return ParseLogReply(status, body);
    }

    public static async Task<List<Station>> StationsAsync(string baseUrl, string token)
    {
        using var request = StationsRequest(baseUrl, token) ?? throw ApiException.BadUrl();
        var (status, body) = await PerformAsync(request);
        return ParseStations(status, body);
    }

    /// Reports the rig's state as the CAT radio `radio`.
    public static async Task ReportRadioAsync(RadioStatus status, string radio, string baseUrl, string token)
    {
        using var request = RadioRequest(baseUrl, token, radio, status) ?? throw ApiException.BadUrl();
        var (code, body) = await PerformAsync(request);
        ParseRadioReply(code, body);
    }

    private static async Task<(int Status, string Body)> PerformAsync(HttpRequestMessage request)
    {
        using var timeout = new CancellationTokenSource(Timeout);
        try
        {
            using var response = await Http.SendAsync(request, timeout.Token);
            return ((int)response.StatusCode, await response.Content.ReadAsStringAsync(timeout.Token));
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            throw new ApiException(Loc.F("wavelog.wavelogDidntAnswerWithin", Timeout.TotalSeconds));
        }
        catch (HttpRequestException e) when (e.InnerException is SocketException { SocketErrorCode: SocketError.HostNotFound or SocketError.NoData or SocketError.TryAgain })
        {
            throw new ApiException(Loc.F("common.couldntFindTheHost", request.RequestUri?.Host));
        }
        catch (HttpRequestException e)
        {
            throw new ApiException(Loc.F("wavelog.couldntReachWavelogX", e.Message));
        }
    }
}

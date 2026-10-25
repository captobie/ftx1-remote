using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// Wavelog's API v2 requests and reply parsing, and the tune listener —
/// the Mac's WavelogTests/WavelogTuneRequestTests (Tests/FTX1CoreTests/),
/// same cases, plus the listener over loopback HTTP.
public class WavelogTests
{
    [Theory]
    [InlineData("https://log.example.org")]
    [InlineData("https://log.example.org/")]
    [InlineData("https://log.example.org/index.php")]
    [InlineData("https://log.example.org/index.php/")]
    [InlineData("log.example.org")]
    [InlineData("  https://log.example.org  ")]
    public void ApiUrlForms(string baseUrl) =>
        Assert.Equal("https://log.example.org/index.php/api/v2/qso", Wavelog.ApiUrl(baseUrl, "qso")?.AbsoluteUri);

    [Fact]
    public void ApiUrlWithPathAndPort()
    {
        Assert.Equal("http://wavelog:8086/wavelog/index.php/api/v2/station", Wavelog.ApiUrl("http://wavelog:8086/wavelog", "station")?.AbsoluteUri);
        Assert.Null(Wavelog.ApiUrl("", "qso"));
        Assert.Null(Wavelog.ApiUrl("ftp://log.example.org", "qso"));
    }

    private static async Task<JsonObject> Body(HttpRequestMessage request) =>
        (JsonObject)JsonNode.Parse(await request.Content!.ReadAsStringAsync())!;

    [Fact]
    public async Task QsoRequest()
    {
        using var request = Wavelog.QsoRequest("https://log.example.org", "wl2_abc", "3", "<call:4>K6NA <EOR>")!;
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("Bearer wl2_abc", request.Headers.Authorization?.ToString());
        Assert.Equal("application/json", request.Content!.Headers.ContentType?.MediaType);
        var body = await Body(request);
        Assert.Equal(3, (int)body["station_profile_id"]!);
        Assert.Equal("adif", (string)body["import_type"]!);
        Assert.Equal("<call:4>K6NA <EOR>", (string)body["adif"]!);
        Assert.False((bool)body["dryrun"]!);
        Assert.Null(body["key"]); // the token goes in the header only

        using var dryRun = Wavelog.QsoRequest("https://log.example.org", "t", "1", "x", dryRun: true)!;
        Assert.True((bool)(await Body(dryRun))["dryrun"]!);
        Assert.Null(Wavelog.QsoRequest("https://log.example.org", "t", "abc", "x"));
    }

    [Fact]
    public void StationsRequest()
    {
        using var request = Wavelog.StationsRequest("https://log.example.org", "wl2_abc")!;
        Assert.Equal("https://log.example.org/index.php/api/v2/station", request.RequestUri?.AbsoluteUri);
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("Bearer wl2_abc", request.Headers.Authorization?.ToString());
    }

    [Fact]
    public void Created()
    {
        Assert.IsType<Wavelog.LogResult.Created>(Wavelog.ParseLogReply(201, """{"data":{"parsed":1,"imported":1,"skipped":0,"messages":[]},"meta":{"api_version":"2"}}"""));
        Assert.IsType<Wavelog.LogResult.Created>(Wavelog.ParseLogReply(200, """{"data":{"dryrun":true,"parsed":1},"meta":{}}"""));
    }

    [Fact]
    public void Duplicate() =>
        Assert.IsType<Wavelog.LogResult.Duplicate>(Wavelog.ParseLogReply(201, """{"data":{"parsed":1,"imported":0,"skipped":1,"messages":[]}}"""));

    [Fact]
    public void NothingImported()
    {
        Assert.Equal(new Wavelog.LogResult.Rejected("Wrong band x"),
            Wavelog.ParseLogReply(201, """{"data":{"parsed":1,"imported":0,"skipped":0,"messages":["Wrong band <b>x</b>"]}}"""));
        Assert.Equal(new Wavelog.LogResult.Rejected("No valid QSO records found in ADIF"),
            Wavelog.ParseLogReply(400, """{"error":{"code":"validation_error","message":"No valid QSO records found in ADIF"}}"""));
    }

    [Fact]
    public void ForeignStationIsARejection() =>
        Assert.Equal(new Wavelog.LogResult.Rejected("station_profile_id does not belong to the API key owner"),
            Wavelog.ParseLogReply(403, """{"error":{"code":"forbidden","message":"station_profile_id does not belong to the API key owner"}}"""));

    [Theory]
    [InlineData(401, """{"error":{"code":"invalid_token","message":"API v2 requires a wl2_ token; legacy v1 API keys are not accepted"}}""",
        "API v2 requires a wl2_ token; legacy v1 API keys are not accepted")]
    [InlineData(403, """{"error":{"code":"insufficient_scope","message":"Token is missing the required scope: qso:write","details":{"required_scope":"qso:write"}}}""",
        "Token is missing the required scope: qso:write")]
    [InlineData(429, """{"status":"failed","reason":"Rate limit exceeded. Try again in 30 seconds.","retry_after":30}""",
        "Rate limit exceeded. Try again in 30 seconds.")]
    public void TokenProblemsThrow(int status, string body, string message)
    {
        var error = Assert.Throws<Wavelog.ApiException>(() => Wavelog.ParseLogReply(status, body));
        Assert.Equal($"Wavelog: {message}", error.Message);
    }

    [Fact]
    public void NonJsonReply()
    {
        var error = Assert.Throws<Wavelog.ApiException>(() => Wavelog.ParseLogReply(404, "<html><body>Not Found</body></html>"));
        Assert.Equal("Unexpected reply from Wavelog (HTTP 404): Not Found", error.Message);
    }

    [Fact]
    public void Stations()
    {
        var body = """
            {"data":[{"id":1,"name":"Home","callsign":"N0CALL","gridsquare":"FN31PR","active":true,"dxcc":291},
                     {"id":2,"name":"Portable","callsign":"N0CALL/P","gridsquare":null,"active":false}],
             "meta":{}}
            """;
        Assert.Equal(
            [new Wavelog.Station("1", "Home", "N0CALL", "FN31PR", true), new Wavelog.Station("2", "Portable", "N0CALL/P", "", false)],
            Wavelog.ParseStations(200, body));
    }

    [Fact]
    public void StationsWithoutScope()
    {
        var error = Assert.Throws<Wavelog.ApiException>(() => Wavelog.ParseStations(403,
            """{"error":{"code":"insufficient_scope","message":"Token is missing the required scope: station:read"}}"""));
        Assert.Equal("Wavelog: Token is missing the required scope: station:read", error.Message);
    }

    [Fact]
    public void PlainText() => Assert.Equal("a; b; c & d's", Wavelog.PlainText("a<br>b<BR/> <b>c</b> &amp; d&#039;s"));

    // Radio (CAT).

    [Fact]
    public async Task RadioRequest()
    {
        var status = new Wavelog.RadioStatus(14_025_000, "CW", 14_023_000, "CW", 50);
        using var request = Wavelog.RadioRequest("log.example.org", "wl2_abc", "FTX-1", status)!;
        Assert.Equal("https://log.example.org/index.php/api/v2/radio", request.RequestUri?.AbsoluteUri);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("Bearer wl2_abc", request.Headers.Authorization?.ToString());
        var body = await Body(request);
        Assert.Equal("FTX-1", (string)body["radio"]!);
        Assert.Equal(14_025_000, (long)body["frequency"]!);
        Assert.Equal("CW", (string)body["mode"]!);
        Assert.Equal(14_023_000, (long)body["frequency_rx"]!);
        Assert.Equal("CW", (string)body["mode_rx"]!);
        Assert.Equal(50.0, (double)body["power"]!);

        using var simplex = Wavelog.RadioRequest("log.example.org", "t", "R", new Wavelog.RadioStatus(7_074_000, null))!;
        Assert.Equal(["frequency", "radio"], (await Body(simplex)).Select(p => p.Key).Order());
    }

    [Fact]
    public void CatModes()
    {
        Assert.Equal("USB", Wavelog.CatMode(RigMode.Usb));
        Assert.Equal("PKTUSB", Wavelog.CatMode(RigMode.DataUsb));
        Assert.Equal("FM", Wavelog.CatMode(RigMode.DataFm));
        Assert.Equal("FM", Wavelog.CatMode(RigMode.Usb, isC4fm: true));
        Assert.Null(Wavelog.CatMode(null));
        foreach (var mode in Enum.GetValues<RigMode>())
        {
            Assert.True((Wavelog.CatMode(mode)?.Length ?? 0) <= 10, "Wavelog's mode column is 10 characters");
        }
    }

    [Fact]
    public void RadioReplies()
    {
        var row = """{"data":{"id":4,"radio":"FTX-1","frequency":14025000,"mode":"CW"},"meta":{}}""";
        Wavelog.ParseRadioReply(201, row);
        Wavelog.ParseRadioReply(200, row);
        Assert.Equal("Wavelog: Token is missing the required scope: radio:write", Assert.Throws<Wavelog.ApiException>(() => Wavelog.ParseRadioReply(403,
            """{"error":{"code":"insufficient_scope","message":"Token is missing the required scope: radio:write","details":{"required_scope":"radio:write"}}}""")).Message);
        Assert.Equal("Wavelog: Invalid field(s): mode", Assert.Throws<Wavelog.ApiException>(() => Wavelog.ParseRadioReply(400,
            """{"error":{"code":"validation_error","message":"Invalid field(s): mode","details":{"invalid":["mode"]}}}""")).Message);
        Assert.Throws<Wavelog.ApiException>(() => Wavelog.ParseRadioReply(404, "<html>Not found</html>"));
    }

    /// Against a local stand-in server: the request as it goes on the wire
    /// (path, header, body) and the reply parsed.
    [Fact]
    public async Task LogsOverHttp()
    {
        using var server = new HttpListener();
        var port = FreePort();
        server.Prefixes.Add($"http://127.0.0.1:{port}/");
        server.Start();
        var serving = Task.Run(async () =>
        {
            var context = await server.GetContextAsync();
            var body = await new StreamReader(context.Request.InputStream).ReadToEndAsync();
            var reply = context.Request.Url!.AbsolutePath == "/wl/index.php/api/v2/qso"
                        && context.Request.Headers["Authorization"] == "Bearer wl2_x"
                        && body.Contains("<call:4>TE5T", StringComparison.Ordinal)
                ? """{"data":{"parsed":1,"imported":0,"skipped":1,"messages":[]}}"""
                : """{"error":{"code":"bad","message":"unexpected request"}}""";
            context.Response.StatusCode = 201;
            var bytes = System.Text.Encoding.UTF8.GetBytes(reply);
            await context.Response.OutputStream.WriteAsync(bytes);
            context.Response.Close();
        });
        var now = DateTimeOffset.UtcNow;
        var qso = new LoggedQso { Call = "TE5T", Start = now, End = now, FrequencyHz = 14_025_000, Mode = "CW" };
        var result = await Wavelog.LogAsync(qso, $"http://127.0.0.1:{port}/wl/", "wl2_x", "1");
        await serving;
        Assert.IsType<Wavelog.LogResult.Duplicate>(result);
    }

    [Fact]
    public async Task NoServer()
    {
        var error = await Assert.ThrowsAsync<Wavelog.ApiException>(() => Wavelog.StationsAsync($"http://127.0.0.1:{FreePort()}", "wl2_x"));
        Assert.StartsWith("Couldn't reach Wavelog", error.Message);
    }

    // Tune requests, shaped like 3.2.3's cat.js sends them.

    [Fact]
    public void TunePaths()
    {
        Assert.Equal(new WavelogTuneRequest(14_025_000, RigMode.Cw), WavelogTuneRequest.FromPath("/14025000/cw"));
        Assert.Equal(new WavelogTuneRequest(7_074_000, RigMode.DataUsb), WavelogTuneRequest.FromPath("/7074000/pktusb"));
        Assert.Equal(new WavelogTuneRequest(146_940_000, RigMode.Fm), WavelogTuneRequest.FromPath("/146940000/fm?x=1"));
        Assert.Equal(new WavelogTuneRequest(3_573_000, null), WavelogTuneRequest.FromPath("/3573000"));
        Assert.Equal(new WavelogTuneRequest(14_074_000, null), WavelogTuneRequest.FromPath("/14074000.4/xyz"));
        Assert.Null(WavelogTuneRequest.FromPath("/"));
        Assert.Null(WavelogTuneRequest.FromPath("/favicon.ico"));
        Assert.Null(WavelogTuneRequest.FromPath("/1000/usb")); // below the rig's coverage
        Assert.Null(WavelogTuneRequest.FromPath("/14025000/cw/extra"));
    }

    [Fact]
    public void TuneModes()
    {
        Assert.Equal(RigMode.Lsb, WavelogTuneRequest.RigModeForCatMode("LSB"));
        Assert.Equal(RigMode.Rtty, WavelogTuneRequest.RigModeForCatMode("rtty"));
        Assert.Equal(RigMode.DataUsb, WavelogTuneRequest.RigModeForCatMode("dig"));
        Assert.Equal(RigMode.DataFm, WavelogTuneRequest.RigModeForCatMode("pktfm"));
        Assert.Null(WavelogTuneRequest.RigModeForCatMode("ft8"));
    }

    [Fact]
    public void TuneHead()
    {
        var head = WavelogTuneRequest.ParseHead(
            "GET /14025000/cw HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nOrigin: http://100.104.255.14:8082\r\nAccess-Control-Request-Private-Network: true")!;
        Assert.Equal("GET", head.Method);
        Assert.Equal("/14025000/cw", head.Path);
        Assert.Equal("http://100.104.255.14:8082", head.Headers["origin"]);
        Assert.Equal("true", head.Headers["access-control-request-private-network"]);
        Assert.Null(WavelogTuneRequest.ParseHead("\u0016\u0003\u0001garbage"));
    }

    [Fact]
    public void TuneOrigin()
    {
        Assert.Equal("http://100.104.255.14:8082", WavelogTuneRequest.OriginOfWavelogUrl("http://100.104.255.14:8082"));
        Assert.Equal("https://log.example.org", WavelogTuneRequest.OriginOfWavelogUrl("https://Log.Example.org/wavelog/index.php"));
        Assert.Equal("https://log.example.org", WavelogTuneRequest.OriginOfWavelogUrl("log.example.org:443"));
        Assert.Equal("http://wavelog", WavelogTuneRequest.OriginOfWavelogUrl("http://wavelog:80/"));
        Assert.Null(WavelogTuneRequest.OriginOfWavelogUrl(""));
        Assert.Null(WavelogTuneRequest.OriginOfWavelogUrl("ftp://x"));
    }

    // The listener, over loopback.

    private const string WavelogOrigin = "http://100.104.255.14:8082";

    [Fact]
    public async Task ListenerTunesFromWavelogOnly()
    {
        var tuned = new List<WavelogTuneRequest>();
        string? refusal = null;
        var listener = new WavelogTuneListener(r =>
        {
            tuned.Add(r);
            return Task.FromResult(refusal);
        }, () => WavelogOrigin + "/index.php");
        var port = FreePort();
        listener.Apply(true, port);
        try
        {
            Assert.Equal(new WavelogTuneListener.ListenerState.Listening(port), listener.State);
            using var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}") };

            // Chrome's private-network preflight.
            using var preflight = new HttpRequestMessage(HttpMethod.Options, "/14025000/cw");
            preflight.Headers.Add("Origin", WavelogOrigin);
            preflight.Headers.Add("Access-Control-Request-Private-Network", "true");
            using (var reply = await http.SendAsync(preflight))
            {
                Assert.Equal(HttpStatusCode.NoContent, reply.StatusCode);
                Assert.Equal(WavelogOrigin, reply.Headers.GetValues("Access-Control-Allow-Origin").Single());
                Assert.Equal("true", reply.Headers.GetValues("Access-Control-Allow-Private-Network").Single());
            }

            // The tune itself.
            using var get = new HttpRequestMessage(HttpMethod.Get, "/14025000/cw");
            get.Headers.Add("Origin", WavelogOrigin);
            using (var reply = await http.SendAsync(get))
            {
                Assert.Equal(HttpStatusCode.OK, reply.StatusCode);
                Assert.Equal(WavelogOrigin, reply.Headers.GetValues("Access-Control-Allow-Origin").Single());
            }
            Assert.Equal([new WavelogTuneRequest(14_025_000, RigMode.Cw)], tuned);
            Assert.True(listener.LastEvent?.Ok);

            // Another page, or none: not obeyed.
            using var foreign = new HttpRequestMessage(HttpMethod.Get, "/7030000/cw");
            foreign.Headers.Add("Origin", "https://evil.example");
            using (var reply = await http.SendAsync(foreign))
            {
                Assert.Equal(HttpStatusCode.Forbidden, reply.StatusCode);
                Assert.False(reply.Headers.Contains("Access-Control-Allow-Origin"));
            }
            using (var reply = await http.GetAsync("/7030000/cw"))
            {
                Assert.Equal(HttpStatusCode.Forbidden, reply.StatusCode);
            }
            Assert.Single(tuned);

            // A refusal comes back as 409 with the reason.
            refusal = "the rig is transmitting";
            using var refused = new HttpRequestMessage(HttpMethod.Get, "/7030000/cw");
            refused.Headers.Add("Origin", WavelogOrigin);
            using (var reply = await http.SendAsync(refused))
            {
                Assert.Equal(HttpStatusCode.Conflict, reply.StatusCode);
                Assert.Equal("the rig is transmitting", await reply.Content.ReadAsStringAsync());
            }
            Assert.False(listener.LastEvent?.Ok);

            using (var reply = await http.GetAsync("/favicon.ico"))
            {
                Assert.Equal(HttpStatusCode.NotFound, reply.StatusCode);
            }
        }
        finally
        {
            listener.Stop();
        }
        Assert.IsType<WavelogTuneListener.ListenerState.Off>(listener.State);
    }

    [Fact]
    public void ListenerReportsAPortInUse()
    {
        var port = FreePort();
        var first = new WavelogTuneListener(_ => Task.FromResult<string?>(null), () => WavelogOrigin);
        var second = new WavelogTuneListener(_ => Task.FromResult<string?>(null), () => WavelogOrigin);
        first.Apply(true, port);
        try
        {
            second.Apply(true, port);
            var failed = Assert.IsType<WavelogTuneListener.ListenerState.Failed>(second.State);
            Assert.Contains("in use", failed.Message);
        }
        finally
        {
            first.Stop();
            second.Stop();
        }
    }

    private static int FreePort()
    {
        var socket = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        socket.Start();
        var port = ((IPEndPoint)socket.LocalEndpoint).Port;
        socket.Stop();
        return port;
    }
}

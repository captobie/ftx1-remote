using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using FTX1RemoteWindows.Services.Hub;
using Xunit;
using static FTX1RemoteWindows.Tests.HubWireTests;

namespace FTX1RemoteWindows.Tests;

/// Phase 6 (Apps/Windows/README.md, "Desktop hub for the iPad"): the CW
/// keyer request/reply pair — the Swift fixtures round-trip and parse, the
/// write checks, replies to the asker only with its id, acquire always
/// granted, the keyer player's disconnect, the keyer tracker and play
/// refusal, the confirmed stop, and the C#-made reply fixtures for the
/// Mac's HubWireFixtureTests (written through the real server).
public class HubKeyerTests
{
    private static string RepoRoot => Path.GetFullPath(Path.Combine(FixturesDir, "..", ".."));

    // Swift fixtures.

    [Theory]
    [InlineData("cw-keyer-request.write.json")]
    [InlineData("cw-keyer-request.check.json")]
    [InlineData("cw-keyer-request.acquire.json")]
    [InlineData("cw-keyer-request.release.json")]
    public void RequestFixtureRoundTrips(string fileName) => RoundTrips<CwKeyerRequestWire>(fileName);

    [Theory]
    [InlineData("cw-keyer-reply.stored.json")]
    [InlineData("cw-keyer-reply.checked.json")]
    [InlineData("cw-keyer-reply.error.json")]
    [InlineData("cw-keyer-reply.busy.json")]
    public void ReplyFixtureRoundTrips(string fileName) => RoundTrips<CwKeyerReplyWire>(fileName);

    [Theory]
    [InlineData("cw-keyer-request.write.json", 7, 1, "CQ CQ DE W1AW K", null)]
    [InlineData("cw-keyer-request.check.json", 8, 1, null, null)]
    [InlineData("cw-keyer-request.acquire.json", 9, 0, null, "acquire")]
    [InlineData("cw-keyer-request.release.json", 10, 0, null, "release")]
    public void RequestFixtureParses(string fileName, int id, int slot, string? text, string? action)
    {
        var inbound = RigCommandWire.ParseInbound(File.ReadAllText(Path.Combine(FixturesDir, fileName)));
        Assert.Equal(InboundKind.CwKeyer, inbound.Kind);
        var request = inbound.CwKeyer!;
        Assert.Equal((id, slot, text, action), (request.Id, request.Slot, request.Text, request.Action));
    }

    [Theory]
    [InlineData("""{"type":"cw_keyer","slot":1,"text":"CQ"}""")]
    [InlineData("""{"type":"cw_keyer","id":"7","slot":1}""")]
    [InlineData("""{"type":"cw_keyer","id":7,"slot":1.5}""")]
    [InlineData("""{"type":"cw_keyer","id":7,"slot":1,"text":5}""")]
    [InlineData("""{"type":"cw_keyer","id":7,"slot":0,"action":"steal"}""")]
    public void MalformedRequestIsInvalid(string json) =>
        Assert.Equal(InboundKind.Invalid, RigCommandWire.ParseInbound(json).Kind);

    [Fact]
    public void NullTextAndActionAreAbsent()
    {
        var request = RigCommandWire.ParseInbound("""{"type":"cw_keyer","id":3,"slot":2,"text":null,"action":null}""").CwKeyer!;
        Assert.Null(request.Text);
        Assert.Null(request.Action);
    }

    private static void RoundTrips<T>(string fileName)
    {
        var original = File.ReadAllText(Path.Combine(FixturesDir, fileName));
        var message = HubWire.Deserialize<T>(original);
        Assert.NotNull(message);
        using var a = JsonDocument.Parse(original);
        using var b = JsonDocument.Parse(HubWire.Serialize(message!));
        AssertJsonEqual(a.RootElement, b.RootElement, "$");
    }

    // Write checks.

    [Theory]
    [InlineData(1, "CQ CQ DE W1AW K", null)]
    [InlineData(5, "?/,.=+-()@: 0123456789", null)]
    [InlineData(1, null, null)] // TEXT check
    [InlineData(0, "CQ", "Keyer memory 0 doesn't exist (1–5)")]
    [InlineData(6, "CQ", "Keyer memory 6 doesn't exist (1–5)")]
    [InlineData(9, null, "Keyer memory 9 doesn't exist (1–5)")]
    [InlineData(1, "", "Nothing to write: the text is empty")]
    [InlineData(1, "CQ;FA14074000", "The keyer can't send \";\" (allowed: A–Z 0–9 space / ? , . = + - ( ) @ :)")]
    // Lowercase is refused, as by the Mac (CWText.allowed is uppercase; the
    // iPad uppercases before sending).
    [InlineData(1, "cq", "The keyer can't send \"c\" (allowed: A–Z 0–9 space / ? , . = + - ( ) @ :)")]
    [InlineData(1, "CQ\nDE", "The keyer can't send \"\n\" (allowed: A–Z 0–9 space / ? , . = + - ( ) @ :)")]
    [InlineData(1, "<BT>", "The keyer can't send \"<\" (allowed: A–Z 0–9 space / ? , . = + - ( ) @ :)")]
    public void RequestRefusal(int slot, string? text, string? expected) =>
        Assert.Equal(expected, HubKeyerPolicy.RequestRefusal(slot, text));

    [Theory]
    [InlineData(1, "CQ", null)]
    [InlineData(1, null, null)]
    [InlineData(9, "CQ", "keyer_bad_slot")]
    [InlineData(1, "", "keyer_bad_text")]
    [InlineData(1, "cq", "keyer_bad_text")]
    public void RequestRefusalCode(int slot, string? text, string? expected) =>
        Assert.Equal(expected, HubKeyerPolicy.RequestRefusalCode(slot, text));

    [Fact]
    public void LengthLimitIsFifty()
    {
        Assert.Null(HubKeyerPolicy.RequestRefusal(1, new string('E', 50)));
        Assert.Equal("Too long for the keyer memory: 51 characters (50 at most)",
            HubKeyerPolicy.RequestRefusal(1, new string('E', 51)));
    }

    [Fact]
    public void AllowedCharactersMatchSwiftAndTheCwSender()
    {
        var swift = File.ReadAllText(Path.Combine(RepoRoot, "Sources", "FTX1CW", "CWSender.swift"));
        var swiftAllowed = Regex.Match(swift, @"static let allowed = Set\(""([^""]*)""\)").Groups[1].Value;
        var csharp = File.ReadAllText(Path.Combine(RepoRoot, "Apps", "Windows", "FTX1RemoteWindows", "Services", "CwSender.cs"));
        var csharpAllowed = Regex.Match(csharp, @"Allowed = \[\.\. ""([^""]*)""\]").Groups[1].Value;
        Assert.Equal(HubKeyerPolicy.AllowedCharacters, swiftAllowed);
        Assert.Equal(HubKeyerPolicy.AllowedCharacters, csharpAllowed);
        Assert.DoesNotContain(';', HubKeyerPolicy.AllowedCharacters);
    }

    // Play refusal and the tracker.

    [Theory]
    [InlineData(false, false, false, false, false, null)]
    [InlineData(false, false, false, true, true, null)] // the hub's own play still keying
    [InlineData(true, false, false, false, false, "this PC's PTT is held")]
    [InlineData(false, true, false, false, false, "MOX is on")]
    [InlineData(false, false, true, false, false, "a hub client is keyed with PTT")]
    [InlineData(false, false, false, true, false, "the rig is already transmitting (not the hub's keyer)")]
    [InlineData(false, false, true, true, true, "a hub client is keyed with PTT")]
    public void PlayRefusal(bool windowPtt, bool mox, bool hubPtt, bool rigTx, bool hubKeyer, string? expected) =>
        Assert.Equal(expected, HubKeyerPolicy.PlayRefusal(windowPtt, mox, hubPtt, rigTx, hubKeyer));

    [Fact]
    public void TrackerRidesOutASpuriousZeroAndEndsAfterASecondOff()
    {
        var t = new HubKeyerTracker();
        Assert.False(t.Active);
        Assert.False(t.PlayedSinceStop);
        t.Played(10_000);
        t.OnPtt(false, 10_500); // not keying yet
        t.OnPtt(false, 11_600);
        Assert.True(t.Active); // inside the start grace
        t.OnPtt(true, 12_000);
        t.OnPtt(false, 13_000); // the odd spurious 0
        t.OnPtt(true, 13_500);
        Assert.True(t.Active);
        t.OnPtt(false, 20_000);
        Assert.True(t.Active);
        t.OnPtt(false, 20_999);
        Assert.True(t.Active);
        t.OnPtt(false, 21_000);
        Assert.False(t.Active);
        Assert.True(t.PlayedSinceStop); // still owes a KY00 on lock/disconnect
        t.Stopped();
        Assert.False(t.PlayedSinceStop);
    }

    [Fact]
    public void TrackerEndsWhenTheRigNeverKeys()
    {
        var t = new HubKeyerTracker();
        t.Played(0);
        t.OnPtt(false, 500);
        t.OnPtt(false, 1500);
        Assert.True(t.Active);
        t.OnPtt(false, 2000);
        Assert.False(t.Active);
    }

    [Fact]
    public void StopEndsThePlayAtOnce()
    {
        var t = new HubKeyerTracker();
        t.Played(0);
        t.OnPtt(true, 500);
        t.Stopped();
        Assert.False(t.Active);
        Assert.False(t.PlayedSinceStop);
    }

    // The confirmed stop.

    private sealed class FakeRig(params bool?[] reads)
    {
        private int _read;
        public List<string> Sent { get; } = [];
        public List<string> Log { get; } = [];
        public int Delays { get; private set; }
        public bool FailSends { get; init; }

        public Task<HubKeyerStopResult> StopAsync() => HubKeyerStop.RunAsync("test",
            sendStop: () =>
            {
                Sent.Add("KY00");
                return FailSends ? Task.FromException(new IOException("link down")) : Task.CompletedTask;
            },
            readTransmitting: () => _read < reads.Length
                ? (reads[_read++] is { } r ? Task.FromResult<bool?>(r) : Task.FromException<bool?>(new TimeoutException()))
                : Task.FromResult<bool?>(true),
            pttOff: () =>
            {
                Sent.Add("T 0");
                return Task.CompletedTask;
            },
            delay: d =>
            {
                Assert.Equal(TimeSpan.FromSeconds(1), d);
                Delays++;
                return Task.CompletedTask;
            },
            log: Log.Add);
    }

    [Fact]
    public async Task StopConfirmedOnTheFirstRead()
    {
        var rig = new FakeRig(false);
        Assert.Equal(HubKeyerStopResult.Confirmed, await rig.StopAsync());
        Assert.Equal(["KY00"], rig.Sent);
        Assert.Equal(1, rig.Delays);
        Assert.Contains(rig.Log, l => l.StartsWith("hub: keyer stop confirmed (try 1)"));
    }

    [Fact]
    public async Task StillTransmittingIsRetried()
    {
        var rig = new FakeRig(true, true, false);
        Assert.Equal(HubKeyerStopResult.Confirmed, await rig.StopAsync());
        Assert.Equal(["KY00", "KY00", "KY00"], rig.Sent);
        Assert.Contains("hub: keyer still transmitting after 1 try", rig.Log);
        Assert.Contains("hub: keyer still transmitting after 2 tries", rig.Log);
        Assert.Contains(rig.Log, l => l.StartsWith("hub: keyer stop confirmed (try 3)"));
    }

    [Fact]
    public async Task FiveFailedStopsFallBackToPttOff()
    {
        var rig = new FakeRig(true, true, true, true, true, false);
        Assert.Equal(HubKeyerStopResult.StoppedByPttOff, await rig.StopAsync());
        Assert.Equal(["KY00", "KY00", "KY00", "KY00", "KY00", "T 0"], rig.Sent);
        Assert.Equal(6, rig.Delays);
        Assert.Contains("hub: keyer still transmitting after 5 tries — sent PTT off", rig.Log);
        Assert.Contains(rig.Log, l => l.StartsWith("hub: keyer stopped by PTT off"));
    }

    [Fact]
    public async Task StillTransmittingAfterEverythingIsLoud()
    {
        var rig = new FakeRig(true, true, true, true, true, true);
        Assert.Equal(HubKeyerStopResult.StillTransmitting, await rig.StopAsync());
        Assert.Contains(rig.Log, l => l.StartsWith("hub: KEYER STILL TRANSMITTING"));
    }

    [Fact]
    public async Task UnreadableStateIsNeverTakenAsStopped()
    {
        // A dead link: every send and read fails. Retried, PTT off tried,
        // and reported as unconfirmed — not as confirmed.
        var rig = new FakeRig(null, null, null, null, null, null) { FailSends = true };
        Assert.Equal(HubKeyerStopResult.Unconfirmed, await rig.StopAsync());
        Assert.Equal(5, rig.Sent.Count(s => s == "KY00"));
        Assert.Contains("T 0", rig.Sent);
        Assert.Contains(rig.Log, l => l.Contains("failed to send: link down"));
        Assert.Contains(rig.Log, l => l.StartsWith("hub: COULDN'T CONFIRM"));
    }

    // Through the real server, on loopback.

    [Fact]
    public async Task RepliesGoToTheAskerOnlyWithItsId()
    {
        var calls = new List<(int, string?)>();
        await using var hub = await StartHubAsync();
        hub.CwKeyerHandler = (slot, text) =>
        {
            lock (calls)
            {
                calls.Add((slot, text));
            }
            return Task.FromResult(text);
        };
        using var asker = await ConnectAsync(hub);
        using var other = await ConnectAsync(hub);
        var otherReceive = ReceiveAsync(other, TimeSpan.FromSeconds(3));

        Assert.Equal("""{"type":"cw_keyer_reply","id":7,"stored":"CQ CQ DE W1AW K"}""",
            await AskAsync(asker, """{"type":"cw_keyer","id":7,"slot":1,"text":"CQ CQ DE W1AW K"}"""));
        Assert.Equal("""{"type":"cw_keyer_reply","id":8}""",
            await AskAsync(asker, """{"type":"cw_keyer","id":8,"slot":1}"""));
        // Acquire always granted (no busy), release a plain answer; neither
        // reaches the rig.
        Assert.Equal("""{"type":"cw_keyer_reply","id":9}""",
            await AskAsync(asker, """{"type":"cw_keyer","id":9,"slot":0,"action":"acquire"}"""));
        Assert.Equal("""{"type":"cw_keyer_reply","id":10}""",
            await AskAsync(asker, """{"type":"cw_keyer","id":10,"slot":0,"action":"release"}"""));
        // Refused before the rig: slot, ";".
        Assert.Equal("""{"type":"cw_keyer_reply","id":11,"error":"Keyer memory 9 doesn't exist (1–5)","errorCode":"keyer_bad_slot"}""",
            Decode(await AskAsync(asker, """{"type":"cw_keyer","id":11,"slot":9,"text":"CQ"}""")));
        Assert.Contains("can't send \\\";\\\"",
            Decode(await AskAsync(asker, """{"type":"cw_keyer","id":12,"slot":1,"text":"CQ;TX1"}""")));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => otherReceive);
        lock (calls)
        {
            Assert.Equal([(1, "CQ CQ DE W1AW K"), (1, (string?)null)], calls);
        }
    }

    [Fact]
    public async Task AcquireIsGrantedWhileAnotherClientSends()
    {
        await using var hub = await StartHubAsync();
        hub.CwKeyerHandler = (_, text) => Task.FromResult(text);
        using var a = await ConnectAsync(hub);
        using var b = await ConnectAsync(hub);
        Assert.Equal("""{"type":"cw_keyer_reply","id":1}""", await AskAsync(a, """{"type":"cw_keyer","id":1,"slot":0,"action":"acquire"}"""));
        Assert.Equal("""{"type":"cw_keyer_reply","id":1}""", await AskAsync(b, """{"type":"cw_keyer","id":1,"slot":0,"action":"acquire"}"""));
    }

    [Fact]
    public async Task HandlerFailuresAndNoRigAreErrors()
    {
        await using var hub = await StartHubAsync();
        using var asker = await ConnectAsync(hub);
        Assert.Equal("""{"type":"cw_keyer_reply","id":1,"error":"Not connected to the rig","errorCode":"rigctld_not_connected"}""",
            await AskAsync(asker, """{"type":"cw_keyer","id":1,"slot":1,"text":"CQ"}"""));
        hub.CwKeyerHandler = (_, _) => throw new InvalidOperationException("The rig rejected the keyer memory write.");
        Assert.Equal("""{"type":"cw_keyer_reply","id":2,"error":"The rig rejected the keyer memory write."}""",
            await AskAsync(asker, """{"type":"cw_keyer","id":2,"slot":1,"text":"CQ"}"""));
    }

    [Fact]
    public async Task KeyerPlayerDisconnectIsRaised()
    {
        await using var hub = await StartHubAsync();
        var gone = new List<int>();
        var commands = 0;
        hub.KeyerPlayerDisconnected += id =>
        {
            lock (gone)
            {
                gone.Add(id);
            }
        };
        hub.CommandReceived += (_, _) => Interlocked.Increment(ref commands);
        var a = await ConnectAsync(hub);
        var b = await ConnectAsync(hub);
        await WaitUntilAsync(() => hub.Clients.Count == 2);
        var ids = hub.Clients.Select(c => c.Id).ToList();

        await SendAsync(a, """{"cmd":"play_cw_text_memory","value":1}""");
        await WaitUntilAsync(() => commands == 1);
        Assert.Equal(ids[0], hub.KeyerPlayer);

        // B never played: its disconnect stops nothing.
        await b.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
        b.Dispose();
        await WaitUntilAsync(() => hub.Clients.Count == 1);
        lock (gone)
        {
            Assert.Empty(gone);
        }

        // A drops without stopping: raised (MainWindow sends a confirmed KY00).
        a.Abort();
        a.Dispose();
        await WaitUntilAsync(() => hub.Clients.Count == 0);
        await WaitUntilAsync(() => { lock (gone) { return gone.Count == 1; } });
        Assert.Equal(ids[0], gone[0]);
        Assert.Null(hub.KeyerPlayer);
    }

    [Fact]
    public async Task PlayersOwnStopClearsIt()
    {
        await using var hub = await StartHubAsync();
        var gone = 0;
        var commands = 0;
        hub.KeyerPlayerDisconnected += _ => Interlocked.Increment(ref gone);
        hub.CommandReceived += (_, _) => Interlocked.Increment(ref commands);
        var a = await ConnectAsync(hub);
        await SendAsync(a, """{"cmd":"play_cw_text_memory","value":1}""");
        await SendAsync(a, """{"cmd":"play_cw_text_memory","value":0}""");
        await WaitUntilAsync(() => commands == 2);
        Assert.Null(hub.KeyerPlayer);
        a.Abort();
        a.Dispose();
        await WaitUntilAsync(() => hub.Clients.Count == 0);
        await Task.Delay(100);
        Assert.Equal(0, gone);
    }

    // C#-made fixtures for the Mac's HubWireFixtureTests, captured from the
    // real server's replies. Re-run and commit after any change to the
    // reply code (HubServer.AnswerCwKeyerAsync, HubKeyer.cs).

    [Fact]
    public async Task WritesWindowsKeyerReplyFixtures()
    {
        await using var hub = await StartHubAsync();
        hub.CwKeyerHandler = (_, text) => Task.FromResult(text);
        using var asker = await ConnectAsync(hub);
        WriteFixture("cw-keyer-reply.stored.json",
            await AskAsync(asker, """{"type":"cw_keyer","id":7,"slot":1,"text":"CQ CQ DE W1AW K"}"""));
        WriteFixture("cw-keyer-reply.checked.json",
            await AskAsync(asker, """{"type":"cw_keyer","id":8,"slot":1}"""));
        WriteFixture("cw-keyer-reply.error.json",
            await AskAsync(asker, """{"type":"cw_keyer","id":7,"slot":9,"text":"CQ CQ DE W1AW K"}"""));
    }

    private static void WriteFixture(string name, string json)
    {
        var reply = HubWire.Deserialize<CwKeyerReplyWire>(json)!;
        using (var a = JsonDocument.Parse(json))
        using (var b = JsonDocument.Parse(HubWire.Serialize(reply)))
        {
            AssertJsonEqual(a.RootElement, b.RootElement, "$");
        }
        var indented = JsonSerializer.Serialize(reply, new JsonSerializerOptions(HubWire.JsonOptions)
        {
            WriteIndented = true,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
        var dir = Path.Combine(FixturesDir, "windows");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, name), indented + "\n");
    }

    // Helpers.

    /// Re-encodes a reply with relaxed escaping, so a non-ASCII message
    /// compares as written.
    private static string Decode(string json) => JsonSerializer.Serialize(HubWire.Deserialize<CwKeyerReplyWire>(json),
        new JsonSerializerOptions(HubWire.JsonOptions) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });

    private static async Task<string> AskAsync(ClientWebSocket socket, string json)
    {
        await SendAsync(socket, json);
        return await ReceiveAsync(socket, TimeSpan.FromSeconds(5));
    }

    private static async Task<HubServer> StartHubAsync()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var hub = new HubServer(port, loopbackOnly: true);
        await hub.StartAsync();
        Assert.True(hub.IsListening, hub.LastError);
        return hub;
    }

    private static async Task<ClientWebSocket> ConnectAsync(HubServer hub)
    {
        var socket = new ClientWebSocket();
        await socket.ConnectAsync(new Uri($"ws://127.0.0.1:{hub.ListenPort}/"), CancellationToken.None);
        return socket;
    }

    /// As the iPad sends it: JSON in a binary frame.
    private static Task SendAsync(ClientWebSocket socket, string json) =>
        socket.SendAsync(Encoding.UTF8.GetBytes(json), WebSocketMessageType.Binary, true, CancellationToken.None);

    private static async Task<string> ReceiveAsync(ClientWebSocket socket, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        var buffer = new byte[64 * 1024];
        var message = new MemoryStream();
        while (true)
        {
            var result = await socket.ReceiveAsync(buffer, cts.Token);
            message.Write(buffer, 0, result.Count);
            if (result.EndOfMessage)
            {
                return Encoding.UTF8.GetString(message.ToArray());
            }
        }
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "timed out");
            await Task.Delay(10);
        }
    }
}

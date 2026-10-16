using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services.Hub;
using Xunit;
using static FTX1RemoteWindows.Tests.HubWireTests;

namespace FTX1RemoteWindows.Tests;

/// Phase 4 (Apps/Windows/README.md, "Desktop hub for the iPad"): the memory
/// list and APRS history pushes and the Deep Settings read pair — the
/// Swift-made fixtures round-trip, the throttles, a menu read answered to
/// the asking client only, list pushes kept apart from state pushes, and
/// the C#-made fixtures for the Mac's HubWireFixtureTests.
public class HubListTests
{
    // Swift fixtures: decode and re-encode to the same JSON.

    [Theory]
    [InlineData("memory-list-push.json")]
    [InlineData("memory-list-push.scanning.json")]
    public void MemoryListFixtureRoundTrips(string fileName) => RoundTrips<MemoryListPushWire>(fileName);

    [Fact]
    public void AprsListFixtureRoundTrips() => RoundTrips<AprsListPushWire>("aprs-list-push.json");

    [Theory]
    [InlineData("menu-item-push.json")]
    [InlineData("menu-item-push.unreadable.json")]
    public void MenuItemPushFixtureRoundTrips(string fileName) => RoundTrips<MenuItemPushWire>(fileName);

    [Fact]
    public void MenuItemReadRequestFixtureRoundTripsAndParses()
    {
        RoundTrips<MenuItemReadRequestWire>("menu-item-read-request.json");
        var inbound = RigCommandWire.ParseInbound(File.ReadAllText(Path.Combine(FixturesDir, "menu-item-read-request.json")));
        Assert.Equal(InboundKind.MenuItemRead, inbound.Kind);
        Assert.Equal((6, 1, 3), (inbound.MenuRead!.P1, inbound.MenuRead.P2, inbound.MenuRead.P3));
        Assert.True(inbound.MenuRead.IsValidAddress);
    }

    [Theory]
    [InlineData("""{"type":"read_menu_item","p1":6,"p2":1}""")]
    [InlineData("""{"type":"read_menu_item","p1":"6","p2":1,"p3":3}""")]
    [InlineData("""{"type":"read_menu_item","p1":6.5,"p2":1,"p3":3}""")]
    [InlineData("""{"type":"read_menu_item","p1":99999999999,"p2":1,"p3":3}""")]
    public void MalformedMenuItemReadIsInvalid(string json) =>
        Assert.Equal(InboundKind.Invalid, RigCommandWire.ParseInbound(json).Kind);

    [Theory]
    [InlineData(0, 0, 0, true)]
    [InlineData(99, 99, 99, true)]
    [InlineData(100, 1, 3, false)]
    [InlineData(6, -1, 3, false)]
    [InlineData(6, 1, 100, false)]
    public void MenuReadAddressRange(int p1, int p2, int p3, bool valid) =>
        Assert.Equal(valid, new MenuItemReadRequestWire { P1 = p1, P2 = p2, P3 = p3 }.IsValidAddress);

    private static void RoundTrips<T>(string fileName)
    {
        var original = File.ReadAllText(Path.Combine(FixturesDir, fileName));
        var message = HubWire.Deserialize<T>(original);
        Assert.NotNull(message);
        using var a = JsonDocument.Parse(original);
        using var b = JsonDocument.Parse(HubWire.Serialize(message!));
        AssertJsonEqual(a.RootElement, b.RootElement, "$");
    }

    // Throttles.

    [Fact]
    public void ThrottleSendsTheFirstChangeAtOnceAndCoalescesTheRest()
    {
        var throttle = new HubPushThrottle(TimeSpan.FromSeconds(1));
        Assert.False(throttle.TakeDue(0)); // nothing changed
        throttle.MarkDirty();
        Assert.True(throttle.TakeDue(0));
        Assert.False(throttle.TakeDue(50)); // sent, nothing new
        throttle.MarkDirty();
        throttle.MarkDirty();
        Assert.False(throttle.TakeDue(100));
        Assert.False(throttle.TakeDue(999));
        Assert.True(throttle.TakeDue(1000)); // one trailing push for both
        Assert.False(throttle.TakeDue(5000));
        throttle.MarkDirty();
        Assert.True(throttle.TakeDue(5000)); // quiet for longer than the interval: at once
    }

    [Fact]
    public void AprsThrottleIsTwoSeconds()
    {
        var throttle = new HubPushThrottle(TimeSpan.FromSeconds(2));
        throttle.MarkDirty();
        Assert.True(throttle.TakeDue(10_000));
        throttle.MarkDirty();
        Assert.False(throttle.TakeDue(11_900));
        Assert.True(throttle.TakeDue(12_000));
    }

    // The server, on loopback.

    [Fact]
    public async Task MenuReadIsAnsweredOnlyToTheAsker()
    {
        var reads = new List<(int, int, int)>();
        await using var hub = await StartHubAsync();
        hub.MenuItemReader = (p1, p2, p3) =>
        {
            lock (reads)
            {
                reads.Add((p1, p2, p3));
            }
            return p3 == 4 ? throw new TimeoutException("no reply") : Task.FromResult<string?>("1");
        };
        using var asker = await ConnectAsync(hub);
        using var other = await ConnectAsync(hub);
        // Listens across all three reads below; must get nothing.
        var otherReceive = ReceiveAsync(other, TimeSpan.FromSeconds(2));

        // As the iPad sends it: JSON in a binary frame.
        await SendAsync(asker, """{"type":"read_menu_item","p1":6,"p2":1,"p3":3}""", WebSocketMessageType.Binary);
        using (var reply = JsonDocument.Parse(await ReceiveAsync(asker, TimeSpan.FromSeconds(5))))
        {
            AssertJsonEqual(JsonDocument.Parse("""{"type":"menu_item","p1":6,"p2":1,"p3":3,"value":"1"}""").RootElement,
                reply.RootElement, "$");
        }

        // Out of range: unreadable, and the rig isn't asked.
        await SendAsync(asker, """{"type":"read_menu_item","p1":100,"p2":1,"p3":3}""", WebSocketMessageType.Text);
        using (var reply = JsonDocument.Parse(await ReceiveAsync(asker, TimeSpan.FromSeconds(5))))
        {
            Assert.Equal(100, reply.RootElement.GetProperty("p1").GetInt32());
            Assert.False(reply.RootElement.TryGetProperty("value", out _));
        }

        // A read that throws: unreadable too.
        await SendAsync(asker, """{"type":"read_menu_item","p1":6,"p2":1,"p3":4}""", WebSocketMessageType.Binary);
        using (var reply = JsonDocument.Parse(await ReceiveAsync(asker, TimeSpan.FromSeconds(5))))
        {
            Assert.Equal(4, reply.RootElement.GetProperty("p3").GetInt32());
            Assert.False(reply.RootElement.TryGetProperty("value", out _));
        }
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => otherReceive);
        lock (reads)
        {
            Assert.Equal([(6, 1, 3), (6, 1, 4)], reads);
        }
    }

    [Fact]
    public async Task ListPushesAreKeptApartFromStatePushes()
    {
        await using var hub = await StartHubAsync();
        hub.PublishMemoryList("""{"type":"memory_list","list":{"entries":[]}}""");
        hub.Publish("""{"type":"state","n":1}""");
        hub.PublishAprsList("""{"type":"aprs_list","stations":[],"messages":[]}""");
        hub.Publish("""{"type":"state","n":2}""");

        // On connect: the newest of each kind, none replacing another.
        using var client = await ConnectAsync(hub);
        var received = await ReceiveTypesAsync(client, 3);
        Assert.Equal(["aprs_list", "memory_list", "state"], received.Keys.Order());
        Assert.Contains("\"n\":2", received["state"]);

        // While connected: a burst of each still delivers each kind.
        hub.PublishMemoryList("""{"type":"memory_list","list":{"entries":[],"scanningChannel":5}}""");
        hub.Publish("""{"type":"state","n":3}""");
        hub.PublishAprsList("""{"type":"aprs_list","stations":[],"messages":[],"x":1}""");
        hub.Publish("""{"type":"state","n":4}""");
        received = await ReceiveTypesAsync(client, 3);
        Assert.Contains("scanningChannel", received["memory_list"]);
        Assert.Contains("\"x\":1", received["aprs_list"]);
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

    private static Task SendAsync(ClientWebSocket socket, string json, WebSocketMessageType type) =>
        socket.SendAsync(Encoding.UTF8.GetBytes(json), type, true, CancellationToken.None);

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

    private static async Task<Dictionary<string, string>> ReceiveTypesAsync(ClientWebSocket socket, int count)
    {
        var byType = new Dictionary<string, string>();
        for (var i = 0; i < count; i++)
        {
            var json = await ReceiveAsync(socket, TimeSpan.FromSeconds(5));
            using var doc = JsonDocument.Parse(json);
            byType[doc.RootElement.GetProperty("type").GetString()!] = json;
        }
        Assert.Equal(count, byType.Count);
        return byType;
    }

    // C#-made fixtures for the Mac's HubWireFixtureTests, from the real
    // mappers and models (MemoryChannelEntry.Parse on real-shaped "MR"
    // answers). Re-run and commit after any change to HubListWire.cs.

    private static readonly DateTimeOffset At = HubWire.FromSwiftDate(813754800); // 2026-10-15T11:00:00Z

    [Fact]
    public void WritesWindowsMemoryListFixture()
    {
        MemoryChannelEntry Entry(string mr, string? tag)
        {
            var entry = MemoryChannelEntry.Parse(mr)!;
            entry.Tag = tag;
            return entry;
        }
        var push = HubListWireMapper.MemoryList(
        [
            Entry("MR00001146520000+000000410000;", "CALL 2M"),
            Entry("MR00002146940000+000000412002;", null),
            Entry("MR00003446000000+000000410000;", ""), // a blank tag is no tag
            Entry("MR00101014074000+000000C10000;", "FT8 20M"),
        ], At, null);
        var root = WriteFixture("memory-list-push.json", push);
        var list = root.GetProperty("list");
        Assert.Equal("memory_list", root.GetProperty("type").GetString());
        Assert.Equal(813754800.0, list.GetProperty("scanned").GetDouble());
        Assert.False(list.TryGetProperty("scanningChannel", out _));
        var entries = list.GetProperty("entries").EnumerateArray().ToArray();
        Assert.Equal([1, 2, 3, 101], entries.Select(e => e.GetProperty("channel").GetInt32()));
        Assert.Equal("4", entries[0].GetProperty("modeCode").GetString());
        Assert.Equal("C", entries[3].GetProperty("modeCode").GetString());
        Assert.Equal(146_940_000, entries[1].GetProperty("frequencyHz").GetInt64());
        Assert.Equal((2, 2), (entries[1].GetProperty("toneMode").GetInt32(), entries[1].GetProperty("shift").GetInt32()));
        Assert.False(entries[1].TryGetProperty("tag", out _));
        Assert.False(entries[2].TryGetProperty("tag", out _));
        Assert.Equal("CALL 2M", entries[0].GetProperty("tag").GetString());

        // While a read runs.
        var scanning = HubListWireMapper.MemoryList([Entry("MR00001146520000+000000410000;", null)], null, 37);
        using var doc = JsonDocument.Parse(HubWire.Serialize(scanning));
        Assert.Equal(37, doc.RootElement.GetProperty("list").GetProperty("scanningChannel").GetInt32());
        Assert.False(doc.RootElement.GetProperty("list").TryGetProperty("scanned", out _));
    }

    [Fact]
    public void WritesWindowsAprsListFixture()
    {
        var stations = new[]
        {
            new AprsStation
            {
                Callsign = "W1AW-9", Latitude = 41.7147, Longitude = -72.7272, SymbolTable = "/", SymbolCode = ">",
                Comment = "Mobile 146.520", LastHeardAt = At, Source = AprsSource.Main,
            },
            new AprsStation { Callsign = "K6NA-7", LastHeardAt = At.AddSeconds(30), Source = AprsSource.Sub },
        };
        var messages = new[]
        {
            new AprsMessage
            {
                Id = "6F1C2A4E-2222-4A2B-9C3D-000000000001", From = "W1AW-9", To = "DEMO", Text = "Hello from Windows",
                MessageId = "12", ReceivedAt = At, Source = AprsSource.Main,
            },
            new AprsMessage
            {
                From = "K6NA-7", To = "BLNA", Text = "Net tonight 2000", ReceivedAt = At.AddSeconds(60), Source = AprsSource.Sub,
            },
        };
        // The id is the store's own, so the same message keeps it across pushes.
        var first = HubListWireMapper.AprsList(stations, messages);
        Assert.Equal(first.Messages[1].Id, HubListWireMapper.AprsList(stations, messages).Messages[1].Id);
        Assert.False(string.IsNullOrEmpty(first.Messages[1].Id));
        // A fixed id in the committed file, so re-running doesn't change it.
        messages[1].Id = "6F1C2A4E-2222-4A2B-9C3D-000000000002";

        var root = WriteFixture("aprs-list-push.json", HubListWireMapper.AprsList(stations, messages));
        Assert.Equal("aprs_list", root.GetProperty("type").GetString());
        var s = root.GetProperty("stations").EnumerateArray().ToArray();
        Assert.Equal(41.7147, s[0].GetProperty("latitude").GetDouble());
        Assert.Equal("main", s[0].GetProperty("source").GetString());
        Assert.Equal("sub", s[1].GetProperty("source").GetString());
        Assert.Equal(813754830.0, s[1].GetProperty("lastHeardAt").GetDouble());
        foreach (var key in new[] { "latitude", "longitude", "symbolTable", "symbolCode", "comment" })
        {
            Assert.False(s[1].TryGetProperty(key, out _), key);
        }
        var m = root.GetProperty("messages").EnumerateArray().ToArray();
        Assert.Equal("12", m[0].GetProperty("messageID").GetString());
        Assert.False(m[1].TryGetProperty("messageID", out _));
        Assert.Equal("sub", m[1].GetProperty("source").GetString());
        Assert.Equal(813754860.0, m[1].GetProperty("receivedAt").GetDouble());
    }

    [Fact]
    public void WritesWindowsMenuItemFixtures()
    {
        var readable = WriteFixture("menu-item-push.json", new MenuItemPushWire { P1 = 6, P2 = 1, P3 = 3, Value = "1" });
        Assert.Equal("menu_item", readable.GetProperty("type").GetString());
        Assert.Equal("1", readable.GetProperty("value").GetString());
        var unreadable = WriteFixture("menu-item-push.unreadable.json", new MenuItemPushWire { P1 = 6, P2 = 1, P3 = 3 });
        Assert.False(unreadable.TryGetProperty("value", out _));
    }

    /// Writes Tests/WireFixtures/windows/<name> (indented, as the Swift ones)
    /// after checking it decodes back to the same JSON; returns the parsed root.
    private static JsonElement WriteFixture<T>(string name, T message)
    {
        var compact = HubWire.Serialize(message);
        using var a = JsonDocument.Parse(compact);
        using var b = JsonDocument.Parse(HubWire.Serialize(HubWire.Deserialize<T>(compact)!));
        AssertJsonEqual(a.RootElement, b.RootElement, "$");

        var indented = JsonSerializer.Serialize(message, new JsonSerializerOptions(HubWire.JsonOptions)
        {
            WriteIndented = true,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
        var dir = Path.Combine(FixturesDir, "windows");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, name), indented + "\n");
        return JsonDocument.Parse(compact).RootElement.Clone();
    }
}

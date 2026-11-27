using System.Diagnostics;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using FTX1RemoteWindows.Services.FreeDv;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;
using Xunit.Abstractions;

namespace FTX1RemoteWindows.Tests;

/// FreeDV Reporter — the Mac's FreeDVReporterTests (wire format and station
/// list), plus the client against a stand-in server on loopback.
public class FreeDvReporterTests(ITestOutputHelper output)
{
    [Fact]
    public void Url() => Assert.Equal(
        "wss://qso.freedv.org/socket.io/?EIO=4&transport=websocket", FreeDvReporterProtocol.Url().AbsoluteUri);

    [Fact]
    public void ParsesEngineIoAndSocketIoPackets()
    {
        var open = FreeDvReporterProtocol.Parse("""0{"sid":"abc","upgrades":[],"pingInterval":25000,"pingTimeout":20000}""");
        Assert.Equal(FreeDvReporterProtocol.Kind.Open, open.Kind);
        Assert.Equal((25.0, 20.0), (open.PingInterval, open.PingTimeout));
        Assert.Equal(FreeDvReporterProtocol.Kind.Ping, FreeDvReporterProtocol.Parse("2").Kind);
        Assert.Equal(FreeDvReporterProtocol.Kind.Close, FreeDvReporterProtocol.Parse("1").Kind);
        Assert.Equal(FreeDvReporterProtocol.Kind.Connected, FreeDvReporterProtocol.Parse("""40{"sid":"xyz"}""").Kind);
        Assert.Equal(FreeDvReporterProtocol.Kind.Disconnected, FreeDvReporterProtocol.Parse("41").Kind);
        var refused = FreeDvReporterProtocol.Parse("""44{"message":"Not authorized"}""");
        Assert.Equal((FreeDvReporterProtocol.Kind.ConnectError, "Not authorized"), (refused.Kind, refused.Name));
        var change = FreeDvReporterProtocol.Parse("""42["freq_change",{"sid":"s1","freq":14236000}]""");
        Assert.Equal((FreeDvReporterProtocol.Kind.Event, "freq_change"), (change.Kind, change.Name));
        Assert.Equal(14_236_000, change.Payload!.Value.GetProperty("freq").GetInt32());
        var success = FreeDvReporterProtocol.Parse("""42["connection_successful"]""");
        Assert.Equal("connection_successful", success.Name);
        Assert.Null(success.Payload);
        Assert.Equal(FreeDvReporterProtocol.Kind.Unknown, FreeDvReporterProtocol.Parse("42not json").Kind);
        Assert.Equal(FreeDvReporterProtocol.Kind.Unknown, FreeDvReporterProtocol.Parse("").Kind);
    }

    [Fact]
    public void OutgoingFrames()
    {
        var connect = FreeDvReporterProtocol.ConnectFrame("TE5T", "FN31", "FTX1Remote 1.0", false, "Windows");
        Assert.StartsWith("40{", connect);
        var auth = JsonDocument.Parse(connect[2..]).RootElement;
        Assert.Equal("report", auth.GetProperty("role").GetString());
        Assert.Equal("TE5T", auth.GetProperty("callsign").GetString());
        Assert.Equal("FN31", auth.GetProperty("grid_square").GetString());
        Assert.False(auth.GetProperty("rx_only").GetBoolean());
        Assert.Equal("Windows", auth.GetProperty("os").GetString());
        Assert.Equal(2, auth.GetProperty("protocol_version").GetInt32());
        Assert.Equal("""42["freq_change",{"freq":14236000}]""", FreeDvReporterProtocol.FrequencyChange(14_236_000));
        Assert.Equal("""42["tx_report",{"mode":"RADEV1","transmitting":true}]""", FreeDvReporterProtocol.TransmitReport(true));
        Assert.Equal("""42["rx_report",{"callsign":"VK3TPM","mode":"RADEV1","snr":12}]""",
            FreeDvReporterProtocol.ReceiveReport("VK3TPM", 12));
        Assert.Equal("""42["message_update",{"message":"CQ 20m"}]""", FreeDvReporterProtocol.Message("CQ 20m"));
    }

    private static bool Apply(FreeDvReporterStations table, string frame)
    {
        var incoming = FreeDvReporterProtocol.Parse(frame);
        return incoming.Kind == FreeDvReporterProtocol.Kind.Event && table.Apply(incoming.Name, incoming.Payload);
    }

    /// Event shapes as freedv-backend's FreeDVReporter reads them.
    [Fact]
    public void StationList()
    {
        var table = new FreeDvReporterStations();
        Assert.True(Apply(table, """42["new_connection",{"sid":"s1","last_update":"2026-11-27T10:00:00.123456","callsign":"VK3TPM","grid_square":"QF22","version":"FreeDV 2.2","rx_only":false,"connect_time":"2026-11-27T09:00:00"}]"""));
        Assert.True(Apply(table, """42["freq_change",{"sid":"s1","last_update":"2026-11-27T10:00:01","callsign":"VK3TPM","grid_square":"QF22","freq":14236000}]"""));
        Assert.True(Apply(table, """42["tx_report",{"sid":"s1","last_update":"2026-11-27T10:00:02","callsign":"VK3TPM","grid_square":"QF22","last_tx":null,"mode":"RADEV1","transmitting":true}]"""));
        Assert.True(Apply(table, """42["rx_report",{"sid":"s1","last_update":"2026-11-27T10:00:03","receiver_callsign":"VK3TPM","receiver_grid_square":"QF22","callsign":"VK5KVA","snr":7.5,"mode":"RADEV1"}]"""));
        Assert.True(Apply(table, """42["message_update",{"sid":"s1","last_update":"2026-11-27T10:00:04","message":"Listening 20m"}]"""));
        var station = table.Stations["s1"];
        Assert.Equal("VK3TPM", station.Callsign);
        Assert.Equal("QF22", station.GridSquare);
        Assert.Equal("FreeDV 2.2", station.Version);
        Assert.Equal(14_236_000, station.FrequencyHz);
        Assert.Equal("RADEV1", station.Mode);
        Assert.True(station.Transmitting);
        Assert.Equal("VK5KVA", station.LastHeardCallsign);
        Assert.Equal(7.5, station.LastHeardSnr);
        Assert.Equal("Listening 20m", station.Message);
        Assert.Equal(new DateTime(2026, 11, 27, 10, 0, 4, DateTimeKind.Utc), station.LastUpdateUtc);

        // An event for a station we don't know is ignored; remove drops it.
        Assert.False(Apply(table, """42["freq_change",{"sid":"unknown","freq":7177000}]"""));
        Assert.True(Apply(table, """42["remove_connection",{"sid":"s1","last_update":"2026-11-27T10:05:00","callsign":"VK3TPM","grid_square":"QF22","version":"","rx_only":false}]"""));
        Assert.Empty(table.Stations);
    }

    [Fact]
    public void BulkUpdateAndOrder()
    {
        var table = new FreeDvReporterStations();
        Assert.True(Apply(table, """42["bulk_update",[["new_connection",{"sid":"a","last_update":"2026-11-27T10:00:00","callsign":"W1AW","grid_square":"FN31","version":"x","rx_only":true,"connect_time":"2026-11-27T10:00:00"}],["freq_change",{"sid":"a","last_update":"2026-11-27T10:00:01","callsign":"W1AW","grid_square":"FN31","freq":7177000}],["chat_message",{"text":"hi"}],["new_connection",{"sid":"b","last_update":"2026-11-27T10:00:02","callsign":"K1ABC","grid_square":null}]]]"""));
        Assert.Equal(7_177_000, table.Stations["a"].FrequencyHz);
        Assert.True(table.Stations["a"].ReceiveOnly);
        Assert.Equal(["K1ABC", "W1AW"], table.Sorted().Select(s => s.Callsign));
    }

    [Fact]
    public void Timestamps()
    {
        var expected = new DateTime(2026, 11, 27, 10, 0, 0, DateTimeKind.Utc);
        Assert.Equal(expected, FreeDvReporterProtocol.Timestamp("2026-11-27T10:00:00Z"));
        Assert.Equal(expected.AddTicks(1_234_560), FreeDvReporterProtocol.Timestamp("2026-11-27T10:00:00.123456+00:00"));
        Assert.Equal(expected.AddTicks(1_234_560), FreeDvReporterProtocol.Timestamp("2026-11-27T10:00:00.123456"));
        Assert.Null(FreeDvReporterProtocol.Timestamp("yesterday"));
        Assert.Null(FreeDvReporterProtocol.Timestamp(null));
    }

    // The client, against a stand-in server.

    /// A loopback WebSocket server speaking just enough of the protocol,
    /// recording what the client sends.
    private sealed class StandInServer : IAsyncDisposable
    {
        private readonly WebApplication _app;
        public List<string> Received { get; } = [];
        public int Connections;
        public bool Closed;
        public Uri Url { get; private set; } = null!;
        private WebSocket? _socket;

        private StandInServer(WebApplication app) => _app = app;

        public static async Task<StandInServer> StartAsync()
        {
            var builder = WebApplication.CreateSlimBuilder();
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(k => k.Listen(IPAddress.Loopback, 0));
            var app = builder.Build();
            var server = new StandInServer(app);
            app.UseWebSockets();
            app.Run(async context =>
            {
                using var socket = await context.WebSockets.AcceptWebSocketAsync();
                server._socket = socket;
                Interlocked.Increment(ref server.Connections);
                await server.SendAsync("""0{"sid":"x","pingInterval":25000,"pingTimeout":20000}""");
                var buffer = new byte[8192];
                try
                {
                    while (true)
                    {
                        var result = await socket.ReceiveAsync(buffer, context.RequestAborted);
                        if (result.MessageType == WebSocketMessageType.Close)
                        {
                            break;
                        }
                        var frame = Encoding.UTF8.GetString(buffer, 0, result.Count);
                        lock (server.Received)
                        {
                            server.Received.Add(frame);
                        }
                        if (frame.StartsWith("40", StringComparison.Ordinal))
                        {
                            await server.SendAsync("""40{"sid":"y"}""");
                            await server.SendAsync("""42["connection_successful",{}]""");
                            await server.SendAsync("""42["bulk_update",[["new_connection",{"sid":"a","callsign":"W1AW","grid_square":"FN31"}]]]""");
                            await server.SendAsync("2");
                        }
                    }
                }
                catch (Exception)
                {
                    // The client went away.
                }
                server.Closed = true;
            });
            await app.StartAsync();
            var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
            server.Url = new Uri(address.Replace("http://", "ws://") + "/socket.io/?EIO=4&transport=websocket");
            return server;
        }

        public Task SendAsync(string frame) =>
            _socket!.SendAsync(Encoding.UTF8.GetBytes(frame), WebSocketMessageType.Text, true, CancellationToken.None);

        public async Task DropAsync() =>
            await _socket!.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);

        public List<string> Frames()
        {
            lock (Received)
            {
                return [.. Received];
            }
        }

        public async ValueTask DisposeAsync()
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            try
            {
                await _app.StopAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
            }
            await _app.DisposeAsync();
        }
    }

    private static async Task Until(Func<bool> condition, double seconds = 10)
    {
        var watch = Stopwatch.StartNew();
        while (!condition())
        {
            Assert.True(watch.Elapsed.TotalSeconds < seconds, "timed out");
            await Task.Delay(20);
        }
    }

    [Fact]
    public async Task ReportsOurStateAndListsStations()
    {
        await using var server = await StandInServer.StartAsync();
        var settings = new FreeDvData { ReporterMessage = "hello" };
        var station = ("te5t", "FN31");
        var reporter = new FreeDvReporter(settings, () => { }, "FTX1Remote test", () => station,
            output.WriteLine, server.Url);
        reporter.SetFrequency(14_236_000);

        // Off until both enabled and the window is open.
        reporter.SetActive(true);
        Assert.Equal(FreeDvReporter.ConnectionStatus.Off, reporter.Status);
        Assert.Equal(0, server.Connections);
        reporter.Enabled = true;
        await Until(() => reporter.Status == FreeDvReporter.ConnectionStatus.Connected && reporter.Stations.Count == 1);
        Assert.Equal("W1AW", reporter.Stations[0].Callsign);
        await Until(() => server.Frames().Contains("3"));
        var frames = server.Frames();
        Assert.Contains("\"callsign\":\"TE5T\"", frames[0]);
        Assert.Equal(
            [FreeDvReporterProtocol.FrequencyChange(14_236_000), FreeDvReporterProtocol.TransmitReport(false),
                FreeDvReporterProtocol.Message("hello")],
            frames.Skip(1).Where(f => f != "3").Take(3));

        reporter.SetTransmitting(true);
        reporter.SetTransmitting(false);
        reporter.ReportHeard("VK3TPM", 11.6f);
        reporter.Message = "bye";
        await Until(() => server.Frames().Contains(FreeDvReporterProtocol.Message("bye")));
        // In the order sent.
        Assert.Equal(
            [FreeDvReporterProtocol.TransmitReport(true), FreeDvReporterProtocol.TransmitReport(false),
                FreeDvReporterProtocol.ReceiveReport("VK3TPM", 12), FreeDvReporterProtocol.Message("bye")],
            server.Frames().TakeLast(4));

        // The window closing disconnects.
        reporter.SetActive(false);
        Assert.Equal(FreeDvReporter.ConnectionStatus.Off, reporter.Status);
        Assert.Empty(reporter.Stations);
        await Until(() => server.Closed);
    }

    [Fact]
    public async Task ADroppedConnectionRetriesAndANewCallsignReconnects()
    {
        await using var server = await StandInServer.StartAsync();
        var station = ("TE5T", "FN31");
        var reporter = new FreeDvReporter(new FreeDvData { ReporterEnabled = true }, () => { }, "FTX1Remote test",
            () => station, output.WriteLine, server.Url);
        reporter.SetActive(true);
        await Until(() => reporter.Status == FreeDvReporter.ConnectionStatus.Connected);

        // Nothing changed: no reconnect.
        reporter.StationChanged();
        Assert.Equal(FreeDvReporter.ConnectionStatus.Connected, reporter.Status);
        station = ("TE5T/P", "FN31");
        reporter.StationChanged();
        await Until(() => server.Connections == 2 && reporter.Status == FreeDvReporter.ConnectionStatus.Connected);

        await server.DropAsync();
        await Until(() => reporter.Status == FreeDvReporter.ConnectionStatus.Retrying);
        Assert.NotEqual("", reporter.RetryReason);
        // After the first delay (5 s).
        await Until(() => server.Connections == 3 && reporter.Status == FreeDvReporter.ConnectionStatus.Connected, 15);
        reporter.Enabled = false;
        Assert.Equal(FreeDvReporter.ConnectionStatus.Off, reporter.Status);
    }

    [Fact]
    public void WithoutACallsignOrGridItDoesNotConnect()
    {
        var station = ("", "FN31");
        var reporter = new FreeDvReporter(new FreeDvData { ReporterEnabled = true }, () => { }, "test",
            () => station, url: new Uri("ws://127.0.0.1:1/"));
        reporter.SetActive(true);
        Assert.Equal(FreeDvReporter.ConnectionStatus.NeedsStation, reporter.Status);
        station = ("TE5T", "FN");
        reporter.StationChanged();
        Assert.Equal(FreeDvReporter.ConnectionStatus.NeedsStation, reporter.Status);
    }

    /// Connects read-only (role "view", as the website does — nothing about us
    /// is sent). Does nothing unless FREEDV_REPORTER_LIVE=1.
    [Fact]
    public async Task LiveViewConnectionReceivesStations()
    {
        if (Environment.GetEnvironmentVariable("FREEDV_REPORTER_LIVE") != "1")
        {
            return;
        }
        using var socket = new ClientWebSocket();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        await socket.ConnectAsync(FreeDvReporterProtocol.Url(), timeout.Token);
        var table = new FreeDvReporterStations();
        var buffer = new byte[16 * 1024];
        using var message = new MemoryStream();
        var connected = false;
        while (table.Stations.Count <= 5 || !connected)
        {
            var result = await socket.ReceiveAsync(buffer.AsMemory(), timeout.Token);
            message.Write(buffer, 0, result.Count);
            if (!result.EndOfMessage)
            {
                continue;
            }
            var incoming = FreeDvReporterProtocol.Parse(Encoding.UTF8.GetString(message.ToArray()));
            message.SetLength(0);
            var reply = incoming.Kind switch
            {
                FreeDvReporterProtocol.Kind.Open => FreeDvReporterProtocol.ViewConnectFrame(),
                FreeDvReporterProtocol.Kind.Ping => FreeDvReporterProtocol.Pong,
                _ => null,
            };
            if (reply is not null)
            {
                await socket.SendAsync(Encoding.UTF8.GetBytes(reply), WebSocketMessageType.Text, true, timeout.Token);
            }
            connected |= incoming.Kind == FreeDvReporterProtocol.Kind.Connected;
            if (incoming.Kind == FreeDvReporterProtocol.Kind.Event)
            {
                table.Apply(incoming.Name, incoming.Payload);
            }
        }
        output.WriteLine($"live: {table.Stations.Count} stations, {table.Stations.Values.Count(s => s.FrequencyHz is not null)} with a frequency");
        Assert.Contains(table.Stations.Values, s => s.LastUpdateUtc is not null);
    }
}

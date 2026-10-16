using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Hub;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// Phase 5 of "Desktop hub for the iPad" (Apps/Windows/README.md): the PTT
/// holder and TX frame order through the real HubServer on loopback, the
/// keyed/sink/watchdog state (HubTransmitAudio), and the Remote sink
/// (RemoteTxAudioClient) against a local TCP listener.
public class HubTransmitTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    // HubTransmitAudio

    private sealed class FakeSink : ITxAudioSink
    {
        public List<byte[]> Sent { get; } = [];
        public bool Finished { get; private set; }
        public void Send(byte[] pcm) => Sent.Add(pcm);
        public void Finish() => Finished = true;
    }

    private static (HubTransmitAudio Tx, List<FakeSink> Sinks) NewTx(bool sinkAvailable = true)
    {
        var sinks = new List<FakeSink>();
        var tx = new HubTransmitAudio(() =>
        {
            if (!sinkAvailable)
            {
                return null;
            }
            var sink = new FakeSink();
            sinks.Add(sink);
            return sink;
        });
        return (tx, sinks);
    }

    [Fact]
    public void FramesWhileUnkeyedAreDroppedAndOpenNoSink()
    {
        var (tx, sinks) = NewTx();
        Assert.Equal(TxFrameResult.DroppedNotKeyed, tx.Frame(1, [1, 2], 0));
        Assert.Empty(sinks);
    }

    [Fact]
    public void FramesFromAnotherClientThanTheKeyedOneAreDropped()
    {
        var (tx, sinks) = NewTx();
        tx.Keyed(1, 0);
        Assert.Equal(TxFrameResult.Sent, tx.Frame(1, [1, 2], 10));
        Assert.Equal(TxFrameResult.DroppedNotKeyed, tx.Frame(2, [3, 4], 20));
        Assert.Single(sinks);
        Assert.Single(sinks[0].Sent);
        Assert.False(sinks[0].Finished);
    }

    [Fact]
    public void OneSinkPerTransmissionFinishedOnUnkey()
    {
        var (tx, sinks) = NewTx();
        tx.Keyed(1, 0);
        tx.Frame(1, [1, 2], 10);
        tx.Frame(1, [3, 4], 50);
        Assert.Equal(1, tx.Unkeyed());
        Assert.True(sinks[0].Finished);
        Assert.Equal(2, sinks[0].Sent.Count);
        // After the unkey: dropped, no new sink.
        Assert.Equal(TxFrameResult.DroppedNotKeyed, tx.Frame(1, [5, 6], 60));
        Assert.Single(sinks);
        // The next press gets its own.
        tx.Keyed(1, 100);
        tx.Frame(1, [7, 8], 110);
        Assert.Equal(2, sinks.Count);
        Assert.Null(new HubTransmitAudio(() => null).Unkeyed());
    }

    [Fact]
    public void NoSinkMeansDroppedAndOnlyOneOpenAttemptPerTransmission()
    {
        var attempts = 0;
        var tx = new HubTransmitAudio(() =>
        {
            attempts++;
            return null;
        });
        tx.Keyed(1, 0);
        Assert.Equal(TxFrameResult.DroppedNoSink, tx.Frame(1, [1, 2], 10));
        Assert.Equal(TxFrameResult.DroppedNoSink, tx.Frame(1, [1, 2], 50));
        Assert.Equal(1, attempts);
        tx.Unkeyed();
        tx.Keyed(1, 100);
        tx.Frame(1, [1, 2], 110);
        Assert.Equal(2, attempts);
    }

    [Fact]
    public void WatchdogDoesNotFireWhileFramesKeepComing()
    {
        var (tx, _) = NewTx();
        tx.Keyed(1, 0);
        for (long t = 0; t <= 5000; t += 40)
        {
            tx.Frame(1, [0, 0], t);
            Assert.False(tx.TakeSilenceExpired(t + 20));
        }
    }

    [Fact]
    public void WatchdogFiresOnceAt1500MsOfSilence()
    {
        var (tx, _) = NewTx();
        tx.Keyed(1, 0);
        tx.Frame(1, [0, 0], 1000);
        Assert.False(tx.TakeSilenceExpired(2499));
        Assert.True(tx.TakeSilenceExpired(2500));
        Assert.False(tx.TakeSilenceExpired(2600));
        Assert.False(tx.TakeSilenceExpired(9000));
    }

    [Fact]
    public void WatchdogCountsFromTheKeyWhenNoFrameEverArrives()
    {
        var (tx, _) = NewTx();
        tx.Keyed(1, 10_000);
        Assert.False(tx.TakeSilenceExpired(11_499));
        Assert.True(tx.TakeSilenceExpired(11_500));
    }

    [Fact]
    public void WatchdogIsQuietWhileUnkeyed()
    {
        var (tx, _) = NewTx();
        Assert.False(tx.TakeSilenceExpired(100_000));
        tx.Keyed(1, 0);
        tx.Unkeyed();
        Assert.False(tx.TakeSilenceExpired(100_000));
    }

    // HubServer: PTT holder and order

    /// Everything one HubServer raised, in order.
    private sealed class Recorder
    {
        public ConcurrentQueue<string> Events { get; } = new();

        public Recorder(HubServer hub)
        {
            hub.CommandReceived += (id, c) => Events.Enqueue($"{id}:{(c is SetPtt p ? $"ptt {p.On}" : c.GetType().Name)}");
            hub.TxAudioReceived += (id, pcm) => Events.Enqueue($"{id}:audio {pcm.Length} {pcm[0]}");
            hub.PttHolderDisconnected += id => Events.Enqueue($"{id}:holder gone");
        }

        public async Task WaitForAsync(int count)
        {
            var deadline = DateTime.UtcNow + Timeout;
            while (Events.Count < count && DateTime.UtcNow < deadline)
            {
                await Task.Delay(10);
            }
            Assert.True(Events.Count >= count, $"{Events.Count} of {count}: {string.Join(", ", Events)}");
        }
    }

    [Fact]
    public async Task HolderRulesThroughTheRealServer()
    {
        await using var hub = await StartHubAsync();
        var recorder = new Recorder(hub);
        using var a = await ConnectAsync(hub);
        using var b = await ConnectAsync(hub);
        var (idA, idB) = await ClientIdsAsync(hub);

        await SendJsonAsync(a, """{"cmd":"ptt","value":true}""");
        await recorder.WaitForAsync(1);
        Assert.Equal(idA, hub.PttHolder);

        // Another client's release goes through (it unkeys the rig) but
        // doesn't clear A as the holder.
        await SendJsonAsync(b, """{"cmd":"ptt","value":false}""");
        await recorder.WaitForAsync(2);
        Assert.Equal(idA, hub.PttHolder);

        // The holder disconnecting raises the unkey and clears it.
        await a.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
        await recorder.WaitForAsync(3);
        Assert.Null(hub.PttHolder);
        Assert.Equal([$"{idA}:ptt True", $"{idB}:ptt False", $"{idA}:holder gone"], recorder.Events);

        // A non-holder disconnecting raises nothing.
        await SendJsonAsync(b, """{"cmd":"ptt","value":true}""");
        await recorder.WaitForAsync(4);
        await SendJsonAsync(b, """{"cmd":"ptt","value":false}""");
        await recorder.WaitForAsync(5);
        Assert.Null(hub.PttHolder);
        await b.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
        await WaitUntilAsync(() => hub.Clients.Count == 0);
        Assert.Equal(5, recorder.Events.Count);
    }

    [Fact]
    public async Task FramesFromANonHolderAreDropped()
    {
        await using var hub = await StartHubAsync();
        var recorder = new Recorder(hub);
        using var a = await ConnectAsync(hub);
        using var b = await ConnectAsync(hub);
        var (idA, idB) = await ClientIdsAsync(hub);

        // Nobody holds PTT yet.
        await SendFrameAsync(a, 1);
        await SendJsonAsync(a, """{"cmd":"ptt","value":true}""");
        await SendFrameAsync(b, 2);
        await SendFrameAsync(a, 3);
        // A marker from B, so everything B sent before it has been handled.
        await SendJsonAsync(b, """{"cmd":"set_att","value":true}""");
        await recorder.WaitForAsync(3);
        await Task.Delay(100);
        Assert.Contains($"{idA}:audio 320 3", recorder.Events);
        Assert.DoesNotContain(recorder.Events, e => e.Contains(":audio 320 1") || e.Contains(":audio 320 2"));
        Assert.Contains(AppLog.Lines, l => l.Contains($"client {idB}: TX audio dropped (not the PTT holder)"));
    }

    [Fact]
    public async Task PttAndFramesKeepTheirOrder()
    {
        await using var hub = await StartHubAsync();
        var recorder = new Recorder(hub);
        using var a = await ConnectAsync(hub);
        var (id, _) = await ClientIdsAsync(hub, expected: 1);

        await SendJsonAsync(a, """{"cmd":"ptt","value":true}""");
        for (byte i = 1; i <= 20; i++)
        {
            await SendFrameAsync(a, i);
        }
        await SendJsonAsync(a, """{"cmd":"ptt","value":false}""");
        // After its own release A isn't the holder: these are dropped.
        await SendFrameAsync(a, 99);
        await SendJsonAsync(a, """{"cmd":"set_att","value":true}""");
        await recorder.WaitForAsync(23);
        await Task.Delay(100);

        var expected = new List<string> { $"{id}:ptt True" };
        expected.AddRange(Enumerable.Range(1, 20).Select(i => $"{id}:audio 320 {i}"));
        expected.Add($"{id}:ptt False");
        expected.Add($"{id}:SetAtt");
        Assert.Equal(expected, recorder.Events);
        Assert.Null(hub.PttHolder);
    }

    // RemoteTxAudioClient against a local listener

    private sealed class FakePi : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);

        public FakePi() => _listener.Start();

        public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

        /// Accepts one connection and reads it to EOF.
        public async Task<byte[]> ReceiveOneAsync()
        {
            using var cts = new CancellationTokenSource(Timeout);
            using var client = await _listener.AcceptTcpClientAsync(cts.Token);
            var received = new MemoryStream();
            await client.GetStream().CopyToAsync(received, cts.Token);
            return received.ToArray();
        }

        public bool HasPendingConnection => _listener.Pending();

        public void Dispose() => _listener.Stop();
    }

    private static byte[] Chunk(byte value, int length = 320) => Enumerable.Repeat(value, length).ToArray();

    [Fact]
    public async Task RemoteSinkFlushesPendingAudioOnConnectThenFinishCloses()
    {
        using var pi = new FakePi();
        var connect = new TaskCompletionSource();
        var client = new RemoteTxAudioClient("127.0.0.1", pi.Port) { BeforeConnectForTests = () => connect.Task };
        var receiving = pi.ReceiveOneAsync();
        client.Start();
        // While connecting: held.
        client.Send(Chunk(1));
        client.Send(Chunk(2));
        connect.SetResult();
        await WaitUntilAsync(() => AppLog.Lines.Any(l => l.Contains($"connected to 127.0.0.1:{pi.Port}")));
        client.Send(Chunk(3));
        client.Finish();
        var received = await receiving;
        await client.Completion.WaitAsync(Timeout);
        Assert.Equal(Chunk(1).Concat(Chunk(2)).Concat(Chunk(3)).ToArray(), received);
        // Nothing after finish.
        client.Send(Chunk(4));
    }

    [Fact]
    public async Task RemoteSinkHoldsOnlyTheNewestHalfSecondWhileConnecting()
    {
        using var pi = new FakePi();
        var connect = new TaskCompletionSource();
        var client = new RemoteTxAudioClient("127.0.0.1", pi.Port) { BeforeConnectForTests = () => connect.Task };
        var receiving = pi.ReceiveOneAsync();
        client.Start();
        var sent = new List<byte>();
        for (byte i = 0; i < 40; i++)
        {
            var chunk = Chunk(i);
            sent.AddRange(chunk);
            client.Send(chunk);
        }
        connect.SetResult();
        await WaitUntilAsync(() => AppLog.Lines.Any(l => l.Contains($"connected to 127.0.0.1:{pi.Port}")));
        client.Finish();
        var received = await receiving;
        Assert.Equal(RemoteTxAudioClient.MaxPendingBytes, received.Length);
        Assert.Equal(sent.Skip(sent.Count - RemoteTxAudioClient.MaxPendingBytes).ToArray(), received);
    }

    [Fact]
    public async Task RemoteSinkIsOneConnectionPerTransmission()
    {
        using var pi = new FakePi();
        for (byte transmission = 1; transmission <= 2; transmission++)
        {
            var receiving = pi.ReceiveOneAsync();
            var client = new RemoteTxAudioClient("127.0.0.1", pi.Port);
            client.Start();
            client.Send(Chunk(transmission));
            client.Send(Chunk((byte)(transmission + 10)));
            await WaitUntilAsync(() => AppLog.Lines.Count(l => l.Contains($"connected to 127.0.0.1:{pi.Port}")) >= transmission);
            client.Finish();
            Assert.Equal(Chunk(transmission).Concat(Chunk((byte)(transmission + 10))).ToArray(), await receiving);
            await client.Completion.WaitAsync(Timeout);
        }
        Assert.False(pi.HasPendingConnection);
    }

    [Fact]
    public async Task RemoteSinkFinishedBeforeConnectingDropsTheAudio()
    {
        using var pi = new FakePi();
        var connect = new TaskCompletionSource();
        var client = new RemoteTxAudioClient("127.0.0.1", pi.Port) { BeforeConnectForTests = () => connect.Task };
        client.Start();
        client.Send(Chunk(1));
        client.Finish();
        connect.SetResult();
        await client.Completion.WaitAsync(Timeout);
        await Task.Delay(100);
        Assert.False(pi.HasPendingConnection);
    }

    // Helpers

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

    /// The ids of the connected clients, in connect order.
    private static async Task<(int First, int Second)> ClientIdsAsync(HubServer hub, int expected = 2)
    {
        await WaitUntilAsync(() => hub.Clients.Count == expected);
        var ids = hub.Clients.Select(c => c.Id).ToList();
        return (ids[0], expected > 1 ? ids[1] : 0);
    }

    /// As the iPad sends its JSON: a binary frame.
    private static Task SendJsonAsync(ClientWebSocket socket, string json) =>
        socket.SendAsync(Encoding.UTF8.GetBytes(json), WebSocketMessageType.Binary, true, CancellationToken.None);

    /// A 0x02 TX audio frame of 160 samples, every byte <paramref name="marker"/>.
    private static Task SendFrameAsync(ClientWebSocket socket, byte marker)
    {
        var frame = new byte[321];
        frame[0] = 0x02;
        Array.Fill(frame, marker, 1, 320);
        return socket.SendAsync(frame, WebSocketMessageType.Binary, true, CancellationToken.None);
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + Timeout;
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "timed out");
            await Task.Delay(10);
        }
    }
}

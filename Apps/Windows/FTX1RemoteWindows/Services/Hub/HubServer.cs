using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Threading.Channels;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace FTX1RemoteWindows.Services.Hub;

/// The Mac hub's WebSocket server (RigWebSocketServer.swift), so the iPad's
/// "Desktop hub" route can connect to this app — Apps/Windows/README.md,
/// "Desktop hub for the iPad". State pushes go out (phase 1); a client's
/// commands are parsed (RigCommandWire) and raised as
/// <see cref="CommandReceived"/> for RigCommandDispatcher (phase 2); MAIN/SUB
/// receive audio frames go out through <see cref="BroadcastAudio"/>
/// (phase 3). TX audio frames (phase 5), read_menu_item (phase 4) and
/// cw_keyer (phase 6) are logged and ignored.
///
/// Plain ws:// on every interface, path "/", port <see cref="Port"/> (the
/// iPad's RigClientViewModel has it fixed). Connections from outside
/// loopback, Tailscale and the private ranges are refused before the
/// upgrade (<see cref="HubAddressFilter"/>). Runs independently of the
/// rigctld connection: MainWindow starts/stops it with Settings → Hub and
/// just keeps handing it the latest state.
///
/// Thread-safe: <see cref="Publish"/> and <see cref="BroadcastAudio"/> may
/// be called from any thread, and
/// <see cref="StatusChanged"/> and <see cref="CommandReceived"/> are raised
/// on a pool thread.
public sealed class HubServer : IAsyncDisposable
{
    public const int Port = 8765;

    public sealed record ClientInfo(int Id, string Address, DateTime ConnectedAt);

    /// ~0.5 s of receive audio per client: MAIN and SUB each send a frame
    /// per 2048-sample chunk (~46 ms at 44.1 kHz, ~43 ms at 48 kHz).
    private const int AudioQueueFrames = 24;
    private static readonly TimeSpan AudioDropLogInterval = TimeSpan.FromSeconds(5);

    private sealed class Client
    {
        public Client()
        {
            AudioOutbox = Channel.CreateBounded<byte[]>(
                new BoundedChannelOptions(AudioQueueFrames)
                {
                    FullMode = BoundedChannelFullMode.DropOldest,
                    SingleReader = true,
                },
                _ => AudioDropped());
        }

        public required ClientInfo Info { get; init; }
        public required WebSocket Socket { get; init; }
        /// Only the newest state matters, so a slow client skips the ones
        /// it couldn't send in time rather than queuing them.
        public Channel<string> Outbox { get; } = Channel.CreateBounded<string>(
            new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
        /// A WebSocket takes one send at a time, and a close counts as a
        /// send: CloseOutputAsync while SendAsync runs throws. Every
        /// send-side call holds this — the send loop's pushes, the close
        /// handshake's reply, StopAsync's close.
        public SemaphoreSlim SendLock { get; } = new(1, 1);

        /// Receive audio frames, separate from <see cref="Outbox"/> (which
        /// keeps only the newest push and would drop audio). A client that
        /// falls behind loses its oldest frames, so the delay can't grow
        /// past ~0.5 s.
        public Channel<byte[]> AudioOutbox { get; }

        private int _droppedFrames;
        private long _lastDropLog;

        private void AudioDropped()
        {
            var dropped = Interlocked.Increment(ref _droppedFrames);
            var now = Environment.TickCount64;
            if (now - Interlocked.Read(ref _lastDropLog) < AudioDropLogInterval.TotalMilliseconds)
            {
                return;
            }
            Interlocked.Exchange(ref _lastDropLog, now);
            Interlocked.Exchange(ref _droppedFrames, 0);
            AppLog.Write($"hub: client {Info.Id} is behind on audio — dropped {dropped} oldest frame(s)");
        }
    }

    private readonly object _gate = new();
    private readonly Dictionary<int, Client> _clients = [];
    /// <see cref="_clients"/> for the audio path, replaced under the gate on
    /// every connect/disconnect so a broadcast needn't take the lock.
    private volatile Client[] _audioClients = [];
    private int _nextClientId;
    private WebApplication? _app;
    private string? _latestState;

    /// Listening on <see cref="Port"/>.
    public bool IsListening { get; private set; }
    /// Why the last start failed (e.g. the port is taken); null otherwise.
    public string? LastError { get; private set; }

    /// Raised when listening starts/stops or a client connects/disconnects.
    public event Action? StatusChanged;

    /// A client's command, with the client's id, in the order that client
    /// sent them.
    public event Action<int, RigCommand>? CommandReceived;

    public IReadOnlyList<ClientInfo> Clients
    {
        get
        {
            lock (_gate)
            {
                return _clients.Values.Select(c => c.Info).OrderBy(c => c.Id).ToList();
            }
        }
    }

    public async Task StartAsync()
    {
        if (_app is not null)
        {
            return;
        }
        LastError = null;
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
        {
            ContentRootPath = AppContext.BaseDirectory,
        });
        builder.Logging.ClearProviders();
        // IPv6Any in dual mode: IPv4 clients arrive as ::ffff:a.b.c.d.
        builder.WebHost.ConfigureKestrel(o => o.ListenAnyIP(Port));
        var app = builder.Build();
        app.Use(async (context, next) =>
        {
            var remote = context.Connection.RemoteIpAddress;
            if (!HubAddressFilter.IsAllowed(remote))
            {
                AppLog.Write($"hub: refused {remote} (not loopback, Tailscale or a local network)");
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            await next(context);
        });
        // The iPad pings as its heartbeat; the stack answers with pongs on
        // its own while a receive is pending (every client always has one).
        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(20) });
        app.Run(async context =>
        {
            if (context.Request.Path != "/" || !context.WebSockets.IsWebSocketRequest)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }
            var socket = await context.WebSockets.AcceptWebSocketAsync();
            await RunClientAsync(socket, context.Connection.RemoteIpAddress, context.RequestAborted);
        });

        try
        {
            await app.StartAsync();
        }
        catch (Exception ex)
        {
            LastError = ex is IOException { InnerException: { } inner } ? inner.Message : ex.Message;
            AppLog.Write($"hub: couldn't listen on port {Port}: {ex.Message}");
            await app.DisposeAsync();
            StatusChanged?.Invoke();
            return;
        }
        _app = app;
        IsListening = true;
        AppLog.Write($"hub: listening on port {Port}");
        StatusChanged?.Invoke();
    }

    public async Task StopAsync()
    {
        if (_app is not { } app)
        {
            return;
        }
        _app = null;
        IsListening = false;
        List<Client> clients;
        lock (_gate)
        {
            clients = [.. _clients.Values];
        }
        foreach (var client in clients)
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                await CloseOutputAsync(client, WebSocketCloseStatus.EndpointUnavailable, "Hub turned off", timeout.Token);
            }
            catch
            {
                // Already gone, or a send stuck past the timeout; StopAsync
                // below aborts what's left.
            }
        }
        try
        {
            await app.StopAsync(new CancellationTokenSource(TimeSpan.FromSeconds(3)).Token);
        }
        catch (Exception ex)
        {
            AppLog.Write($"hub: stop: {ex.Message}");
        }
        await app.DisposeAsync();
        AppLog.Write("hub: stopped");
        StatusChanged?.Invoke();
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    /// Whether any client is connected — the audio taps skip encoding when
    /// not.
    public bool HasClients => _audioClients.Length > 0;

    /// One receive audio frame (AudioStreamFormat: tag 0x00 MAIN / 0x01
    /// SUB, then 8 kHz Int16LE PCM) to every connected client, as the Mac's
    /// broadcastAudio/broadcastSubAudio.
    public void BroadcastAudio(byte[] frame)
    {
        foreach (var client in _audioClients)
        {
            client.AudioOutbox.Writer.TryWrite(frame);
        }
    }

    /// The current state push as JSON. Sent to every client now and to each
    /// new client on connect.
    public void Publish(string stateJson)
    {
        List<Client> clients;
        lock (_gate)
        {
            _latestState = stateJson;
            clients = [.. _clients.Values];
        }
        foreach (var client in clients)
        {
            client.Outbox.Writer.TryWrite(stateJson);
        }
    }

    private async Task RunClientAsync(WebSocket socket, IPAddress? remote, CancellationToken aborted)
    {
        var address = remote is { IsIPv4MappedToIPv6: true } ? remote.MapToIPv4() : remote;
        var client = new Client
        {
            Info = new ClientInfo(Interlocked.Increment(ref _nextClientId), address?.ToString() ?? "?", DateTime.Now),
            Socket = socket,
        };
        lock (_gate)
        {
            _clients[client.Info.Id] = client;
            _audioClients = [.. _clients.Values];
            if (_latestState is { } state)
            {
                client.Outbox.Writer.TryWrite(state);
            }
        }
        AppLog.Write($"hub: client {client.Info.Id} connected from {client.Info.Address}");
        StatusChanged?.Invoke();

        using var done = CancellationTokenSource.CreateLinkedTokenSource(aborted);
        var sender = SendLoopAsync(client, done.Token);
        var audioSender = AudioSendLoopAsync(client, done.Token);
        try
        {
            await ReceiveLoopAsync(client, done.Token);
        }
        catch (Exception ex) when (ex is WebSocketException or OperationCanceledException)
        {
            // Dropped connection.
        }
        finally
        {
            done.Cancel();
            client.Outbox.Writer.TryComplete();
            client.AudioOutbox.Writer.TryComplete();
            try
            {
                await Task.WhenAll(sender, audioSender);
            }
            catch
            {
                // A send loop's own failure is the disconnect.
            }
            lock (_gate)
            {
                _clients.Remove(client.Info.Id);
                _audioClients = [.. _clients.Values];
            }
            AppLog.Write($"hub: client {client.Info.Id} ({client.Info.Address}) disconnected");
            StatusChanged?.Invoke();
        }
    }

    private async Task ReceiveLoopAsync(Client client, CancellationToken cancellationToken)
    {
        var buffer = new byte[16 * 1024];
        var message = new MemoryStream();
        while (client.Socket.State == WebSocketState.Open)
        {
            var result = await client.Socket.ReceiveAsync(buffer, cancellationToken);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                // Bounded, so a push stuck on a dead connection can't hold
                // the disconnect up.
                using var closeTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                closeTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                await CloseOutputAsync(client, WebSocketCloseStatus.NormalClosure, null, closeTimeout.Token);
                return;
            }
            message.Write(buffer, 0, result.Count);
            if (!result.EndOfMessage)
            {
                continue;
            }
            // The iPad sends its JSON (commands, menu reads, keyer requests)
            // as *binary* frames (URLSessionWebSocketTask .data); only a
            // 0x02-tagged binary frame is TX audio — the Mac's
            // RigWebSocketServer tells them apart the same way.
            var frame = new ArraySegment<byte>(message.GetBuffer(), 0, (int)message.Length);
            if (result.MessageType == WebSocketMessageType.Binary && RigCommandWire.IsTxAudioFrame(frame))
            {
                // TX audio arrives in phase 5.
                AppLog.Write($"hub: client {client.Info.Id} sent a {message.Length}-byte TX audio frame (ignored until phase 5)");
            }
            else
            {
                HandleText(client, Encoding.UTF8.GetString(frame));
            }
            message.SetLength(0);
        }
    }

    /// One text frame from a client. Never throws: a bad frame is logged
    /// and the connection carries on, as with the Mac's server.
    private void HandleText(Client client, string text)
    {
        var id = client.Info.Id;
        try
        {
            var inbound = RigCommandWire.ParseInbound(text);
            switch (inbound.Kind)
            {
                case InboundKind.Command:
                    CommandReceived?.Invoke(id, inbound.Command!);
                    break;
                case InboundKind.MenuItemRead:
                    AppLog.Write($"hub: client {id}: read_menu_item ignored (Deep Settings reads arrive in phase 4)");
                    break;
                case InboundKind.CwKeyer:
                    AppLog.Write($"hub: client {id}: cw_keyer ignored (the CW keyer arrives in phase 6)");
                    break;
                default:
                    AppLog.Write($"hub: client {id}: ignored ({inbound.Error}): {Truncated(text)}");
                    break;
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"hub: client {id}: handling a frame failed ({ex.Message}): {Truncated(text)}");
        }
    }

    private static string Truncated(string text) => text.Length > 200 ? text[..200] + "…" : text;

    private static async Task SendLoopAsync(Client client, CancellationToken cancellationToken)
    {
        await foreach (var json in client.Outbox.Reader.ReadAllAsync(cancellationToken))
        {
            await client.SendLock.WaitAsync(cancellationToken);
            try
            {
                if (client.Socket.State != WebSocketState.Open)
                {
                    return;
                }
                await client.Socket.SendAsync(Encoding.UTF8.GetBytes(json), WebSocketMessageType.Text, true, cancellationToken);
            }
            finally
            {
                client.SendLock.Release();
            }
        }
    }

    private static async Task AudioSendLoopAsync(Client client, CancellationToken cancellationToken)
    {
        await foreach (var frame in client.AudioOutbox.Reader.ReadAllAsync(cancellationToken))
        {
            await client.SendLock.WaitAsync(cancellationToken);
            try
            {
                if (client.Socket.State != WebSocketState.Open)
                {
                    return;
                }
                await client.Socket.SendAsync(frame, WebSocketMessageType.Binary, true, cancellationToken);
            }
            finally
            {
                client.SendLock.Release();
            }
        }
    }

    /// Our half of the close handshake, under the send lock so it can't
    /// overlap a push. Skipped once our side has closed already (the
    /// receive loop's reply and StopAsync can both get here).
    private static async Task CloseOutputAsync(Client client, WebSocketCloseStatus status, string? description,
        CancellationToken cancellationToken)
    {
        await client.SendLock.WaitAsync(cancellationToken);
        try
        {
            if (client.Socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
            {
                await client.Socket.CloseOutputAsync(status, description, cancellationToken);
            }
        }
        finally
        {
            client.SendLock.Release();
        }
    }
}

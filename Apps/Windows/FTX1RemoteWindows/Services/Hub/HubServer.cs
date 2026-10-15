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
/// <see cref="CommandReceived"/> for RigCommandDispatcher (phase 2). Binary
/// frames (TX audio, phase 5), read_menu_item (phase 4) and cw_keyer
/// (phase 6) are logged and ignored.
///
/// Plain ws:// on every interface, path "/", port <see cref="Port"/> (the
/// iPad's RigClientViewModel has it fixed). Connections from outside
/// loopback, Tailscale and the private ranges are refused before the
/// upgrade (<see cref="HubAddressFilter"/>). Runs independently of the
/// rigctld connection: MainWindow starts/stops it with Settings → Hub and
/// just keeps handing it the latest state.
///
/// Thread-safe: <see cref="Publish"/> may be called from any thread, and
/// <see cref="StatusChanged"/> and <see cref="CommandReceived"/> are raised
/// on a pool thread.
public sealed class HubServer : IAsyncDisposable
{
    public const int Port = 8765;

    public sealed record ClientInfo(int Id, string Address, DateTime ConnectedAt);

    private sealed class Client
    {
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
    }

    private readonly object _gate = new();
    private readonly Dictionary<int, Client> _clients = [];
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
            if (_latestState is { } state)
            {
                client.Outbox.Writer.TryWrite(state);
            }
        }
        AppLog.Write($"hub: client {client.Info.Id} connected from {client.Info.Address}");
        StatusChanged?.Invoke();

        using var done = CancellationTokenSource.CreateLinkedTokenSource(aborted);
        var sender = SendLoopAsync(client, done.Token);
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
            try
            {
                await sender;
            }
            catch
            {
                // The send loop's own failure is the disconnect.
            }
            lock (_gate)
            {
                _clients.Remove(client.Info.Id);
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
            if (result.MessageType == WebSocketMessageType.Text)
            {
                HandleText(client, Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length));
            }
            else
            {
                // TX audio (0x02) arrives in phase 5.
                AppLog.Write($"hub: client {client.Info.Id} sent a {message.Length}-byte binary frame (ignored until phase 5)");
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

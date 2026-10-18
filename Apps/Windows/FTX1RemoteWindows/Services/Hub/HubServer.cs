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
/// (phase 3); the memory list and APRS history go out through
/// <see cref="PublishMemoryList"/>/<see cref="PublishAprsList"/>, and a
/// client's read_menu_item is answered to that client alone through
/// <see cref="MenuItemReader"/> (phase 4); the PTT holder is tracked and
/// its TX audio frames raised as <see cref="TxAudioReceived"/>, in the same
/// order as its commands (phase 5); a client's cw_keyer request is
/// answered to that client alone through <see cref="CwKeyerHandler"/>, and
/// the client that last played the keyer is tracked so its disconnect can
/// stop it (<see cref="KeyerPlayerDisconnected"/>, phase 6).
///
/// Plain ws:// on every interface, path "/", port <see cref="Port"/> (the
/// iPad's RigClientViewModel has it fixed). Connections from outside
/// loopback, Tailscale and the private ranges are refused before the
/// upgrade (<see cref="HubAddressFilter"/>). Runs independently of the
/// rigctld connection: MainWindow starts/stops it with Settings → Hub and
/// just keeps handing it the latest state.
///
/// Thread-safe: <see cref="Publish"/>, the list publishes and
/// <see cref="BroadcastAudio"/> may be called from any thread, and
/// <see cref="StatusChanged"/>, <see cref="CommandReceived"/>,
/// <see cref="TxAudioReceived"/> and <see cref="PttHolderDisconnected"/> are
/// raised on a pool thread. Each client's commands and TX frames are raised
/// one at a time from its receive loop, in arrival order, so a handler that
/// queues them (RigCommandDispatcher's one FIFO) keeps a ptt=true ahead of
/// that client's first frame.
public sealed class HubServer : IAsyncDisposable
{
    public const int Port = 8765;

    public sealed record ClientInfo(int Id, string Address, DateTime ConnectedAt);

    /// ~0.5 s of receive audio per client: MAIN and SUB each send a frame
    /// per 2048-sample chunk (~46 ms at 44.1 kHz, ~43 ms at 48 kHz).
    private const int AudioQueueFrames = 24;
    private static readonly TimeSpan AudioDropLogInterval = TimeSpan.FromSeconds(5);
    /// Menu replies waiting to go out to one client. Deep Settings reads a
    /// tab's items at once (a few dozen), each answered once; past this a
    /// reply is dropped (logged) and the iPad's read times out.
    private const int ReplyQueueLimit = 256;

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
        public Channel<string> Outbox { get; } = NewestOnly();
        /// The memory list and APRS history pushes: each kind its own
        /// newest-wins slot, so neither a state push nor the other list can
        /// replace one before it's sent.
        public Channel<string> MemoryListOutbox { get; } = NewestOnly();
        public Channel<string> AprsListOutbox { get; } = NewestOnly();
        /// Answers to this client's own requests (menu_item, cw_keyer_reply), in order, none
        /// replaced by a later one.
        public Channel<string> ReplyOutbox { get; } = Channel.CreateBounded<string>(
            new BoundedChannelOptions(ReplyQueueLimit) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });

        private static Channel<string> NewestOnly() => Channel.CreateBounded<string>(
            new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });

        public IEnumerable<Channel<string>> TextOutboxes => [Outbox, MemoryListOutbox, AprsListOutbox, ReplyOutbox];
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
        private long? _lastTxDropLog;

        /// TX audio from a client that isn't the PTT holder, logged at most
        /// every 5 s. Receive loop only.
        public void LogTxDropped()
        {
            var now = Environment.TickCount64;
            if (_lastTxDropLog is { } last && now - last < AudioDropLogInterval.TotalMilliseconds)
            {
                return;
            }
            _lastTxDropLog = now;
            AppLog.Write($"hub: client {Info.Id}: TX audio dropped (not the PTT holder)");
        }

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
    private string? _latestMemoryList;
    private string? _latestAprsList;
    private readonly int _port;
    private readonly bool _loopbackOnly;
    /// The client whose ptt=true came last, the Mac's pttHolder: only its
    /// TX frames are passed on, only its own ptt=false clears it, and its
    /// disconnect raises <see cref="PttHolderDisconnected"/> (the unkey). Set
    /// on the press whether or not the gate then lets it key, as on the Mac.
    /// Under <see cref="_gate"/>.
    private int? _pttHolder;
    /// The client whose play_cw_text_memory 1-5 came last, the Mac's
    /// keyerPlayer: its own play 0 clears it, and its disconnect raises
    /// <see cref="KeyerPlayerDisconnected"/> (the "KY00"). Set whether or not
    /// the play then passes the gate, as on the Mac. Under <see cref="_gate"/>.
    private int? _keyerPlayer;

    /// <paramref name="port"/>/<paramref name="loopbackOnly"/> are for the
    /// tests; the app always uses <see cref="Port"/> on every interface.
    public HubServer(int port = Port, bool loopbackOnly = false)
    {
        _port = port;
        _loopbackOnly = loopbackOnly;
    }

    /// Reads one Deep Settings item (P1, P2, P3) for a client's
    /// read_menu_item: the raw value, or null when it can't be read. Called
    /// off the command FIFO, on a pool thread; may throw (answered as
    /// unreadable).
    public Func<int, int, int, Task<string?>>? MenuItemReader { get; set; }

    /// Writes CW TEXT keyer memory <c>slot</c> with <c>text</c> and returns
    /// what the rig stored, or (text null) makes the slot a TEXT memory and
    /// returns null — for a client's cw_keyer, already checked by
    /// <see cref="HubKeyerPolicy.RequestRefusal"/>. Called off the command
    /// FIFO, on a pool thread; throws with a readable message on failure
    /// (sent back as the reply's error). Null = no rig to write to.
    public Func<int, string?, Task<string?>>? CwKeyerHandler { get; set; }

    /// The port it listens on: <see cref="Port"/> except in the tests.
    public int ListenPort => _port;

    /// Listening on <see cref="ListenPort"/>.
    public bool IsListening { get; private set; }
    /// Why the last start failed (e.g. the port is taken); null otherwise.
    public string? LastError { get; private set; }

    /// Raised when listening starts/stops or a client connects/disconnects.
    public event Action? StatusChanged;

    /// A client's command, with the client's id, in the order that client
    /// sent them.
    public event Action<int, RigCommand>? CommandReceived;

    /// A TX audio frame's payload (8 kHz mono Int16LE, the 0x02 tag
    /// stripped) from the PTT holder, in order with its commands. Frames
    /// from anyone else are dropped here.
    public event Action<int, byte[]>? TxAudioReceived;

    /// The PTT holder disconnected: the rig must be unkeyed (the Mac's
    /// remove() sends .setPTT(false)). Raised after its last command/frame.
    public event Action<int>? PttHolderDisconnected;

    /// The client that last played the keyer disconnected without stopping
    /// it: send "KY00" (the Mac's remove()). Raised after its last command.
    public event Action<int>? KeyerPlayerDisconnected;

    /// The client that last played the keyer, or null.
    public int? KeyerPlayer
    {
        get
        {
            lock (_gate)
            {
                return _keyerPlayer;
            }
        }
    }

    /// The current PTT holder's client id, or null.
    public int? PttHolder
    {
        get
        {
            lock (_gate)
            {
                return _pttHolder;
            }
        }
    }

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
        builder.WebHost.ConfigureKestrel(o =>
        {
            if (_loopbackOnly)
            {
                o.ListenLocalhost(_port);
            }
            else
            {
                o.ListenAnyIP(_port);
            }
        });
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
            AppLog.Write($"hub: couldn't listen on port {_port}: {ex.Message}");
            await app.DisposeAsync();
            StatusChanged?.Invoke();
            return;
        }
        _app = app;
        IsListening = true;
        AppLog.Write($"hub: listening on port {_port}");
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

    /// The memory list push (MemoryListPushWire) to every client now and to
    /// each new client on connect. The caller throttles (1 s).
    public void PublishMemoryList(string json) => PublishList(json, isMemory: true);

    /// The APRS history push (AprsListPushWire), likewise. The caller
    /// throttles (2 s).
    public void PublishAprsList(string json) => PublishList(json, isMemory: false);

    private void PublishList(string json, bool isMemory)
    {
        List<Client> clients;
        lock (_gate)
        {
            if (isMemory)
            {
                _latestMemoryList = json;
            }
            else
            {
                _latestAprsList = json;
            }
            clients = [.. _clients.Values];
        }
        foreach (var client in clients)
        {
            (isMemory ? client.MemoryListOutbox : client.AprsListOutbox).Writer.TryWrite(json);
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
            if (_latestMemoryList is { } memoryList)
            {
                client.MemoryListOutbox.Writer.TryWrite(memoryList);
            }
            if (_latestAprsList is { } aprsList)
            {
                client.AprsListOutbox.Writer.TryWrite(aprsList);
            }
        }
        AppLog.Write($"hub: client {client.Info.Id} connected from {client.Info.Address}");
        StatusChanged?.Invoke();

        using var done = CancellationTokenSource.CreateLinkedTokenSource(aborted);
        var senders = client.TextOutboxes.Select(outbox => SendLoopAsync(client, outbox, done.Token))
            .Append(AudioSendLoopAsync(client, done.Token)).ToList();
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
            foreach (var outbox in client.TextOutboxes)
            {
                outbox.Writer.TryComplete();
            }
            client.AudioOutbox.Writer.TryComplete();
            try
            {
                await Task.WhenAll(senders);
            }
            catch
            {
                // A send loop's own failure is the disconnect.
            }
            bool wasHolder;
            bool wasKeyerPlayer;
            lock (_gate)
            {
                _clients.Remove(client.Info.Id);
                _audioClients = [.. _clients.Values];
                wasHolder = _pttHolder == client.Info.Id;
                if (wasHolder)
                {
                    _pttHolder = null;
                }
                wasKeyerPlayer = _keyerPlayer == client.Info.Id;
                if (wasKeyerPlayer)
                {
                    _keyerPlayer = null;
                }
            }
            AppLog.Write($"hub: client {client.Info.Id} ({client.Info.Address}) disconnected");
            if (wasHolder)
            {
                AppLog.Write($"hub: client {client.Info.Id} held PTT — unkeying");
                PttHolderDisconnected?.Invoke(client.Info.Id);
            }
            if (wasKeyerPlayer)
            {
                AppLog.Write($"hub: client {client.Info.Id} played the keyer last — stopping it");
                KeyerPlayerDisconnected?.Invoke(client.Info.Id);
            }
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
                HandleTxAudio(client, frame);
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
                    if (inbound.Command is SetPtt ptt)
                    {
                        // The Mac's rule: a press makes this client the
                        // holder; only the holder's own release clears it
                        // (another client's release still unkeys the rig,
                        // but doesn't take over the holder).
                        lock (_gate)
                        {
                            _pttHolder = ptt.On ? id : (_pttHolder == id ? null : _pttHolder);
                        }
                    }
                    else if (inbound.Command is PlayCwTextMemory play)
                    {
                        // The Mac's keyerPlayer rule, as for the PTT holder.
                        lock (_gate)
                        {
                            _keyerPlayer = play.Value != 0 ? id : (_keyerPlayer == id ? null : _keyerPlayer);
                        }
                    }
                    CommandReceived?.Invoke(id, inbound.Command!);
                    break;
                case InboundKind.MenuItemRead:
                    // Off the receive loop and the command FIFO, as on the
                    // Mac: a read is a rigctld round trip, and commands
                    // behind it shouldn't wait (RigctldClient's own lock
                    // still orders the I/O).
                    _ = AnswerMenuItemReadAsync(client, inbound.MenuRead!);
                    break;
                case InboundKind.CwKeyer:
                    // Off the receive loop and the command FIFO, like a menu
                    // read: a keyer write takes ~2 s over the Pi. The iPad
                    // waits for the reply before it plays, so order holds.
                    _ = AnswerCwKeyerAsync(client, inbound.CwKeyer!);
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

    /// A 0x02 frame: passed on only from the PTT holder (the Mac's
    /// RigWebSocketServer.handle), from this client's receive loop so it
    /// stays behind the client's earlier commands.
    private void HandleTxAudio(Client client, ArraySegment<byte> frame)
    {
        bool isHolder;
        lock (_gate)
        {
            isHolder = _pttHolder == client.Info.Id;
        }
        if (!isHolder)
        {
            client.LogTxDropped();
            return;
        }
        TxAudioReceived?.Invoke(client.Info.Id, frame.AsSpan(1).ToArray());
    }

    /// Reads the item and answers the asking client alone. Never throws:
    /// anything that goes wrong is an unreadable answer (no "value").
    private async Task AnswerMenuItemReadAsync(Client client, MenuItemReadRequestWire request)
    {
        string? value = null;
        if (!request.IsValidAddress)
        {
            AppLog.Write($"hub: client {client.Info.Id}: read_menu_item {request.P1}/{request.P2}/{request.P3} — out of range, answered unreadable");
        }
        else if (MenuItemReader is { } read)
        {
            try
            {
                value = await read(request.P1, request.P2, request.P3).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                AppLog.Write($"hub: client {client.Info.Id}: read EX{request.P1:00}{request.P2:00}{request.P3:00} failed: {ex.Message}");
            }
        }
        var reply = HubWire.Serialize(new MenuItemPushWire { P1 = request.P1, P2 = request.P2, P3 = request.P3, Value = value });
        if (!client.ReplyOutbox.Writer.TryWrite(reply) && !client.ReplyOutbox.Reader.Completion.IsCompleted)
        {
            AppLog.Write($"hub: client {client.Info.Id}: menu reply dropped (reply queue full)");
        }
    }

    /// Answers a client's cw_keyer to that client alone, with its id. Never
    /// throws. No keyer lease here (README, phase 6): acquire is always
    /// granted and release does nothing, so this PC's own CW window and an
    /// iPad aren't coordinated.
    private async Task AnswerCwKeyerAsync(Client client, CwKeyerRequestWire request)
    {
        var id = client.Info.Id;
        var reply = new CwKeyerReplyWire { Id = request.Id };
        switch (request.Action)
        {
            case CwKeyerRequestWire.AcquireAction:
                AppLog.Write($"hub: client {id}: keyer acquire — granted (no keyer lease on Windows)");
                break;
            case CwKeyerRequestWire.ReleaseAction:
                AppLog.Write($"hub: client {id}: keyer release (no keyer lease on Windows)");
                break;
            default:
                var what = request.Text is null ? $"TEXT check of keyer memory {request.Slot}" : $"keyer memory {request.Slot} write";
                if (HubKeyerPolicy.RequestRefusal(request.Slot, request.Text) is { } refusal)
                {
                    AppLog.Write($"hub: client {id}: {what} — refused: {refusal}");
                    reply.Error = refusal;
                }
                else if (CwKeyerHandler is not { } handler)
                {
                    AppLog.Write($"hub: client {id}: {what} — refused: not connected to the rig");
                    reply.Error = "Not connected to the rig";
                }
                else
                {
                    try
                    {
                        reply.Stored = await handler(request.Slot, request.Text).ConfigureAwait(false);
                        AppLog.Write(request.Text is null
                            ? $"hub: client {id}: {what} — done"
                            : $"hub: client {id}: {what} — stored \"{reply.Stored}\"");
                    }
                    catch (Exception ex)
                    {
                        AppLog.Write($"hub: client {id}: {what} failed: {ex.Message}");
                        reply.Stored = null;
                        reply.Error = string.IsNullOrWhiteSpace(ex.Message) ? "The keyer memory write failed" : ex.Message;
                    }
                }
                break;
        }
        if (!client.ReplyOutbox.Writer.TryWrite(HubWire.Serialize(reply)) && !client.ReplyOutbox.Reader.Completion.IsCompleted)
        {
            AppLog.Write($"hub: client {id}: keyer reply dropped (reply queue full)");
        }
    }

    private static string Truncated(string text) => text.Length > 200 ? text[..200] + "…" : text;

    private static async Task SendLoopAsync(Client client, Channel<string> outbox, CancellationToken cancellationToken)
    {
        await foreach (var json in outbox.Reader.ReadAllAsync(cancellationToken))
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

using System.Net.Sockets;
using System.Threading.Channels;
using FTX1RemoteWindows.Services.Hub;

namespace FTX1RemoteWindows.Services;

/// Sends transmit audio to the Pi's ftx1-txaudio.py (port 8533), which plays
/// it into the rig's USB audio input: raw 8 kHz mono Int16LE, no framing.
/// A port of FTX1Core's RemoteTXAudioClient.swift, used by the Desktop hub
/// in Remote mode for an iPad's PTT (Apps/Windows/README.md, "Desktop hub
/// for the iPad", phase 5).
///
/// One instance per transmission: <see cref="Start"/> on the first frame,
/// <see cref="Finish"/> on unkey, which closes the sending side once the
/// queue is out — the Pi then plays out its buffer, and its own 0.5 s
/// grace before unkeying applies. Audio sent before the connection is up is
/// held, up to <see cref="MaxPendingBytes"/> (the newest), so the first
/// syllable isn't lost to the connect; a transmission finished before it
/// connects is dropped, as on the Mac. Never keys anything.
///
/// <see cref="Send"/>/<see cref="Finish"/> may be called from any thread
/// and never block on the network: writes go out from one background task.
public sealed class RemoteTxAudioClient : ITxAudioSink
{
    public const int DefaultPort = 8533;
    /// Half a second of 8 kHz Int16 audio — more than a Tailscale connect.
    public const int MaxPendingBytes = 8000;
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(5);

    private readonly string _host;
    private readonly int _port;
    private readonly object _lock = new();
    private readonly Channel<byte[]> _writes = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _connectCancel = new();
    private MemoryStream? _pending = new();
    private bool _ready;
    private bool _finished;
    private long _bytesSent;
    private Task _run = Task.CompletedTask;

    public RemoteTxAudioClient(string host, int port = DefaultPort)
    {
        _host = host;
        _port = port;
    }

    /// Tests only: awaited before connecting, so frames sent meanwhile take
    /// the pending path.
    internal Func<Task>? BeforeConnectForTests { get; set; }

    /// Done once the connection is closed (or failed, or was dropped).
    public Task Completion => _run;

    public void Start() => _run = Task.Run(RunAsync);

    public void Send(byte[] pcm)
    {
        if (pcm.Length == 0)
        {
            return;
        }
        lock (_lock)
        {
            if (_finished)
            {
                return;
            }
            if (!_ready)
            {
                var pending = _pending!;
                pending.Write(pcm);
                if (pending.Length > MaxPendingBytes)
                {
                    // Keep the newest half second. Both lengths are even, so
                    // this stays on a sample boundary.
                    var keep = pending.GetBuffer().AsSpan((int)(pending.Length - MaxPendingBytes), MaxPendingBytes).ToArray();
                    pending.SetLength(0);
                    pending.Write(keep);
                }
                return;
            }
        }
        _writes.Writer.TryWrite(pcm);
    }

    public void Finish()
    {
        bool ready;
        lock (_lock)
        {
            if (_finished)
            {
                return;
            }
            _finished = true;
            ready = _ready;
        }
        _writes.Writer.TryComplete();
        if (!ready)
        {
            _connectCancel.Cancel();
        }
    }

    private async Task RunAsync()
    {
        using var tcp = new TcpClient { NoDelay = true };
        try
        {
            if (BeforeConnectForTests is { } beforeConnect)
            {
                await beforeConnect();
            }
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(_connectCancel.Token))
            {
                timeout.CancelAfter(ConnectTimeout);
                await tcp.ConnectAsync(_host, _port, timeout.Token);
            }
            byte[] pending;
            lock (_lock)
            {
                if (_finished)
                {
                    AppLog.Write($"tx-audio: finished before connecting to {_host}:{_port} — dropped {_pending?.Length ?? 0} bytes");
                    return;
                }
                _ready = true;
                pending = _pending!.ToArray();
                _pending = null;
            }
            AppLog.Write($"tx-audio: connected to {_host}:{_port}");
            var stream = tcp.GetStream();
            if (pending.Length > 0)
            {
                await stream.WriteAsync(pending);
                _bytesSent += pending.Length;
            }
            await foreach (var pcm in _writes.Reader.ReadAllAsync())
            {
                await stream.WriteAsync(pcm);
                _bytesSent += pcm.Length;
            }
            // FIN: the Pi plays out what it has, then closes.
            tcp.Client.Shutdown(SocketShutdown.Send);
            AppLog.Write($"tx-audio: finish — {_bytesSent} bytes sent");
        }
        catch (OperationCanceledException) when (_connectCancel.IsCancellationRequested)
        {
            AppLog.Write($"tx-audio: finished before connecting to {_host}:{_port} — dropped");
        }
        catch (Exception ex)
        {
            lock (_lock)
            {
                _finished = true;
            }
            _writes.Writer.TryComplete();
            AppLog.Write($"tx-audio: connection to {_host}:{_port} failed: {ex.Message}");
        }
    }
}

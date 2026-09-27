using System.Diagnostics;
using System.Net.Sockets;

namespace FTX1RemoteWindows.Services;

/// Where the audio link currently stands — read by the UI via
/// <see cref="RemoteAudioStreamClient.GetStatus"/>, not pushed.
public enum AudioLinkPhase
{
    Stopped,
    Connecting,
    /// The TCP connect itself failed or timed out — Pi/Tailscale
    /// unreachable, or ftx1-audiostream.service isn't running. Retrying.
    Unreachable,
    /// TCP connected but no audio is arriving. The usual cause is that
    /// Pi/ftx1-audiostream.py serves one client at a time (listen(1), a
    /// serial accept loop) and another client — typically the Mac in
    /// .remote mode — already has the stream: the Pi's kernel completes our
    /// handshake into the listen backlog, and we get served only once that
    /// client disconnects. Deliberately keeps the socket open rather than
    /// reconnecting, so this app picks the stream up as soon as it's free.
    WaitingForStream,
    Streaming,
}

/// Levels are per physical channel; which one is Main depends on swap
/// tracking (see AudioChannelSwapTracker).
public readonly record struct AudioLinkStatus(AudioLinkPhase Phase, string? Detail, float LeftRms, float RightRms);

/// C# port of Apps/Mac/FTX1RemoteMac/RemoteAudioStreamClient.swift: connects
/// to Pi/ftx1-audiostream.py on :8532 and delivers the rig's audio as two
/// parallel Float32 streams — Main (left channel) and Sub (right channel).
/// The wire format is raw interleaved-stereo Int16 LE at 44100 Hz, 4 bytes
/// per frame (Main sample, then Sub sample), no framing at all — see that
/// Python file's doc comment. The rate isn't negotiated; this file and the
/// Pi script just agree on it.
///
/// Owns its own connect/retry loop, independent of RigctldClient's — two
/// separate TCP connections to two separate Pi-side services, and one can
/// drop while the other stays up (same reasoning as the Mac's version).
///
/// Unlike the Mac's client, this one tells "unreachable" apart from
/// "connected but nothing arriving" (see <see cref="AudioLinkPhase"/>),
/// in the spirit of Apps/Windows/README.md's connection-state note.
public sealed class RemoteAudioStreamClient : IAsyncDisposable
{
    public const int DefaultPort = 8532;
    public const int SampleRate = 44100;
    private const int BytesPerFrame = 4;

    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ReconnectDelay = TimeSpan.FromSeconds(3);
    /// No bytes for this long while connected counts as "waiting for the
    /// stream" rather than streaming. The Pi sends ~23 ms ALSA periods
    /// continuously, so anything past a second or two is not network jitter.
    private static readonly TimeSpan StallThreshold = TimeSpan.FromSeconds(2);

    private readonly string _host;
    private readonly int _port;
    /// Samples per channel handed to <see cref="_onSamples"/> at a time —
    /// 2048 matches the Mac's AudioCaptureEngine.fftSize / chunk size, so a
    /// future waterfall here sees the same chunking.
    private readonly int _samplesPerChunk;
    /// Invoked on the receive thread, not the UI thread — keep it cheap.
    private readonly Action<float[], float[]> _onSamples;

    private CancellationTokenSource? _cts;
    private Task? _loopTask;

    private readonly object _statusLock = new();
    private AudioLinkPhase _phase = AudioLinkPhase.Stopped;
    private string? _detail;
    private bool _socketConnected;
    private long _lastDataTicks;
    private float _mainRms;
    private float _subRms;

    public RemoteAudioStreamClient(string host, Action<float[], float[]> onSamples, int port = DefaultPort, int samplesPerChunk = 2048)
    {
        _host = host;
        _port = port;
        _samplesPerChunk = samplesPerChunk;
        _onSamples = onSamples;
    }

    public void Start()
    {
        if (_loopTask is not null)
        {
            return;
        }
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        _loopTask = Task.Run(() => ConnectionLoopAsync(token));
    }

    public async Task StopAsync()
    {
        if (_cts is null)
        {
            return;
        }
        _cts.Cancel();
        try
        {
            if (_loopTask is not null)
            {
                await _loopTask.ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
        _cts.Dispose();
        _cts = null;
        _loopTask = null;
        SetPhase(AudioLinkPhase.Stopped, null);
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    /// Snapshot for the UI. The stall check lives here rather than in the
    /// receive loop so a blocked read never needs a timeout/cancel dance.
    public AudioLinkStatus GetStatus()
    {
        lock (_statusLock)
        {
            var phase = _phase;
            if (_socketConnected)
            {
                var sinceData = Stopwatch.GetElapsedTime(_lastDataTicks);
                phase = sinceData > StallThreshold ? AudioLinkPhase.WaitingForStream : AudioLinkPhase.Streaming;
            }
            return new AudioLinkStatus(phase, _detail, _mainRms, _subRms);
        }
    }

    private void SetPhase(AudioLinkPhase phase, string? detail)
    {
        lock (_statusLock)
        {
            _phase = phase;
            _detail = detail;
            _socketConnected = false;
        }
    }

    private async Task ConnectionLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await ReceiveUntilDisconnectedAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"remote-audio: {ex.Message}");
                lock (_statusLock)
                {
                    // A drop after we'd connected is a stream ending, not
                    // the Pi being unreachable — just retry quietly.
                    if (!_socketConnected)
                    {
                        _phase = AudioLinkPhase.Unreachable;
                        _detail = ex.Message;
                    }
                    else
                    {
                        _phase = AudioLinkPhase.Connecting;
                        _detail = "stream ended, reconnecting";
                    }
                    _socketConnected = false;
                }
            }
            try
            {
                await Task.Delay(ReconnectDelay, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async Task ReceiveUntilDisconnectedAsync(CancellationToken token)
    {
        lock (_statusLock)
        {
            if (_phase != AudioLinkPhase.Unreachable)
            {
                _phase = AudioLinkPhase.Connecting;
                _detail = null;
            }
        }

        using var client = new TcpClient { NoDelay = true };
        using (var timeoutCts = new CancellationTokenSource(ConnectTimeout))
        using (var linked = CancellationTokenSource.CreateLinkedTokenSource(token, timeoutCts.Token))
        {
            try
            {
                await client.ConnectAsync(_host, _port, linked.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !token.IsCancellationRequested)
            {
                throw new IOException($"timed out connecting to {_host}:{_port}");
            }
        }

        lock (_statusLock)
        {
            _socketConnected = true;
            _lastDataTicks = Stopwatch.GetTimestamp();
            _detail = null;
        }
        Debug.WriteLine($"remote-audio: connected to {_host}:{_port}");

        await using var stream = client.GetStream();
        var readBuffer = new byte[8192];
        // 0-3 bytes carried across reads when a TCP chunk splits a 4-byte
        // stereo frame — a raw byte stream has no frame-boundary guarantee.
        var pending = new byte[BytesPerFrame];
        var pendingCount = 0;
        var main = new float[_samplesPerChunk];
        var sub = new float[_samplesPerChunk];
        var filled = 0;

        while (!token.IsCancellationRequested)
        {
            var read = await stream.ReadAsync(readBuffer, token).ConfigureAwait(false);
            if (read == 0)
            {
                throw new IOException("stream closed by the Pi");
            }
            lock (_statusLock)
            {
                _lastDataTicks = Stopwatch.GetTimestamp();
            }

            var offset = 0;
            if (pendingCount > 0)
            {
                var need = Math.Min(BytesPerFrame - pendingCount, read);
                Array.Copy(readBuffer, 0, pending, pendingCount, need);
                pendingCount += need;
                offset = need;
                if (pendingCount == BytesPerFrame)
                {
                    AppendFrame(pending, 0);
                    pendingCount = 0;
                }
            }
            var usableEnd = offset + (read - offset) / BytesPerFrame * BytesPerFrame;
            for (var i = offset; i < usableEnd; i += BytesPerFrame)
            {
                AppendFrame(readBuffer, i);
            }
            var leftover = read - usableEnd;
            if (leftover > 0)
            {
                Array.Copy(readBuffer, usableEnd, pending, 0, leftover);
                pendingCount = leftover;
            }
        }

        void AppendFrame(byte[] bytes, int index)
        {
            var left = (short)(bytes[index] | (bytes[index + 1] << 8));
            var right = (short)(bytes[index + 2] | (bytes[index + 3] << 8));
            main[filled] = left / 32768f;
            sub[filled] = right / 32768f;
            filled++;
            if (filled == _samplesPerChunk)
            {
                var mainChunk = (float[])main.Clone();
                var subChunk = (float[])sub.Clone();
                filled = 0;
                lock (_statusLock)
                {
                    _mainRms = SquelchGate.Rms(mainChunk);
                    _subRms = SquelchGate.Rms(subChunk);
                }
                _onSamples(mainChunk, subChunk);
            }
        }
    }
}

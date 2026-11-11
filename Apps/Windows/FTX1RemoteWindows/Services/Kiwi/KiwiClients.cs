using System.Net.WebSockets;
using System.Text;
using System.Threading.Channels;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

public enum KiwiErrorKind
{
    /// The host field can't be made into a URL.
    InvalidHost,
    /// The Kiwi refused the password (badp=1 with free channels left).
    BadPassword,
    /// Every receiver channel is in use (too_busy, or badp=1 with none free).
    Busy,
    /// The Kiwi says it's down.
    Down,
    /// The Kiwi redirected this client elsewhere; not followed.
    Redirect,
    /// Another badp code (kiwiclient's list: 2 still starting, 3/4/7 admin,
    /// 5 no second connection from this address, 6 database update).
    Refused,
    /// Couldn't connect, or the connection dropped (the system's text in Detail).
    Unreachable,
    /// Connected, but nothing arrived for the silence timeout.
    NoResponse,
}

/// Why a session couldn't start or ended.
public sealed record KiwiSdrError(KiwiErrorKind Kind, string Detail = "", int Code = 0);

public sealed record KiwiAudioChunk(short[] Samples, double SampleRate, double SmeterDbm, KiwiSoundFlags Flags, uint Sequence);

public abstract record KiwiSdrEvent
{
    /// The Kiwi accepted us and reported its real audio rate (e.g.
    /// 11998.902088 Hz, not 12000 — resample from this).
    public sealed record Ready(double SampleRate) : KiwiSdrEvent;
    public sealed record Audio(KiwiAudioChunk Chunk) : KiwiSdrEvent;
    /// The session ended: null after Stop(), else why.
    public sealed record Closed(KiwiSdrError? Error) : KiwiSdrEvent;
}

/// The socket plumbing the Kiwi's two streams share: a ClientWebSocket,
/// "SET auth" first, a keepalive every second, a silence watchdog, a clean
/// close (which frees the Kiwi's channel). One session per instance. Never
/// logs the password. Port of the plumbing in KiwiSDRClient.swift /
/// KiwiWaterfallClient.swift (kept as two clients, sharing only this).
public abstract class KiwiStreamClient
{
    public static readonly TimeSpan SilenceTimeout = TimeSpan.FromSeconds(10);

    protected readonly string HostPort;
    protected readonly string Password;
    protected readonly string IdentUser;
    protected readonly long Timestamp;
    private readonly string _stream;

    private ClientWebSocket? _socket;
    private CancellationTokenSource? _cts;
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private long _lastFrameTicks = Environment.TickCount64;
    private volatile bool _finished;

    protected KiwiStreamClient(string hostPort, string password, string identUser, long timestamp, string stream)
    {
        HostPort = hostPort;
        Password = password;
        IdentUser = identUser;
        Timestamp = timestamp;
        _stream = stream;
    }

    protected bool Finished => _finished;

    protected abstract Uri? Url { get; }
    protected abstract void Log(string message);
    protected abstract void Emit(KiwiSdrError? closedError, bool closed);
    protected abstract Task HandleAsync(ReadOnlyMemory<byte> data);

    public void Start()
    {
        if (_socket is not null || _finished)
        {
            return;
        }
        if (Url is not { } url)
        {
            Finish(new KiwiSdrError(KiwiErrorKind.InvalidHost));
            return;
        }
        _cts = new CancellationTokenSource();
        _socket = new ClientWebSocket();
        _lastFrameTicks = Environment.TickCount64;
        Log($"connecting to {url}");
        _ = RunAsync(_socket, url, _cts.Token);
    }

    /// Closes the socket (the Kiwi frees the channel) and ends the events.
    public void Stop()
    {
        if (_finished)
        {
            return;
        }
        Log("stop()");
        Finish(null);
    }

    private async Task RunAsync(ClientWebSocket socket, Uri url, CancellationToken token)
    {
        try
        {
            using (var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                connectTimeout.CancelAfter(TimeSpan.FromSeconds(10));
                await socket.ConnectAsync(url, connectTimeout.Token).ConfigureAwait(false);
            }
            await SendAsync(KiwiProtocol.Auth(Password), "SET auth t=kiwi p=…").ConfigureAwait(false);
            _ = WatchdogAsync(token);
            await ReceiveLoopAsync(socket, token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            // stop()
        }
        catch (Exception ex)
        {
            if (!_finished)
            {
                Log($"connection failed: {ex.Message}");
                Finish(new KiwiSdrError(KiwiErrorKind.Unreachable, ex.InnerException?.Message ?? ex.Message));
            }
        }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket socket, CancellationToken token)
    {
        var buffer = new byte[64 * 1024];
        using var message = new MemoryStream();
        while (!_finished && !token.IsCancellationRequested)
        {
            var result = await socket.ReceiveAsync(buffer, token).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                // A badp=1 makes the Kiwi close right after; that close isn't the reason.
                if (!_finished)
                {
                    Finish(new KiwiSdrError(KiwiErrorKind.Unreachable, "closed by the Kiwi"));
                }
                return;
            }
            message.Write(buffer, 0, result.Count);
            if (!result.EndOfMessage)
            {
                continue;
            }
            _lastFrameTicks = Environment.TickCount64;
            var data = message.ToArray();
            message.SetLength(0);
            await HandleAsync(data).ConfigureAwait(false);
        }
    }

    /// "shownAs" replaces the text in the log (the auth command); log:false
    /// skips it (keepalives).
    protected async Task SendAsync(string text, string? shownAs = null, bool log = true)
    {
        var socket = _socket;
        if (socket is null || _finished || socket.State != WebSocketState.Open)
        {
            return;
        }
        if (log)
        {
            Log($"send {shownAs ?? text}");
        }
        try
        {
            await _sendLock.WaitAsync().ConfigureAwait(false);
            try
            {
                await socket.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true,
                                       _cts?.Token ?? CancellationToken.None).ConfigureAwait(false);
            }
            finally
            {
                _sendLock.Release();
            }
        }
        catch (Exception ex)
        {
            Log($"send failed: {ex.Message}");
        }
    }

    protected void Send(string text, string? shownAs = null, bool log = true) => _ = SendAsync(text, shownAs, log);

    protected void StartKeepalive()
    {
        var token = _cts?.Token ?? CancellationToken.None;
        _ = Task.Run(async () =>
        {
            try
            {
                while (!_finished && !token.IsCancellationRequested)
                {
                    await Task.Delay(1000, token).ConfigureAwait(false);
                    await SendAsync(KiwiProtocol.Keepalive, log: false).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
            }
        }, token);
    }

    /// No answer at all (a host that accepts TCP and says nothing), or data
    /// stopping mid-session.
    private async Task WatchdogAsync(CancellationToken token)
    {
        try
        {
            while (!_finished && !token.IsCancellationRequested)
            {
                await Task.Delay(1000, token).ConfigureAwait(false);
                if (!_finished && Environment.TickCount64 - _lastFrameTicks > SilenceTimeout.TotalMilliseconds)
                {
                    Log($"nothing from the Kiwi for {SilenceTimeout.TotalSeconds:0} s");
                    Finish(new KiwiSdrError(KiwiErrorKind.NoResponse));
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    protected void Finish(KiwiSdrError? error)
    {
        lock (_sendLock)
        {
            if (_finished)
            {
                return;
            }
            _finished = true;
        }
        if (error is not null)
        {
            Log($"session ended: {error.Kind} {error.Detail}".TrimEnd());
        }
        var socket = _socket;
        _cts?.Cancel();
        _socket = null;
        if (socket is not null)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    if (socket.State == WebSocketState.Open)
                    {
                        using var closeTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                        await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, closeTimeout.Token).ConfigureAwait(false);
                    }
                }
                catch
                {
                    // Best effort: the Kiwi frees the channel when the socket goes.
                }
                finally
                {
                    socket.Dispose();
                }
            });
        }
        Emit(error, closed: true);
    }

    protected static int ParseBadp(string? value) => int.TryParse(value, out var code) ? code : -1;
}

/// One KiwiSDR sound stream (/&lt;timestamp&gt;/SND): auth, the setup
/// sequence kiwiclient and the Kiwi's own page send, a keepalive every
/// second, retuning on the open socket, and a clean close. Events come out of
/// <see cref="Events"/> in order. Port of the Mac's KiwiSDRClient.
public sealed class KiwiSdrClient : KiwiStreamClient
{
    private readonly Channel<KiwiSdrEvent> _events = Channel.CreateBounded<KiwiSdrEvent>(
        new BoundedChannelOptions(256) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
    private readonly bool _compression;
    private readonly KiwiSoundDecoder _decoder = new();
    private readonly object _stateLock = new();
    private KiwiTuning _tuning;
    private KiwiReceiverSettings _receiver;
    private double? _sampleRate;
    private bool _setUp, _accepted, _announced;

    public ChannelReader<KiwiSdrEvent> Events => _events.Reader;

    public KiwiSdrClient(string hostPort, string password, KiwiTuning tuning, KiwiReceiverSettings receiver,
                         long timestamp, string identUser = "FTX1Remote", bool compression = false)
        : base(hostPort, password, identUser, timestamp, "SND")
    {
        _tuning = tuning;
        _receiver = receiver;
        _compression = compression;
    }

    protected override Uri? Url => KiwiProtocol.SoundUrl(HostPort, Timestamp);

    protected override void Log(string message) => AppLog.Write($"kiwisdr: {message}");

    protected override void Emit(KiwiSdrError? closedError, bool closed)
    {
        if (closed)
        {
            _events.Writer.TryWrite(new KiwiSdrEvent.Closed(closedError));
            _events.Writer.TryComplete();
        }
    }

    /// Retunes on the open socket — no reconnect. Before setup it only
    /// changes what setup will send.
    public void Tune(KiwiTuning tuning)
    {
        bool setUp;
        lock (_stateLock)
        {
            _tuning = tuning;
            setUp = _setUp;
        }
        if (setUp)
        {
            Send(tuning.Command);
        }
    }

    /// Changes the AGC, blanker or filter on the open socket, sending only
    /// what differs. Before setup it only changes what setup will send.
    public void SetReceiver(KiwiReceiverSettings settings)
    {
        List<string> commands;
        bool setUp;
        lock (_stateLock)
        {
            commands = settings.Commands(_receiver);
            _receiver = settings;
            setUp = _setUp;
        }
        if (setUp)
        {
            foreach (var command in commands)
            {
                Send(command);
            }
        }
    }

    protected override async Task HandleAsync(ReadOnlyMemory<byte> data)
    {
        switch (KiwiProtocol.ParseFrame(data.Span))
        {
            case KiwiFrame.Message message:
                foreach (var item in message.Items)
                {
                    await HandleItemAsync(item).ConfigureAwait(false);
                }
                break;
            case KiwiFrame.Sound sound:
                if (_sampleRate is not { } rate)
                {
                    return;
                }
                var samples = _decoder.Samples(sound.Frame);
                if (samples.Length > 0)
                {
                    _events.Writer.TryWrite(new KiwiSdrEvent.Audio(new KiwiAudioChunk(
                        samples, rate, sound.Frame.SmeterDbm, sound.Frame.Flags, sound.Frame.Sequence)));
                }
                break;
        }
    }

    private async Task HandleItemAsync(KiwiMessageItem item)
    {
        if (Finished)
        {
            return;
        }
        switch (item.Name)
        {
            case "load_cfg" or "load_dxcfg" or "load_dxcomm_cfg":
                return; // large, unused
            case "badp":
                var code = ParseBadp(item.Value);
                Log($"badp={code}");
                switch (code)
                {
                    case 0:
                        _accepted = true;
                        AnnounceIfReady();
                        break;
                    case 1:
                        // "Bad password OR all channels busy that don't require a
                        // password" — /status tells the two apart.
                        var full = await ChannelsFullAsync(HostPort).ConfigureAwait(false);
                        Finish(new KiwiSdrError(full ? KiwiErrorKind.Busy : KiwiErrorKind.BadPassword));
                        break;
                    default:
                        Finish(new KiwiSdrError(KiwiErrorKind.Refused, Code: code));
                        break;
                }
                break;
            case "too_busy":
                Log($"too_busy={item.Value}");
                Finish(new KiwiSdrError(KiwiErrorKind.Busy));
                break;
            case "down":
                Finish(new KiwiSdrError(KiwiErrorKind.Down));
                break;
            case "redirect":
                Finish(new KiwiSdrError(KiwiErrorKind.Redirect, item.Value ?? ""));
                break;
            case "audio_rate":
                if (double.TryParse(item.Value, System.Globalization.NumberStyles.Float,
                                    System.Globalization.CultureInfo.InvariantCulture, out var audioRate))
                {
                    Send(KiwiProtocol.AudioRateOk((int)Math.Round(audioRate)));
                }
                break;
            case "sample_rate":
                if (!double.TryParse(item.Value, System.Globalization.NumberStyles.Float,
                                     System.Globalization.CultureInfo.InvariantCulture, out var sampleRate) || sampleRate <= 0)
                {
                    return;
                }
                Log($"sample_rate={sampleRate}");
                _sampleRate = sampleRate;
                List<string>? setup = null;
                string? tune = null;
                lock (_stateLock)
                {
                    if (!_setUp)
                    {
                        _setUp = true;
                        setup = KiwiProtocol.SetupCommands(IdentUser, _compression, _receiver);
                        tune = _tuning.Command;
                    }
                }
                if (setup is not null)
                {
                    foreach (var command in setup)
                    {
                        Send(command);
                    }
                    Send(tune!);
                    Send(KiwiProtocol.Keepalive, log: false);
                    StartKeepalive();
                }
                AnnounceIfReady();
                break;
        }
    }

    private void AnnounceIfReady()
    {
        if (_announced || !_accepted || _sampleRate is not { } rate)
        {
            return;
        }
        _announced = true;
        _events.Writer.TryWrite(new KiwiSdrEvent.Ready(rate));
    }

    /// Whether the Kiwi's /status shows every channel in use. False if it
    /// can't be read.
    public static async Task<bool> ChannelsFullAsync(string hostPort)
    {
        if (KiwiProtocol.SoundUrl(hostPort, 0) is not { } sound)
        {
            return false;
        }
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
            var text = await http.GetStringAsync($"http://{sound.Host}:{sound.Port}/status").ConfigureAwait(false);
            var status = new KiwiStatus(text);
            return status.Users is { } users && status.UsersMax is { } max && users >= max;
        }
        catch
        {
            return false;
        }
    }
}

public abstract record KiwiWaterfallEvent
{
    /// Accepted and set up: the geometry and calibration to read rows by.
    public sealed record Ready(KiwiWaterfallGeometry Geometry, int Cal) : KiwiWaterfallEvent;
    public sealed record Row(KiwiWaterfallFrame Frame) : KiwiWaterfallEvent;
    public sealed record Closed(KiwiSdrError? Error) : KiwiWaterfallEvent;
}

/// One KiwiSDR waterfall stream (/&lt;timestamp&gt;/W/F), the sound stream's
/// companion: same auth, same MSG framing, a keepalive every second, and "SET
/// zoom=… start=…" on the open socket to pan and zoom. Open it with the sound
/// stream's timestamp once that one is ready — the Kiwi pairs them, so this
/// takes no receiver channel of its own. A failure here ends only this stream.
public sealed class KiwiWaterfallClient : KiwiStreamClient
{
    private readonly Channel<KiwiWaterfallEvent> _events = Channel.CreateBounded<KiwiWaterfallEvent>(
        new BoundedChannelOptions(64) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
    private readonly object _stateLock = new();
    private bool _accepted, _setUp, _announced;
    // What the Kiwi reports before wf_setup (defaults = KiwiSDR 2 at v1.902).
    private double _bandwidthHz = 30_000_000;
    private int _fftSize = 1024;
    private int _zoomMax = 14;
    private int _cal = -13;
    private (int Zoom, int Start)? _view;

    public ChannelReader<KiwiWaterfallEvent> Events => _events.Reader;

    public KiwiWaterfallClient(string hostPort, string password, long timestamp, string identUser = "FTX1Remote")
        : base(hostPort, password, identUser, timestamp, "W/F")
    {
    }

    protected override Uri? Url => KiwiProtocol.WaterfallUrl(HostPort, Timestamp);

    protected override void Log(string message) => AppLog.Write($"kiwisdr: waterfall: {message}");

    protected override void Emit(KiwiSdrError? closedError, bool closed)
    {
        if (closed)
        {
            _events.Writer.TryWrite(new KiwiWaterfallEvent.Closed(closedError));
            _events.Writer.TryComplete();
        }
    }

    /// Pans/zooms on the open socket. Before setup it only changes what setup
    /// will ask for. Repeats of the last request aren't resent.
    public void SetView(int zoom, int start)
    {
        bool send;
        lock (_stateLock)
        {
            if (_view is { } view && view.Zoom == zoom && view.Start == start && _setUp)
            {
                return;
            }
            _view = (zoom, start);
            send = _setUp;
        }
        if (send)
        {
            Send(KiwiProtocol.WaterfallView(zoom, start));
        }
    }

    protected override Task HandleAsync(ReadOnlyMemory<byte> data)
    {
        switch (KiwiProtocol.ParseFrame(data.Span))
        {
            case KiwiFrame.Message message:
                foreach (var item in message.Items)
                {
                    HandleItem(item);
                }
                break;
            case KiwiFrame.Waterfall row:
                if (_announced && !row.Frame.IsCompressed)
                {
                    _events.Writer.TryWrite(new KiwiWaterfallEvent.Row(row.Frame));
                }
                break;
        }
        return Task.CompletedTask;
    }

    private void HandleItem(KiwiMessageItem item)
    {
        if (Finished)
        {
            return;
        }
        double? number = double.TryParse(item.Value, System.Globalization.NumberStyles.Float,
                                         System.Globalization.CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
        switch (item.Name)
        {
            case "load_cfg" or "load_dxcfg" or "load_dxcomm_cfg":
                return;
            case "badp":
                var code = ParseBadp(item.Value);
                Log($"badp={code}");
                switch (code)
                {
                    case 0:
                        _accepted = true;
                        AnnounceIfReady();
                        break;
                    case 1:
                        // The sound stream already got in with this password, so
                        // a refusal here is the channel side, not the password.
                        Finish(new KiwiSdrError(KiwiErrorKind.Busy));
                        break;
                    default:
                        Finish(new KiwiSdrError(KiwiErrorKind.Refused, Code: code));
                        break;
                }
                break;
            case "too_busy":
                Finish(new KiwiSdrError(KiwiErrorKind.Busy));
                break;
            case "down":
                Finish(new KiwiSdrError(KiwiErrorKind.Down));
                break;
            case "redirect":
                Finish(new KiwiSdrError(KiwiErrorKind.Redirect, item.Value ?? ""));
                break;
            case "bandwidth":
                if (number is > 0) { _bandwidthHz = number.Value; }
                break;
            case "wf_fft_size":
                if (number is >= 64) { _fftSize = (int)number.Value; }
                break;
            case "zoom_max":
                if (number is >= 0 and <= 20) { _zoomMax = (int)number.Value; }
                break;
            case "wf_cal":
                if (number is { } cal) { _cal = (int)cal; }
                break;
            case "wf_setup":
                (int Zoom, int Start)? view;
                lock (_stateLock)
                {
                    if (_setUp)
                    {
                        return;
                    }
                    _setUp = true;
                    view = _view;
                    if (view is not { } v || (v.Zoom == 0 && v.Start == 0))
                    {
                        _view = (0, 0);
                    }
                }
                Log($"setup bandwidth={_bandwidthHz} fft={_fftSize} zoom_max={_zoomMax} cal={_cal}");
                foreach (var command in KiwiProtocol.WaterfallSetupCommands(IdentUser))
                {
                    Send(command);
                }
                if (view is { } wanted && (wanted.Zoom != 0 || wanted.Start != 0))
                {
                    Send(KiwiProtocol.WaterfallView(wanted.Zoom, wanted.Start));
                }
                Send(KiwiProtocol.Keepalive, log: false);
                StartKeepalive();
                AnnounceIfReady();
                break;
        }
    }

    private void AnnounceIfReady()
    {
        if (_announced || !_accepted || !_setUp)
        {
            return;
        }
        _announced = true;
        _events.Writer.TryWrite(new KiwiWaterfallEvent.Ready(new KiwiWaterfallGeometry(_bandwidthHz, _fftSize, _zoomMax), _cal));
    }
}

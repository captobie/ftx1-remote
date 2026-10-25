using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// Wavelog → rig: clicking a spot in Wavelog's DX cluster, bandmap or DX
/// waterfall tunes the rig — the Mac's WavelogTuneListener. Wavelog's page
/// fetches GET &lt;cat_url&gt;/&lt;Hz&gt;/&lt;mode&gt; from the browser
/// (WavelogTuneRequest); the radio's cat_url is http://127.0.0.1:54321
/// unless set in Wavelog, so this listens there — WaveLogGate's port, so
/// only one of the two can run. Settings → Logbook → Wavelog → "Tune the
/// rig from Wavelog"; off by default.
///
/// Loopback only, so the browser has to run on this PC. Any web page could
/// send the same request, so only one whose Origin is the Wavelog URL in
/// Settings is obeyed (a browser always sends it on a cross-origin fetch;
/// curl needs -H Origin:). The reply carries CORS headers for that origin
/// and answers Chrome's private-network preflight
/// (Access-Control-Allow-Private-Network). The tuning itself is the
/// `tune` callback (MainWindow.TuneFromWavelog, on the UI thread), with the
/// WebSDR window's click-to-tune rules. Connections are handled on the
/// thread pool; State/LastEvent change from there too (Changed).
public sealed class WavelogTuneListener
{
    public const int MaxHeadBytes = 8192;
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(5);

    public abstract record ListenerState
    {
        public sealed record Off : ListenerState;
        public sealed record Listening(int Port) : ListenerState;
        public sealed record Failed(string Message) : ListenerState;
    }

    public ListenerState State { get; private set; } = new ListenerState.Off();

    /// The last request's outcome, for Settings.
    public (DateTimeOffset At, string Text, bool Ok)? LastEvent { get; private set; }

    /// State or LastEvent changed — on any thread.
    public event Action? Changed;

    private readonly Func<WavelogTuneRequest, Task<string?>> _tune;
    private readonly Func<string> _wavelogUrl;
    private TcpListener? _listener;
    private CancellationTokenSource? _accepting;

    /// `tune` tunes the rig, or returns why it didn't; `wavelogUrl` is
    /// Settings' Wavelog URL, read at each request.
    public WavelogTuneListener(Func<WavelogTuneRequest, Task<string?>> tune, Func<string> wavelogUrl)
    {
        _tune = tune;
        _wavelogUrl = wavelogUrl;
    }

    /// Starts, stops or moves the listener to match Settings.
    public void Apply(bool enabled, int port)
    {
        if (!enabled)
        {
            Stop();
            return;
        }
        if (_listener is not null && State is ListenerState.Listening { Port: var current } && current == port)
        {
            return;
        }
        Stop();
        Start(port);
    }

    public void Stop()
    {
        _accepting?.Cancel();
        _accepting = null;
        _listener?.Stop();
        _listener = null;
        if (State is not ListenerState.Off)
        {
            State = new ListenerState.Off();
            Changed?.Invoke();
        }
    }

    private void Start(int port)
    {
        var listener = new TcpListener(IPAddress.Loopback, port) { ExclusiveAddressUse = true };
        try
        {
            listener.Start();
        }
        catch (SocketException e)
        {
            State = new ListenerState.Failed(e.SocketErrorCode is SocketError.AddressAlreadyInUse or SocketError.AccessDenied
                ? $"Port {port} is in use — is WaveLogGate running?"
                : $"Couldn't listen on port {port}: {e.Message}");
            AppLog.Write($"Wavelog: tune listener failed on port {port}: {e.Message}");
            Changed?.Invoke();
            return;
        }
        _listener = listener;
        var cts = new CancellationTokenSource();
        _accepting = cts;
        State = new ListenerState.Listening(port);
        AppLog.Write($"Wavelog: tune listener on 127.0.0.1:{port}");
        Changed?.Invoke();
        _ = AcceptLoopAsync(listener, cts.Token);
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(token);
            }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException)
            {
                return;
            }
            _ = Task.Run(() => HandleAsync(client));
        }
    }

    private async Task HandleAsync(TcpClient client)
    {
        using (client)
        {
            // A client that never finishes its request isn't kept around.
            using var timeout = new CancellationTokenSource(RequestTimeout);
            try
            {
                var stream = client.GetStream();
                if (await ReadHeadAsync(stream, timeout.Token) is not { } head)
                {
                    return;
                }
                var (status, body, origin, preflight) = await RespondAsync(head);
                await stream.WriteAsync(Response(status, body, origin, preflight), timeout.Token);
            }
            catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or ObjectDisposedException)
            {
            }
        }
    }

    /// Everything up to the blank line, or null if the client gave up, sent
    /// too much or took too long.
    private static async Task<string?> ReadHeadAsync(NetworkStream stream, CancellationToken token)
    {
        var buffer = new byte[MaxHeadBytes];
        var count = 0;
        while (count < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(count), token);
            if (read == 0)
            {
                return null;
            }
            count += read;
            var text = Encoding.UTF8.GetString(buffer, 0, count);
            if (text.IndexOf("\r\n\r\n", StringComparison.Ordinal) is var end and >= 0)
            {
                return text[..end];
            }
        }
        return null;
    }

    private async Task<(int Status, string Body, string? Origin, bool Preflight)> RespondAsync(string headText)
    {
        if (WavelogTuneRequest.ParseHead(headText) is not { } head)
        {
            return (400, "Bad request", null, false);
        }
        var origin = head.Headers.TryGetValue("origin", out var o) ? o : null;
        var allowed = WavelogTuneRequest.OriginOfWavelogUrl(_wavelogUrl());
        var originOk = origin is not null && allowed is not null && origin.ToLowerInvariant() == allowed;

        if (head.Method == "OPTIONS")
        {
            return (originOk ? 204 : 403, "", originOk ? origin : null, true);
        }
        if (head.Method != "GET")
        {
            return (405, "Method not allowed", null, false);
        }
        if (WavelogTuneRequest.FromPath(head.Path) is not { } request)
        {
            return (404, "Not found", originOk ? origin : null, false);
        }
        if (!originOk)
        {
            Record($"Ignored a tune request from {origin ?? "a request without an Origin"} — it isn't the Wavelog URL in Settings", ok: false);
            return (403, "Origin not allowed", null, false);
        }
        var modeText = request.Mode?.DisplayName() ?? "mode unchanged";
        var mhz = (request.FrequencyHz / 1_000_000.0).ToString("0.0000", CultureInfo.InvariantCulture) + " MHz";
        if (await _tune(request) is { } refusal)
        {
            Record($"Didn't tune to {mhz}: {refusal}", ok: false);
            return (409, refusal, origin, false);
        }
        Record($"Tuned to {mhz} {modeText}", ok: true);
        return (200, "OK", origin, false);
    }

    private void Record(string text, bool ok)
    {
        AppLog.Write($"Wavelog: {text}");
        LastEvent = (DateTimeOffset.Now, text, ok);
        Changed?.Invoke();
    }

    private static byte[] Response(int status, string body, string? origin, bool preflight)
    {
        var reason = status switch
        {
            200 => "OK",
            204 => "No Content",
            400 => "Bad Request",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            _ => "Error",
        };
        var lines = new List<string>
        {
            $"HTTP/1.1 {status} {reason}",
            "Content-Type: text/plain; charset=utf-8",
            $"Content-Length: {Encoding.UTF8.GetByteCount(body)}",
            "Cache-Control: no-store",
            "Connection: close",
        };
        if (origin is not null)
        {
            lines.Add($"Access-Control-Allow-Origin: {origin}");
            lines.Add("Vary: Origin");
            if (preflight)
            {
                lines.Add("Access-Control-Allow-Methods: GET, OPTIONS");
                lines.Add("Access-Control-Allow-Headers: *");
                lines.Add("Access-Control-Allow-Private-Network: true");
                lines.Add("Access-Control-Max-Age: 600");
            }
        }
        return Encoding.UTF8.GetBytes(string.Join("\r\n", lines) + "\r\n\r\n" + body);
    }
}

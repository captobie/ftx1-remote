using System.Net.WebSockets;
using System.Text;

namespace FTX1RemoteWindows.Services.FreeDv;

/// FreeDV Reporter (qso.freedv.org) — the Mac's FreeDVReporter: reports this
/// station (frequency, transmitting or not, its status message, the callsigns
/// it hears) and keeps the live list of every other station on it.
///
/// Connected only while <see cref="Enabled"/> (the window's checkbox, saved,
/// off by default), active (the FreeDV window is open) and Settings → Station
/// has a callsign and a grid. Reconnects with a growing delay; our state is
/// sent again on every (re)connect.
///
/// Lives on the UI thread: every call and every await's continuation.
public sealed class FreeDvReporter
{
    public enum ConnectionStatus
    {
        Off,
        /// Enabled, but Settings → Station lacks a callsign or grid.
        NeedsStation,
        Connecting,
        Connected,
        /// Lost or refused; retrying (<see cref="RetryReason"/>).
        Retrying,
    }

    /// <see cref="Status"/> or <see cref="Enabled"/> changed.
    public event Action? Changed;
    /// <see cref="Stations"/> changed (at most twice a second).
    public event Action? StationsChanged;

    /// Reconnect delays, growing; the last repeats.
    private static readonly double[] RetryDelays = [5, 10, 30, 60];
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan PublishDelay = TimeSpan.FromMilliseconds(500);

    private readonly FreeDvData _settings;
    private readonly Action _save;
    private readonly string _version;
    private readonly Func<(string Callsign, string Grid)> _station;
    private readonly Action<string> _log;
    private readonly Uri _url;

    private bool _active;
    private long? _frequencyHz;
    private bool _transmitting;
    private readonly FreeDvReporterStations _table = new();
    private ClientWebSocket? _socket;
    private CancellationTokenSource? _run;
    /// The station the running connection was made for.
    private (string Callsign, string Grid)? _connectedAs;
    private bool _fullyConnected;
    private Task _sending = Task.CompletedTask;
    private bool _publishScheduled;

    /// <param name="version">What the site shows as our software
    /// ("FTX1Remote 0.14").</param>
    /// <param name="station">Our callsign and grid, read at each connect.</param>
    public FreeDvReporter(FreeDvData settings, Action save, string version,
        Func<(string Callsign, string Grid)> station, Action<string>? log = null, Uri? url = null)
    {
        _settings = settings;
        _save = save;
        _version = version;
        _station = station;
        _log = log ?? (_ => { });
        _url = url ?? FreeDvReporterProtocol.Url();
    }

    public ConnectionStatus Status { get; private set; } = ConnectionStatus.Off;
    public string RetryReason { get; private set; } = "";
    /// Every station on FreeDV Reporter, most recently updated first.
    public IReadOnlyList<FreeDvReporterStation> Stations { get; private set; } = [];

    public bool Enabled
    {
        get => _settings.ReporterEnabled;
        set
        {
            if (value == _settings.ReporterEnabled)
            {
                return;
            }
            _settings.ReporterEnabled = value;
            _save();
            Reconsider();
            Changed?.Invoke();
        }
    }

    /// Shown next to our call on the site. Sent when it changes.
    public string Message
    {
        get => _settings.ReporterMessage;
        set
        {
            if (value == _settings.ReporterMessage)
            {
                return;
            }
            _settings.ReporterMessage = value;
            _save();
            Send(FreeDvReporterProtocol.Message(value));
        }
    }

    // Inputs

    /// The FreeDV window opened or closed.
    public void SetActive(bool active)
    {
        if (active == _active)
        {
            return;
        }
        _active = active;
        Reconsider();
    }

    /// Settings → Station may have changed: connect or reconnect as needed.
    public void StationChanged()
    {
        if (_run is not null && _connectedAs != Station())
        {
            StopConnection();
        }
        Reconsider();
    }

    /// Where we listen (and would transmit). Null = unknown, sent as 0.
    public void SetFrequency(long? hz)
    {
        if (hz == _frequencyHz)
        {
            return;
        }
        _frequencyHz = hz;
        Send(FreeDvReporterProtocol.FrequencyChange(hz ?? 0));
    }

    public void SetTransmitting(bool transmitting)
    {
        if (transmitting == _transmitting)
        {
            return;
        }
        _transmitting = transmitting;
        Send(FreeDvReporterProtocol.TransmitReport(transmitting));
    }

    /// A callsign decoded from an end-of-over, live (not from a file).
    public void ReportHeard(string callsign, float? snrDb) =>
        Send(FreeDvReporterProtocol.ReceiveReport(callsign, (int)Math.Round(snrDb ?? 0)));

    // Connection

    private (string Callsign, string Grid)? Station()
    {
        var (callsign, grid) = _station();
        callsign = callsign.Trim().ToUpperInvariant();
        grid = grid.Trim();
        return callsign.Length == 0 || grid.Length < 4 ? null : (callsign, grid);
    }

    private void Reconsider()
    {
        if (!Enabled || !_active)
        {
            StopConnection();
            SetStatus(ConnectionStatus.Off);
            return;
        }
        if (Station() is not { } station)
        {
            StopConnection();
            SetStatus(ConnectionStatus.NeedsStation);
            return;
        }
        if (_run is not null)
        {
            return;
        }
        _connectedAs = station;
        _run = new CancellationTokenSource();
        _ = RunAsync(station, _run.Token);
    }

    private void StopConnection()
    {
        var run = _run;
        var socket = _socket;
        _run = null;
        _socket = null;
        _connectedAs = null;
        _fullyConnected = false;
        if (run is not null)
        {
            _ = CloseAsync(socket, _sending, run);
        }
        ClearStations();
    }

    /// Says goodbye if it can (the site then drops us at once), then ends the
    /// run.
    private static async Task CloseAsync(ClientWebSocket? socket, Task sending, CancellationTokenSource run)
    {
        try
        {
            if (socket?.State == WebSocketState.Open)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await sending.WaitAsync(timeout.Token);
                await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, timeout.Token);
            }
        }
        catch (Exception)
        {
            // Gone already; cancelling below ends it either way.
        }
        run.Cancel();
        socket?.Dispose();
    }

    /// Connects, reads until the connection ends, waits, repeats.
    private async Task RunAsync((string Callsign, string Grid) station, CancellationToken token)
    {
        var attempt = 0;
        while (_run?.Token == token)
        {
            SetStatus(ConnectionStatus.Connecting);
            var (reason, connected) = await ConnectAndReadAsync(station, token);
            if (_run?.Token != token)
            {
                return;
            }
            _socket?.Dispose();
            _socket = null;
            _fullyConnected = false;
            ClearStations();
            if (connected)
            {
                attempt = 0;
            }
            var delay = RetryDelays[Math.Min(attempt, RetryDelays.Length - 1)];
            attempt++;
            RetryReason = reason;
            SetStatus(ConnectionStatus.Retrying);
            _log($"freedv-reporter: disconnected ({reason}), retrying in {delay} s");
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(delay), token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// One connection, until it drops: why, and whether it had fully
    /// connected.
    private async Task<(string Reason, bool Connected)> ConnectAndReadAsync(
        (string Callsign, string Grid) station, CancellationToken token)
    {
        var socket = new ClientWebSocket();
        _socket = socket;
        var connected = false;
        // Until the server says how often it pings.
        var allowance = TimeSpan.FromSeconds(30);
        // Cancelled when no ping arrives in time.
        using var silence = CancellationTokenSource.CreateLinkedTokenSource(token);
        try
        {
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                timeout.CancelAfter(ConnectTimeout);
                await socket.ConnectAsync(_url, timeout.Token);
            }
            silence.CancelAfter(allowance);
            var buffer = new byte[16 * 1024];
            using var message = new MemoryStream();
            while (_run?.Token == token)
            {
                var result = await socket.ReceiveAsync(buffer.AsMemory(), silence.Token);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }
                message.Write(buffer, 0, result.Count);
                if (!result.EndOfMessage)
                {
                    continue;
                }
                var frame = Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
                message.SetLength(0);
                if (_run?.Token != token)
                {
                    break;
                }
                var incoming = FreeDvReporterProtocol.Parse(frame);
                switch (incoming.Kind)
                {
                    case FreeDvReporterProtocol.Kind.Open:
                        allowance = TimeSpan.FromSeconds(incoming.PingInterval + incoming.PingTimeout);
                        silence.CancelAfter(allowance);
                        Write(socket, FreeDvReporterProtocol.ConnectFrame(
                            station.Callsign, station.Grid, _version, receiveOnly: false, os: "Windows"));
                        break;
                    case FreeDvReporterProtocol.Kind.Ping:
                        silence.CancelAfter(allowance);
                        Write(socket, FreeDvReporterProtocol.Pong);
                        break;
                    case FreeDvReporterProtocol.Kind.Connected:
                        _log($"freedv-reporter: connected to {_url.Host} as {station.Callsign}");
                        break;
                    case FreeDvReporterProtocol.Kind.Event when incoming.Name == "connection_successful":
                        connected = true;
                        _fullyConnected = true;
                        SetStatus(ConnectionStatus.Connected);
                        // Our state, as freedv-backend sends it once fully
                        // connected.
                        Write(socket, FreeDvReporterProtocol.FrequencyChange(_frequencyHz ?? 0));
                        Write(socket, FreeDvReporterProtocol.TransmitReport(_transmitting));
                        Write(socket, FreeDvReporterProtocol.Message(Message));
                        break;
                    case FreeDvReporterProtocol.Kind.Event:
                        if (_table.Apply(incoming.Name, incoming.Payload))
                        {
                            SchedulePublish();
                        }
                        break;
                    case FreeDvReporterProtocol.Kind.ConnectError:
                        return (incoming.Name, connected);
                    case FreeDvReporterProtocol.Kind.Close:
                    case FreeDvReporterProtocol.Kind.Disconnected:
                        return (Loc.S("freeDvReporter.closedByServer"), connected);
                }
            }
            return (Loc.S("freeDvReporter.closedByServer"), connected);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            return (Loc.S("freeDvReporter.noAnswer"), connected);
        }
        catch (Exception ex)
        {
            return (ex.InnerException?.Message ?? ex.Message, connected);
        }
    }

    private void Send(string frame)
    {
        if (_fullyConnected && _socket is { } socket)
        {
            Write(socket, frame);
        }
    }

    /// One send at a time, in order (a ClientWebSocket allows no more).
    private void Write(ClientWebSocket socket, string frame) => _sending = WriteAfterAsync(_sending, socket, frame);

    private async Task WriteAfterAsync(Task previous, ClientWebSocket socket, string frame)
    {
        try
        {
            await previous;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await socket.SendAsync(Encoding.UTF8.GetBytes(frame).AsMemory(), WebSocketMessageType.Text,
                endOfMessage: true, timeout.Token);
        }
        catch (Exception ex)
        {
            _log($"freedv-reporter: send failed: {ex.Message}");
        }
    }

    private void SetStatus(ConnectionStatus status)
    {
        if (status == Status && status != ConnectionStatus.Retrying)
        {
            return;
        }
        Status = status;
        Changed?.Invoke();
    }

    // Station list

    /// A bulk update or a busy band can bring dozens of events at once: the
    /// list is republished at most twice a second.
    private void SchedulePublish()
    {
        if (_publishScheduled)
        {
            return;
        }
        _publishScheduled = true;
        _ = PublishLaterAsync();
    }

    private async Task PublishLaterAsync()
    {
        await Task.Delay(PublishDelay);
        _publishScheduled = false;
        Stations = _table.Sorted();
        StationsChanged?.Invoke();
    }

    private void ClearStations()
    {
        _table.Clear();
        if (Stations.Count > 0)
        {
            Stations = [];
            StationsChanged?.Invoke();
        }
    }
}

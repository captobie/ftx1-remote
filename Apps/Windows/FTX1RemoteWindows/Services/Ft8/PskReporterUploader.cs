using System.Net.Sockets;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;

namespace FTX1RemoteWindows.Services.Ft8;

/// Uploads the FT8 and FT4 windows' decodes to PSK Reporter (their "Upload
/// to PSK Reporter" checkbox — one setting, shared by both windows) — the
/// Mac's PSKReporterUploader, packets built by <see cref="PskReporterPacket"/>.
/// Runs only while at least one of those windows decodes
/// (<see cref="Start"/>/<see cref="Stop"/>) *and* the checkbox is on; the
/// checkbox is remembered, off by default.
///
/// Follows pskdev.html's rules: a callsign at most once per hour per band
/// (and mode — an FT4 and an FT8 reception are separate reports) unless it
/// newly carries a grid; one datagram every 5 minutes, timed from when
/// uploading started plus random jitter (never aligned to the clock), or
/// sooner once a full datagram's worth is waiting; the record descriptors in
/// the first 3 datagrams of a connection and hourly after; one UDP flow (one
/// source port) kept for the whole app session.
///
/// UI thread only.
public sealed class PskReporterUploader : IDisposable
{
    public static readonly TimeSpan FlushInterval = TimeSpan.FromMinutes(5);
    public const double FlushJitterSeconds = 30;
    public static readonly TimeSpan RepeatWindow = TimeSpan.FromHours(1);
    public static readonly TimeSpan TemplateInterval = TimeSpan.FromHours(1);
    public const int TemplatePackets = 3;

    private readonly DispatcherQueueTimer _flushTimer;
    /// The modes whose windows are decoding; running while non-empty.
    private readonly HashSet<Ft8Mode> _activeModes = [];
    private readonly List<PskReporterPacket.Report> _pending = [];
    /// "CALL band mode" → when last queued, and whether that one had a grid.
    private readonly Dictionary<string, (DateTimeOffset At, bool HadGrid)> _lastQueued = [];
    private readonly uint _domainId = (uint)Random.Shared.NextInt64(1, uint.MaxValue);

    private UdpClient? _client;
    private int _datagramsOnConnection;
    private DateTimeOffset? _lastTemplatesAt;
    private uint _sequence;
    private bool _enabled;

    /// Last time PTT changed either way, so a slot the rig transmitted in
    /// can be skipped (its audio isn't off-air reception).
    private bool _isTransmitting;
    private DateTimeOffset? _lastPttChangeAt;

    public int PendingCount => _pending.Count;
    public DateTimeOffset? LastUploadAt { get; private set; }
    public DateTimeOffset? NextUploadAt { get; private set; }
    public int SentThisSession { get; private set; }
    public string? LastError { get; private set; }

    /// Status changed (UI thread).
    public event Action? Changed;

    public PskReporterUploader(DispatcherQueue dispatcher)
    {
        _flushTimer = dispatcher.CreateTimer();
        _flushTimer.IsRepeating = false;
        _flushTimer.Tick += (_, _) =>
        {
            Flush();
            ScheduleFlush();
        };
        _enabled = AppSettings.Ft8.PskReporterEnabled;
    }

    public void Dispose()
    {
        _flushTimer.Stop();
        Flush();
        CloseConnection();
    }

    /// Callsign and grid from Settings → Station; nothing is sent without both.
    public static bool StationIsSet =>
        !string.IsNullOrWhiteSpace(AppSettings.Callsign) && !string.IsNullOrWhiteSpace(AppSettings.GridSquare);

    public bool IsRunning => _activeModes.Count > 0;

    public bool IsEnabled
    {
        get => _enabled;
        set
        {
            if (value == _enabled)
            {
                return;
            }
            _enabled = value;
            AppSettings.Ft8.PskReporterEnabled = value;
            AppSettings.SaveFt8();
            AppLog.Write($"pskreporter: upload {(value ? "on" : "off")}");
            if (value)
            {
                ScheduleFlush();
            }
            else
            {
                // The connection stays: closing it right after a send can
                // drop that datagram, and the same source port is wanted for
                // the rest of the session anyway.
                Flush();
                _flushTimer.Stop();
                NextUploadAt = null;
            }
            Changed?.Invoke();
        }
    }

    public void Start(Ft8Mode mode)
    {
        var wasRunning = IsRunning;
        _activeModes.Add(mode);
        if (!wasRunning && _enabled)
        {
            ScheduleFlush();
        }
    }

    /// The last FT8/FT4 window closed (or the app quits): what's queued goes
    /// out now.
    public void Stop(Ft8Mode mode)
    {
        if (!_activeModes.Remove(mode) || IsRunning)
        {
            return;
        }
        _flushTimer.Stop();
        NextUploadAt = null;
        Flush();
        Changed?.Invoke();
    }

    /// PTT changed (MainWindow calls this on every rig-state update).
    public void NotePtt(bool transmitting)
    {
        if (transmitting == _isTransmitting)
        {
            return;
        }
        _lastPttChangeAt = DateTimeOffset.UtcNow;
        _isTransmitting = transmitting;
    }

    /// One decode cycle's spots, all from the slot starting at the first one's time.
    public void Enqueue(IReadOnlyList<Ft8Spot> spots)
    {
        if (!IsRunning || !_enabled || !StationIsSet || spots.Count == 0)
        {
            return;
        }
        var slotStart = spots[0].UtcTimestamp;
        if (_isTransmitting || (_lastPttChangeAt is { } changed && changed >= slotStart))
        {
            AppLog.Write($"pskreporter: slot {slotStart:HH:mm:ss}: rig transmitted, not reported");
            return;
        }
        var myCall = AppSettings.Callsign.Trim().ToUpperInvariant();
        foreach (var spot in spots)
        {
            if (PskReporterReports.From(spot.DialFrequencyHz, spot.AbsoluteFrequencyHz, spot.SpottedCallsign, spot.SpottedGrid, spot.Mode, spot.UtcTimestamp) is not { } report
                || report.Callsign == myCall)
            {
                continue;
            }
            var band = BandPlan.BandContaining(report.FrequencyHz)?.Name ?? $"{report.FrequencyHz / 1_000_000}MHz";
            var key = $"{report.Callsign} {band} {report.Mode}";
            if (_lastQueued.TryGetValue(key, out var previous)
                && report.Time - previous.At < RepeatWindow
                && (previous.HadGrid || report.Locator is null))
            {
                continue;
            }
            _lastQueued[key] = (report.Time, report.Locator is not null);
            _pending.Add(report);
        }
        var now = DateTimeOffset.UtcNow;
        foreach (var stale in _lastQueued.Where(p => now - p.Value.At >= RepeatWindow).Select(p => p.Key).ToList())
        {
            _lastQueued.Remove(stale);
        }

        // A full datagram waiting goes out now rather than at the timer.
        if (Encode(NeedsTemplates).Count > 1)
        {
            Flush();
        }
        Changed?.Invoke();
    }

    private bool NeedsTemplates =>
        _datagramsOnConnection < TemplatePackets
        || _lastTemplatesAt is not { } at
        || DateTimeOffset.UtcNow - at >= TemplateInterval;

    private static PskReporterPacket.Receiver Receiver()
    {
        var version = typeof(PskReporterUploader).Assembly.GetName().Version;
        return new PskReporterPacket.Receiver(
            AppSettings.Callsign.Trim().ToUpperInvariant(),
            AppSettings.GridSquare.Trim(),
            $"FTX1Remote Windows {version?.ToString(3) ?? "?"}");
    }

    private List<PskReporterPacket.Datagram> Encode(bool includeTemplates) =>
        PskReporterPacket.Encode(Receiver(), _pending, includeTemplates, _sequence, _domainId, DateTimeOffset.UtcNow);

    private void ScheduleFlush()
    {
        if (!IsRunning || !_enabled)
        {
            return;
        }
        var delay = FlushInterval + TimeSpan.FromSeconds(Random.Shared.NextDouble() * FlushJitterSeconds);
        NextUploadAt = DateTimeOffset.Now + delay;
        _flushTimer.Interval = delay;
        _flushTimer.Start();
        Changed?.Invoke();
    }

    private void Flush()
    {
        if (_pending.Count == 0)
        {
            return;
        }
        if (!StationIsSet)
        {
            _pending.Clear();
            return;
        }
        try
        {
            var client = OpenConnection();
            var reports = 0;
            // Each datagram decides templates for itself, so a split batch on
            // a fresh connection still carries them in its first three.
            while (_pending.Count > 0)
            {
                var withTemplates = NeedsTemplates;
                if (Encode(withTemplates).FirstOrDefault() is not { } datagram)
                {
                    break;
                }
                client.Send(datagram.Data, datagram.Data.Length);
                AppLog.Write($"pskreporter: sent {datagram.ReportCount} report(s), {datagram.Data.Length} bytes, seq {_sequence}, templates {withTemplates}");
                if (withTemplates)
                {
                    _lastTemplatesAt = DateTimeOffset.UtcNow;
                }
                _datagramsOnConnection++;
                unchecked { _sequence += (uint)datagram.ReportCount; }
                _pending.RemoveRange(0, datagram.ReportCount);
                reports += datagram.ReportCount;
            }
            SentThisSession += reports;
            LastUploadAt = DateTimeOffset.Now;
            LastError = null;
        }
        catch (Exception ex)
        {
            SendFailed(ex);
        }
        Changed?.Invoke();
    }

    private UdpClient OpenConnection()
    {
        if (_client is { } existing)
        {
            return existing;
        }
        var host = PskReporterPacket.Host;
#if DEBUG
        if (Environment.GetEnvironmentVariable("FTX1REMOTE_PSKREPORTER_HOST") is { Length: > 0 } overrideHost)
        {
            host = overrideHost;
        }
#endif
        var client = new UdpClient();
        client.Connect(host, PskReporterPacket.Port);
        _client = client;
        _datagramsOnConnection = 0;
        AppLog.Write($"pskreporter: connection to {host}:{PskReporterPacket.Port}");
        return client;
    }

    /// UDP gets no reply, so this only sees local failures (no route, DNS).
    /// The connection is dropped; the next upload opens a new one, with the
    /// descriptors again since the source port changes.
    private void SendFailed(Exception error)
    {
        AppLog.Write($"pskreporter: upload failed: {error.Message}");
        LastError = error.Message;
        CloseConnection();
    }

    private void CloseConnection()
    {
        _client?.Dispose();
        _client = null;
        _datagramsOnConnection = 0;
    }
}

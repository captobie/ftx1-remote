using System.Collections.Concurrent;
using FTX1RemoteWindows.Services.Digi;

namespace FTX1RemoteWindows.Services.Ft8;

/// One decoded message with where and when it came from (the Mac's
/// FT8DecodeCoordinator.Spot).
public sealed record Ft8CoordinatorSpot(DateTimeOffset UtcTimestamp, long DialFrequencyHz, CwAudioChannel Channel, Ft8RawMessage Message);

public enum Ft8CycleStatus
{
    Idle,
    Accumulating,
    Decoding,
}

/// Coordinates FT8 or FT4 decoding of live audio (one instance per mode):
/// resamples the taps down to 12000 Hz, accumulates them into exact
/// <see cref="Ft8Decoder.BlockSize"/>-sized blocks, and runs one decode pass
/// per UTC slot boundary (15 s FT8, 7.5 s FT4) — the Mac's
/// FT8DecodeCoordinator. Assumes the PC's clock is NTP-synced, as WSJT-X does.
///
/// Decoding only runs between <see cref="Start"/> and <see cref="Stop"/>, the
/// window's lifetime: FT8 has no single frequency to gate on the way APRS
/// does. <see cref="Ingest"/> drops audio cheaply when not running, and audio
/// from any source but the selected one (MAIN, SUB or MyKiwiSDR).
///
/// All decode work happens on one worker thread (CPU-bound LDPC, not for the
/// audio thread or the UI); results go to <c>post</c> (the UI thread).
public sealed class Ft8DecodeCoordinator : IDisposable
{
    /// Where decodes (and status changes) are delivered: the UI thread.
    private readonly Action<Action> _post;
    private readonly BlockingCollection<Action> _queue = new(boundedCapacity: 512);
    private readonly Thread _worker;
    private readonly Timer _timer;
    private readonly DigiResampler _resampler = new(TargetSampleRate);

    public const int TargetSampleRate = 12000;
    /// Ticks well inside the slot period so a boundary crossing is never
    /// missed by more than this margin.
    private static readonly TimeSpan TickInterval = TimeSpan.FromMilliseconds(500);

    public Ft8Mode Mode { get; }

    /// Spots of one finished slot (UI thread).
    public event Action<IReadOnlyList<Ft8CoordinatorSpot>>? SpotsDecoded;
    public event Action<Ft8CycleStatus>? CycleStatusChanged;

    /// The dial frequency of a source: MAIN's or SUB's, or the MyKiwiSDR
    /// window's. Called on the worker thread when a slot begins.
    public Func<CwAudioChannel, long> DialFrequencyProvider { get; set; } = _ => 0;

    // Read by the audio thread.
    private volatile bool _running;
    private volatile CwAudioChannel _channel = CwAudioChannel.Main;

    // Worker thread only.
    private Ft8Decoder? _decoder;
    private readonly List<float> _pending = [];
    private double? _lastSlotPhase;
    private DateTimeOffset? _slotStart;
    private long? _slotDialHz;

    public Ft8DecodeCoordinator(Ft8Mode mode, Action<Action> post)
    {
        Mode = mode;
        _post = post;
        _worker = new Thread(Run) { IsBackground = true, Name = $"{mode.Name()} decoder" };
        _worker.Start();
        _timer = new Timer(_ => TryQueue(CheckSlotBoundary), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    public void Dispose()
    {
        _running = false;
        _timer.Dispose();
        _queue.CompleteAdding();
    }

    public void Start() => Queue(StartOnWorker);

    public void Stop() => Queue(StopOnWorker);

    /// Switches the decoded source. The slot in progress starts over: its
    /// audio so far came from the old source (and maybe another rate), and
    /// its spots would carry the old source's dial frequency.
    public void SetChannel(CwAudioChannel channel)
    {
        Queue(() =>
        {
            if (_channel == channel)
            {
                return;
            }
            _channel = channel;
            if (_running)
            {
                _resampler.Reset();
                BeginSlot(DateTimeOffset.UtcNow);
                AppLog.Write($"{Mode.Name().ToLowerInvariant()}: source now {channel}");
            }
        });
    }

    /// Cheap from the caller's side: the array is queued as it is (callers
    /// hand over a fresh array per chunk) and everything else happens on the
    /// worker. Dropped when not running or when <paramref name="channel"/>
    /// isn't the selected source.
    public void Ingest(float[] samples, int sampleRate, CwAudioChannel channel)
    {
        if (!_running || channel != _channel || sampleRate <= 0)
        {
            return;
        }
        TryQueue(() =>
        {
            if (_running && channel == _channel)
            {
                IngestOnWorker(samples, sampleRate);
            }
        });
    }

    private void Run()
    {
        foreach (var work in _queue.GetConsumingEnumerable())
        {
            try
            {
                work();
            }
            catch (Exception ex)
            {
                AppLog.Write($"{Mode.Name().ToLowerInvariant()}: decoder error: {ex.Message}");
            }
        }
        _decoder?.Dispose();
    }

    private void Queue(Action work)
    {
        try
        {
            _queue.Add(work);
        }
        catch (InvalidOperationException)
        {
            // Disposed.
        }
    }

    /// For audio and timer ticks: dropped if the worker is badly behind.
    private void TryQueue(Action work)
    {
        try
        {
            _queue.TryAdd(work);
        }
        catch (InvalidOperationException)
        {
        }
    }

    private void StartOnWorker()
    {
        if (_running)
        {
            return;
        }
        _running = true;
        _resampler.Reset();
        BeginSlot(DateTimeOffset.UtcNow);
        _timer.Change(TickInterval, TickInterval);
        Notify(Ft8CycleStatus.Accumulating);
        AppLog.Write($"{Mode.Name().ToLowerInvariant()}: started");
    }

    private void StopOnWorker()
    {
        if (!_running)
        {
            return;
        }
        _running = false;
        _timer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        _pending.Clear();
        _decoder?.Dispose();
        _decoder = null;
        _slotStart = null;
        _slotDialHz = null;
        _lastSlotPhase = null;
        Notify(Ft8CycleStatus.Idle);
        AppLog.Write($"{Mode.Name().ToLowerInvariant()}: stopped");
    }

    private double Phase(DateTimeOffset now) =>
        (now.ToUnixTimeMilliseconds() / 1000.0) % Mode.SlotSeconds();

    private void CheckSlotBoundary()
    {
        if (!_running)
        {
            return;
        }
        var now = DateTimeOffset.UtcNow;
        var phase = Phase(now);
        var last = _lastSlotPhase;
        _lastSlotPhase = phase;
        // A boundary was crossed since the last tick when the phase wraps
        // back down (14.7 s → 0.2 s for FT8, 7.3 s → 0.1 s for FT4).
        if (last is { } previous && phase < previous)
        {
            FinishSlotAndStartNext(now);
        }
    }

    /// A fresh <see cref="Ft8Decoder"/> per slot rather than a reset one.
    private void BeginSlot(DateTimeOffset now)
    {
        var phase = Phase(now);
        _slotStart = now - TimeSpan.FromSeconds(phase);
        _slotDialHz = DialFrequencyProvider(_channel);
        _decoder?.Dispose();
        _decoder = new Ft8Decoder(TargetSampleRate, Mode);
        _pending.Clear();
        _lastSlotPhase = phase;
    }

    private void FinishSlotAndStartNext(DateTimeOffset now)
    {
        Notify(Ft8CycleStatus.Decoding);
        try
        {
            if (_decoder is { } decoder && _slotStart is { } slotStart && _slotDialHz is { } dialHz)
            {
                var messages = decoder.Decode();
                AppLog.Write($"{Mode.Name().ToLowerInvariant()}: slot {slotStart:HH:mm:ss}: decoded {messages.Count} message(s)");
                if (messages.Count > 0)
                {
                    var channel = _channel;
                    var spots = messages.Select(m => new Ft8CoordinatorSpot(slotStart, dialHz, channel, m)).ToList();
                    _post(() => SpotsDecoded?.Invoke(spots));
                }
            }
        }
        finally
        {
            BeginSlot(now);
            Notify(Ft8CycleStatus.Accumulating);
        }
    }

    private void IngestOnWorker(float[] samples, int sampleRate)
    {
        if (_decoder is not { } decoder)
        {
            return;
        }
        var resampled = _resampler.Convert(samples, sampleRate);
        if (resampled.Length == 0)
        {
            return;
        }
        _pending.AddRange(resampled);
        var size = decoder.BlockSize;
        var consumed = 0;
        while (_pending.Count - consumed >= size)
        {
            decoder.Process(_pending.GetRange(consumed, size).ToArray());
            consumed += size;
        }
        if (consumed > 0)
        {
            _pending.RemoveRange(0, consumed);
        }
    }

    private void Notify(Ft8CycleStatus status) => _post(() => CycleStatusChanged?.Invoke(status));
}

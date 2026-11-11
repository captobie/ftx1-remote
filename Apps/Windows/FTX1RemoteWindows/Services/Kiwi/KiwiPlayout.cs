namespace FTX1RemoteWindows.Services;

/// Decides how to keep the MyKiwiSDR window's playback queue near its target
/// — port of the Mac's KiwiPlayoutController. Measured there over 36 minutes:
/// the queue grew ~5 ppm (the Kiwi's clock against the output device, ~19 ms
/// an hour), and one ~2 s network stall left 2 s of extra latency for the rest
/// of the session. So:
///  - slow drift: once the 10 s average is <see cref="Deadband"/> off target,
///    one small splice per <see cref="CorrectionInterval"/> until it is within
///    <see cref="Settled"/>;
///  - a backlog: when even the queue's lowest level in the last 0.5 s is
///    <see cref="BacklogExcess"/> over target, audio that hasn't been queued
///    yet is discarded to bring it back in one step;
///  - a dry queue: the audio resumes behind "target" seconds of silence.
/// "now" is seconds on any monotonic clock.
public sealed class KiwiPlayoutController
{
    public abstract record PlayoutAction
    {
        public sealed record None : PlayoutAction;
        /// Take a little out (+1) or add a little (−1).
        public sealed record Splice(int Direction) : PlayoutAction;
        public sealed record Discard(double Seconds) : PlayoutAction;
        public sealed record Pad(double Seconds) : PlayoutAction;
    }

    public const double Deadband = 0.03;
    public const double Settled = 0.01;
    public const double BacklogExcess = 0.3;
    public const double CorrectionInterval = 0.5;
    private const double LongWindow = 10;
    private const double FloorWindow = 0.5;

    public double Target { get; }

    private readonly List<(double Time, double Buffered)> _history = [];
    private double? _firstTime;
    private double _lastCorrection = double.NegativeInfinity;
    private bool _correcting;

    public KiwiPlayoutController(double target) => Target = target;

    /// "queued": seconds queued just before this chunk is added. The level
    /// compared with the target includes the chunk, so it means the same as
    /// the warm-up (the target queued once a chunk has just gone in).
    public PlayoutAction Observe(double queued, double chunkSeconds, double now)
    {
        if (queued <= 0.001 && _firstTime is not null)
        {
            Reset();
            return new PlayoutAction.Pad(Math.Max(Target - chunkSeconds, 0));
        }
        var buffered = queued + chunkSeconds;
        _firstTime ??= now;
        _history.Add((now, buffered));
        var stale = _history.FindIndex(h => now - h.Time <= LongWindow);
        if (stale > 0)
        {
            _history.RemoveRange(0, stale);
        }
        if (now - _firstTime.Value < FloorWindow)
        {
            return new PlayoutAction.None();
        }

        var floor = _history.Where(h => now - h.Time <= FloorWindow).Select(h => h.Buffered).DefaultIfEmpty(buffered).Min();
        if (floor - Target > BacklogExcess)
        {
            Reset();
            return new PlayoutAction.Discard(floor - Target);
        }

        if (now - _firstTime.Value < LongWindow || now - _lastCorrection < CorrectionInterval)
        {
            return new PlayoutAction.None();
        }
        var error = _history.Average(h => h.Buffered) - Target;
        if (Math.Abs(error) >= Deadband) { _correcting = true; }
        if (Math.Abs(error) <= Settled) { _correcting = false; }
        if (!_correcting)
        {
            return new PlayoutAction.None();
        }
        _lastCorrection = now;
        return new PlayoutAction.Splice(error > 0 ? 1 : -1);
    }

    /// A splice took "seconds" out (negative: added them): history shows the
    /// queue as it would have been, so the average doesn't lag.
    public void Applied(double seconds)
    {
        for (var i = 0; i < _history.Count; i++)
        {
            _history[i] = (_history[i].Time, _history[i].Buffered - seconds);
        }
    }

    /// After a discard finishes, or anything else that moves the queue.
    public void Reset()
    {
        _history.Clear();
        _firstTime = null;
        _correcting = false;
    }
}

/// Applies <see cref="KiwiPlayoutController"/>'s decisions to the Kiwi's
/// samples on their way to the player (only there: decoders and recordings get
/// every sample as it came) — the Mac's KiwiPlayoutAdjuster.
///
/// A splice crossfades a few milliseconds of the audio against itself about a
/// millisecond later or earlier, choosing the offset where the two line up
/// best, so a steady CW tone keeps its phase. A discard fades out the chunk in
/// hand and in on the first one kept; a pad fades in after its silence.
public sealed class KiwiPlayoutAdjuster
{
    /// Crossfade/fade length (8 ms at 12 kHz), and the offsets tried.
    internal const int FadeSamples = 96;
    internal const int MinOffset = 6;
    internal const int MaxOffset = 30;

    public int Splices { get; private set; }
    public double DiscardedSeconds { get; private set; }
    public double PaddedSeconds { get; private set; }

    private readonly double _sampleRate;
    private readonly KiwiPlayoutController _controller;
    private int _discardRemaining;
    private bool _fadeInNext;

    public KiwiPlayoutAdjuster(double sampleRate, double targetSeconds)
    {
        _sampleRate = sampleRate;
        _controller = new KiwiPlayoutController(targetSeconds);
    }

    /// "bufferedSeconds": what's queued now, null before playback has started
    /// (the samples go through untouched then).
    public short[] Process(short[] samples, double? bufferedSeconds, double now)
    {
        if (samples.Length == 0)
        {
            return samples;
        }
        if (_discardRemaining > 0)
        {
            _discardRemaining -= samples.Length;
            if (_discardRemaining <= 0)
            {
                _discardRemaining = 0;
                _controller.Reset();
                _fadeInNext = true;
            }
            return [];
        }
        var output = (short[])samples.Clone();
        if (_fadeInNext)
        {
            _fadeInNext = false;
            FadeIn(output);
        }
        if (bufferedSeconds is not { } buffered)
        {
            return output;
        }
        switch (_controller.Observe(buffered, samples.Length / _sampleRate, now))
        {
            case KiwiPlayoutController.PlayoutAction.Splice splice:
                if (Spliced(output, splice.Direction) is not { } spliced)
                {
                    return output;
                }
                Splices++;
                _controller.Applied((output.Length - spliced.Length) / _sampleRate);
                return spliced;
            case KiwiPlayoutController.PlayoutAction.Discard discard:
                DiscardedSeconds += discard.Seconds;
                _discardRemaining = (int)(discard.Seconds * _sampleRate);
                FadeOut(output);
                return output;
            case KiwiPlayoutController.PlayoutAction.Pad pad:
                PaddedSeconds += pad.Seconds;
                FadeIn(output);
                var silence = new short[(int)(pad.Seconds * _sampleRate)];
                return [.. silence, .. output];
            default:
                return output;
        }
    }

    /// "x" a little shorter (direction +1) or longer (−1), or null if the
    /// chunk is too short to splice.
    internal static short[]? Spliced(short[] x, int direction)
    {
        const int start = MaxOffset;
        if (x.Length < start + FadeSamples + MaxOffset)
        {
            return null;
        }
        // The offset where the crossfaded stretches match best.
        var best = MinOffset;
        var bestScore = double.NegativeInfinity;
        for (var offset = MinOffset; offset <= MaxOffset; offset++)
        {
            var shift = direction * offset;
            double dot = 0, energyA = 1, energyB = 1;
            for (var k = 0; k < FadeSamples; k++)
            {
                double a = x[start + k], b = x[start + shift + k];
                dot += a * b;
                energyA += a * a;
                energyB += b * b;
            }
            var score = dot / Math.Sqrt(energyA * energyB);
            if (score > bestScore)
            {
                bestScore = score;
                best = offset;
            }
        }
        var chosen = direction * best;
        var output = new List<short>(x.Length - chosen);
        output.AddRange(x.Take(start));
        for (var k = 0; k < FadeSamples; k++)
        {
            var w = (k + 0.5) / FadeSamples;
            var blended = x[start + k] * (1 - w) + x[start + chosen + k] * w;
            output.Add((short)Math.Round(blended, MidpointRounding.AwayFromZero));
        }
        output.AddRange(x.Skip(start + chosen + FadeSamples));
        return output.ToArray();
    }

    private static void FadeIn(short[] x)
    {
        for (var k = 0; k < Math.Min(FadeSamples, x.Length); k++)
        {
            x[k] = (short)Math.Round(x[k] * (k + 0.5) / FadeSamples, MidpointRounding.AwayFromZero);
        }
    }

    private static void FadeOut(short[] x)
    {
        var count = Math.Min(FadeSamples, x.Length);
        for (var k = 0; k < count; k++)
        {
            var index = x.Length - 1 - k;
            x[index] = (short)Math.Round(x[index] * (k + 0.5) / FadeSamples, MidpointRounding.AwayFromZero);
        }
    }
}

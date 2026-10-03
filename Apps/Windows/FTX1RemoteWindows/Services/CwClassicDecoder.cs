using System.Text;

namespace FTX1RemoteWindows.Services;

// The classic CW decoder (tone detection, adaptive keying threshold, Morse
// timing rules) — a straight translation of CWKit's DSP/ and Morse/ files
// (captobie/cwdecode, Sources/CWKit: Goertzel.swift, ToneDetector.swift,
// FrequencyTracker.swift, MorseCode.swift, MorseDecoder.swift,
// DecoderPipeline.swift), which stay the source of truth: copy any decoder
// fix made there. Same constants, same arithmetic (Float where CWKit uses
// Float), so both apps decode the same audio the same way. The neural
// decoder (CWKit's Neural/, a Core ML model) isn't ported yet.

/// CWKit's PipelineSettings (the classic decoder's part of it).
public sealed record CwPipelineSettings(
    double ToneFrequency = 700,
    bool AutoTune = true,
    /// Minimum signal-to-noise ratio before the key is allowed to close.
    double SquelchDb = 12,
    double InitialWpm = 20);

/// CWKit's PipelineOutput.
public readonly record struct CwPipelineOutput(
    /// Newly committed text.
    string Text,
    bool KeyDown,
    /// Current tone level between the noise floor (0) and the signal peak (1).
    double SignalLevel,
    double SnrDb,
    double ToneFrequency,
    double Wpm,
    /// Dits and dahs of the character being received, as "." and "-".
    string PendingSymbols);

/// Single-bin DFT, much cheaper than an FFT when only a few frequencies matter.
internal static class Goertzel
{
    public static float Coefficient(double frequency, double sampleRate) =>
        (float)(2 * Math.Cos(2 * Math.PI * frequency / sampleRate));

    public static float[] HannWindow(int count)
    {
        if (count <= 1)
        {
            return [1];
        }
        var window = new float[count];
        for (var i = 0; i < count; i++)
        {
            window[i] = (float)(0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (count - 1)));
        }
        return window;
    }

    /// Squared magnitude of `samples` at the frequency `coefficient` was
    /// built for. `window`, when given, must be the same length as `samples`.
    public static float Power(ReadOnlySpan<float> samples, ReadOnlySpan<float> window, float coefficient)
    {
        float s1 = 0, s2 = 0;
        if (!window.IsEmpty)
        {
            for (var i = 0; i < samples.Length; i++)
            {
                var s0 = samples[i] * window[i] + coefficient * s1 - s2;
                s2 = s1;
                s1 = s0;
            }
        }
        else
        {
            foreach (var sample in samples)
            {
                var s0 = sample + coefficient * s1 - s2;
                s2 = s1;
                s1 = s0;
            }
        }
        return s1 * s1 + s2 * s2 - coefficient * s1 * s2;
    }
}

/// Measures the power of a single tone over short overlapping windows.
internal sealed class ToneDetector
{
    public double SampleRate { get; }
    public int WindowSize { get; }
    public int HopSize { get; }

    private double _frequency;
    private float _coefficient;
    private readonly float[] _window;
    private readonly float _normalization;
    private float[] _buffer = new float[4096];
    private int _count;

    /// A 12 ms window gives roughly 170 Hz of bandwidth, narrow enough to
    /// reject most neighbouring signals but short enough for 40+ WPM code.
    public ToneDetector(double sampleRate, double frequency, double windowDuration = 0.012, double hopDuration = 0.004)
    {
        SampleRate = sampleRate;
        WindowSize = Math.Max(16, (int)(sampleRate * windowDuration));
        HopSize = Math.Max(1, (int)(sampleRate * hopDuration));
        Frequency = frequency;
        _window = Goertzel.HannWindow(WindowSize);
        // Scale so a full-scale sine of amplitude A reads as A².
        var gain = _window.Sum() / 2;
        _normalization = 1 / (gain * gain);
    }

    public double Frequency
    {
        get => _frequency;
        set
        {
            _frequency = value;
            _coefficient = Goertzel.Coefficient(value, SampleRate);
        }
    }

    public double HopDuration => HopSize / SampleRate;

    /// Appends samples and returns the tone power, in dBFS, for every hop completed.
    public List<double> Process(float[] samples)
    {
        if (_count + samples.Length > _buffer.Length)
        {
            Array.Resize(ref _buffer, Math.Max(_buffer.Length * 2, _count + samples.Length));
        }
        samples.CopyTo(_buffer, _count);
        _count += samples.Length;

        var levels = new List<double>();
        var start = 0;
        while (_count - start >= WindowSize)
        {
            var power = Goertzel.Power(_buffer.AsSpan(start, WindowSize), _window, _coefficient) * _normalization;
            levels.Add(10 * Math.Log10(power + 1e-12));
            start += HopSize;
        }
        Array.Copy(_buffer, start, _buffer, 0, _count - start);
        _count -= start;
        return levels;
    }
}

/// Finds the strongest tone in the CW audio passband so the detector can follow it.
public sealed class FrequencyTracker
{
    public const double SearchMin = 300;
    public const double SearchMax = 1200;
    private const double Step = 5;
    private const float MinimumPeakToMedian = 30;  // about 15 dB

    public double Frequency { get; private set; }

    private readonly int _windowSize;
    private readonly int _scanInterval;
    private readonly float[] _window;
    private readonly (double Frequency, float Coefficient)[] _bins;
    private readonly float[] _ring;
    private readonly float[] _ordered;
    private readonly float[] _powers;
    private readonly float[] _sorted;
    private int _writeIndex;
    private int _filled;
    private int _samplesSinceScan;
    private double? _candidate;
    private int _candidateHits;

    public FrequencyTracker(double sampleRate, double frequency)
    {
        Frequency = frequency;
        _windowSize = (int)(sampleRate * 0.1);
        _scanInterval = (int)(sampleRate * 0.25);
        _window = Goertzel.HannWindow(_windowSize);
        _ring = new float[_windowSize];
        _ordered = new float[_windowSize];
        var bins = new List<(double, float)>();
        for (var f = SearchMin; f <= SearchMax; f += Step)
        {
            bins.Add((f, Goertzel.Coefficient(f, sampleRate)));
        }
        _bins = [.. bins];
        _powers = new float[_bins.Length];
        _sorted = new float[_bins.Length];
    }

    /// Feeds audio and returns the new frequency whenever the estimate changes.
    public double? Process(float[] samples)
    {
        var changed = false;
        foreach (var sample in samples)
        {
            _ring[_writeIndex] = sample;
            _writeIndex = (_writeIndex + 1) % _windowSize;
            _filled = Math.Min(_filled + 1, _windowSize);
            _samplesSinceScan++;
            if (_samplesSinceScan >= _scanInterval && _filled == _windowSize)
            {
                _samplesSinceScan = 0;
                if (Scan())
                {
                    changed = true;
                }
            }
        }
        return changed ? Frequency : null;
    }

    public void Reset(double frequency)
    {
        Frequency = frequency;
        _candidate = null;
        _candidateHits = 0;
    }

    private bool Scan()
    {
        for (var i = 0; i < _windowSize; i++)
        {
            _ordered[i] = _ring[(_writeIndex + i) % _windowSize] * _window[i];
        }
        var peak = 0;
        for (var i = 0; i < _bins.Length; i++)
        {
            _powers[i] = Goertzel.Power(_ordered, ReadOnlySpan<float>.Empty, _bins[i].Coefficient);
            if (_powers[i] > _powers[peak])
            {
                peak = i;
            }
        }
        if (peak <= 0 || peak >= _powers.Length - 1)
        {
            return false;
        }
        _powers.CopyTo(_sorted, 0);
        Array.Sort(_sorted);
        var median = _sorted[_sorted.Length / 2];
        if (!(_powers[peak] > median * MinimumPeakToMedian))
        {
            return false;
        }

        // Parabolic interpolation on the log spectrum for sub-bin accuracy.
        var a = Math.Log(_powers[peak - 1] + 1e-20);
        var b = Math.Log(_powers[peak] + 1e-20);
        var c = Math.Log(_powers[peak + 1] + 1e-20);
        var denominator = a - 2 * b + c;
        var offset = denominator == 0 ? 0 : 0.5 * (a - c) / denominator;
        var measured = _bins[peak].Frequency + offset * Step;

        if (Math.Abs(measured - Frequency) <= 20)
        {
            Frequency += (measured - Frequency) * 0.5;
            _candidate = null;
            return true;
        }
        // A new signal must show up in two consecutive scans before we jump to it.
        if (_candidate is { } candidate && Math.Abs(measured - candidate) <= 20)
        {
            _candidateHits++;
        }
        else
        {
            _candidate = measured;
            _candidateHits = 1;
        }
        if (_candidateHits < 2)
        {
            return false;
        }
        Frequency = measured;
        _candidate = null;
        return true;
    }
}

/// International Morse code table. Patterns use "." for dit and "-" for dah.
internal static class MorseCode
{
    private static readonly Dictionary<string, string> Patterns = new()
    {
        [".-"] = "A", ["-..."] = "B", ["-.-."] = "C", ["-.."] = "D", ["."] = "E", ["..-."] = "F",
        ["--."] = "G", ["...."] = "H", [".."] = "I", [".---"] = "J", ["-.-"] = "K", [".-.."] = "L",
        ["--"] = "M", ["-."] = "N", ["---"] = "O", [".--."] = "P", ["--.-"] = "Q", [".-."] = "R",
        ["..."] = "S", ["-"] = "T", ["..-"] = "U", ["...-"] = "V", [".--"] = "W", ["-..-"] = "X",
        ["-.--"] = "Y", ["--.."] = "Z",

        ["-----"] = "0", [".----"] = "1", ["..---"] = "2", ["...--"] = "3", ["....-"] = "4",
        ["....."] = "5", ["-...."] = "6", ["--..."] = "7", ["---.."] = "8", ["----."] = "9",

        [".-.-.-"] = ".", ["--..--"] = ",", ["..--.."] = "?", [".----."] = "'", ["-.-.--"] = "!",
        ["-..-."] = "/", ["-.--."] = "(", ["-.--.-"] = ")", [".-..."] = "&", ["---..."] = ":",
        ["-.-.-."] = ";", ["-...-"] = "=", [".-.-."] = "+", ["-....-"] = "-", ["..--.-"] = "_",
        [".-..-."] = "\"", ["...-..-"] = "$", [".--.-."] = "@",

        // Prosigns without a single-character equivalent.
        ["...-.-"] = "<SK>", ["-.-.-"] = "<KA>", ["...-."] = "<SN>", ["........"] = "<HH>",
    };

    /// Shown for patterns that aren't in the table.
    public const string Unknown = "*";

    public static string Decode(string pattern) => Patterns.GetValueOrDefault(pattern, Unknown);
}

/// Turns key-down (mark) and key-up (space) durations into text.
///
/// Speed is tracked automatically: recent mark durations are split into a
/// dit cluster and a dah cluster, and the midpoint between them classifies
/// each mark. Marks are only classified when their character ends, so the
/// first character after a speed change benefits from what its own elements
/// taught the decoder. Letter and word gaps are learned the same way, which
/// handles Farnsworth spacing.
internal sealed class MorseDecoder
{
    public double DitDuration { get; private set; }
    public double DahDuration { get; private set; }

    private readonly List<double> _pendingMarks = [];
    private readonly List<double> _recentMarks = [];
    /// Letter and word gaps, in dot units.
    private readonly List<double> _recentGaps = [];
    private double _wordGapUnits = 5;
    private double _lastGap = double.PositiveInfinity;
    private bool _characterEnded = true;
    private bool _wordEnded = true;

    private const int HistoryLimit = 16;
    private const int MaxSymbolsPerCharacter = 10;

    public MorseDecoder(double initialWpm = 20)
    {
        var dit = 1.2 / initialWpm;
        DitDuration = dit;
        DahDuration = 3 * dit;
    }

    /// One dot unit. A dah is two units longer than a dit, which stays true
    /// even when the tone detector lengthens or shortens every mark by the
    /// same amount.
    public double Unit => (DahDuration - DitDuration) / 2;

    /// PARIS-standard words per minute for the current timing estimate.
    public double EstimatedWpm => 1.2 / Unit;

    /// Elements of the character currently being received, as "." and "-".
    public string PendingSymbols
    {
        get
        {
            var builder = new StringBuilder(_pendingMarks.Count);
            foreach (var mark in _pendingMarks)
            {
                builder.Append(Symbol(mark));
            }
            return builder.ToString();
        }
    }

    /// How much longer marks measure than they should, and so how much
    /// shorter the gaps measure.
    private double MarkBias => Math.Min(Math.Max(DitDuration - Unit, -0.4 * Unit), 0.4 * Unit);

    /// Records a completed key-down period.
    public void Mark(double duration)
    {
        if (!(duration > 0))
        {
            return;
        }
        if (double.IsFinite(_lastGap))
        {
            LearnGap(_lastGap + MarkBias);
        }
        _lastGap = double.PositiveInfinity;
        LearnMark(duration);

        if (_pendingMarks.Count < MaxSymbolsPerCharacter)
        {
            _pendingMarks.Add(duration);
        }
        _characterEnded = false;
        _wordEnded = false;
    }

    /// Reports the length of the current key-up period. Safe to call
    /// repeatedly while the gap grows; each character and word break is
    /// emitted only once.
    public string Space(double duration)
    {
        _lastGap = duration;
        var gap = duration + MarkBias;
        var output = "";
        if (!_characterEnded && gap >= 2 * Unit)
        {
            output += MorseCode.Decode(PendingSymbols);
            _pendingMarks.Clear();
            _characterEnded = true;
        }
        if (_characterEnded && !_wordEnded && gap >= _wordGapUnits * Unit)
        {
            output += " ";
            _wordEnded = true;
        }
        return output;
    }

    private char Symbol(double duration) => duration < (DitDuration + DahDuration) / 2 ? '.' : '-';

    private void LearnMark(double duration)
    {
        // Clamp outliers (a held key, a tuning carrier) so they can't wreck
        // the estimate, while still letting a genuine slowdown pull the
        // estimate upward over time.
        Append(Math.Min(duration, 8 * DitDuration), _recentMarks);
        if (_recentMarks.Count < 3)
        {
            return;
        }

        if (TwoClusters(_recentMarks, minimumRatio: 2) is { } clusters)
        {
            DitDuration = clusters.Short;
            DahDuration = clusters.Long;
        }
        else
        {
            // Only one kind of element seen recently: update whichever
            // estimate it's closer to.
            var mean = Mean(_recentMarks);
            if (Math.Abs(Math.Log(mean / DitDuration)) <= Math.Abs(Math.Log(mean / DahDuration)))
            {
                DitDuration = mean;
            }
            else
            {
                DahDuration = mean;
            }
        }
        DahDuration = Math.Min(Math.Max(DahDuration, 2 * DitDuration), 4.5 * DitDuration);
    }

    private void LearnGap(double gap)
    {
        var units = gap / Unit;
        // Only letter and word gaps; skip element gaps and long pauses between overs.
        if (!(units >= 2 && units < 3 * _wordGapUnits))
        {
            return;
        }
        Append(units, _recentGaps);
        if (_recentGaps.Count < 2)
        {
            return;
        }

        if (TwoClusters(_recentGaps, minimumRatio: 1.6) is { } clusters)
        {
            _wordGapUnits = (clusters.Short + clusters.Long) / 2;
        }
        else
        {
            // Probably all letter gaps; keep word breaks comfortably above them.
            _wordGapUnits = Math.Max(5, 1.4 * Mean(_recentGaps));
        }
    }

    private static void Append(double value, List<double> history)
    {
        history.Add(value);
        if (history.Count > HistoryLimit)
        {
            history.RemoveAt(0);
        }
    }

    private static double Mean(List<double> values) => values.Sum() / values.Count;

    /// Two-means clustering in log space. Returns null if the values don't
    /// form two distinct groups.
    private static (double Short, double Long)? TwoClusters(List<double> values, double minimumRatio)
    {
        if (values.Count == 0)
        {
            return null;
        }
        var shortMean = values.Min();
        var longMean = values.Max();
        if (!(shortMean > 0))
        {
            return null;
        }
        for (var iteration = 0; iteration < 8; iteration++)
        {
            var split = Math.Sqrt(shortMean * longMean);
            double shortSum = 0, longSum = 0;
            int shortCount = 0, longCount = 0;
            foreach (var value in values)
            {
                if (value < split)
                {
                    shortSum += value;
                    shortCount++;
                }
                else
                {
                    longSum += value;
                    longCount++;
                }
            }
            if (shortCount == 0 || longCount == 0)
            {
                return null;
            }
            shortMean = shortSum / shortCount;
            longMean = longSum / longCount;
        }
        return longMean / shortMean >= minimumRatio ? (shortMean, longMean) : null;
    }
}

/// Audio in, text out: tone detection → adaptive keying threshold → Morse
/// timing decoder. CWKit's DecoderPipeline.
///
/// Not thread-safe; confine each instance to one thread.
public sealed class CwClassicDecoder
{
    public double SampleRate { get; }
    private CwPipelineSettings _settings;

    private readonly ToneDetector _detector;
    private readonly FrequencyTracker _tracker;
    private readonly MorseDecoder _decoder;

    private double? _noisePower;
    private double _peakDb;
    private double _snrDb;
    private double _level;
    private bool _keyDown;
    private int _pendingHops;
    private double _pendingStart;
    private double _lastTransition;
    private int _hopCount;

    /// A state change must persist this many hops (8 ms) to count, which
    /// filters clicks and noise spikes.
    private const int DebounceHops = 2;

    public CwClassicDecoder(double sampleRate, CwPipelineSettings settings)
    {
        SampleRate = sampleRate;
        _settings = settings;
        _detector = new ToneDetector(sampleRate, settings.ToneFrequency);
        _tracker = new FrequencyTracker(sampleRate, settings.ToneFrequency);
        _decoder = new MorseDecoder(settings.InitialWpm);
    }

    public void Update(CwPipelineSettings newSettings)
    {
        if (!newSettings.AutoTune)
        {
            _detector.Frequency = newSettings.ToneFrequency;
        }
        else if (!_settings.AutoTune)
        {
            _tracker.Reset(_detector.Frequency);
        }
        _settings = newSettings;
    }

    public CwPipelineOutput Process(float[] samples)
    {
        if (_settings.AutoTune && _tracker.Process(samples) is { } frequency)
        {
            _detector.Frequency = frequency;
        }
        var text = new StringBuilder();
        foreach (var levelDb in _detector.Process(samples))
        {
            text.Append(HandleHop(levelDb));
        }
        return Output(text.ToString());
    }

    /// Flushes whatever is still in progress, e.g. at the end of a file or
    /// when listening stops.
    public CwPipelineOutput Finish()
    {
        var now = _hopCount * _detector.HopDuration;
        if (_keyDown)
        {
            _decoder.Mark(now - _lastTransition);
            _keyDown = false;
            _lastTransition = now;
        }
        _pendingHops = 0;
        return Output(_decoder.Space(double.PositiveInfinity));
    }

    private string HandleHop(double levelDb)
    {
        var now = _hopCount * _detector.HopDuration;
        _hopCount++;
        var hop = _detector.HopDuration;

        var power = Math.Pow(10, levelDb / 10);
        if (_noisePower is not { } noise)
        {
            _noisePower = power;
            _peakDb = levelDb;
            return "";
        }
        // Noise floor: the mean power of hops that look like noise (~300 ms
        // average). Anything else (marks, their edges, spikes) only nudges it
        // over ~5 s in dB, so the tone can't inflate it, yet a jump in band
        // noise can't hold the key down forever.
        var noiseDb = 10 * Math.Log10(noise + 1e-12);
        if (!_keyDown && _pendingHops == 0 && levelDb < noiseDb + 6)
        {
            noise += (power - noise) * Math.Min(1, hop / 0.3);
        }
        else
        {
            noise *= Math.Pow(10, (levelDb - noiseDb) * Math.Min(1, hop / 5) / 10);
        }
        _noisePower = noise;
        noiseDb = 10 * Math.Log10(noise + 1e-12);
        // Signal peak: rises within ~20 ms, decays over ~1.5 s so it survives word gaps.
        _peakDb += (levelDb - _peakDb) * (levelDb > _peakDb ? 0.2 : Math.Min(1, hop / 1.5));
        _peakDb = Math.Max(_peakDb, noiseDb);

        _snrDb = _peakDb - noiseDb;
        _level = _snrDb > 0 ? Math.Min(Math.Max((levelDb - noiseDb) / _snrDb, 0), 1) : 0;
        // Hysteresis between 60 % and 40 % of the way from noise to peak, but
        // always a fixed margin above the noise so a fading peak can't let
        // noise spikes through.
        var above = levelDb - noiseDb;
        var wantsKeyDown = _snrDb >= _settings.SquelchDb
            && (_keyDown ? above > Math.Max(0.4 * _snrDb, 5) : above > Math.Max(0.6 * _snrDb, 8));

        var text = "";
        if (wantsKeyDown != _keyDown)
        {
            if (_pendingHops == 0)
            {
                _pendingStart = now;
            }
            _pendingHops++;
            if (_pendingHops >= DebounceHops)
            {
                var duration = _pendingStart - _lastTransition;
                if (wantsKeyDown)
                {
                    text += _decoder.Space(duration);
                }
                else
                {
                    _decoder.Mark(duration);
                }
                _keyDown = wantsKeyDown;
                _lastTransition = _pendingStart;
                _pendingHops = 0;
            }
        }
        else
        {
            _pendingHops = 0;
        }

        if (!_keyDown)
        {
            text += _decoder.Space(now - _lastTransition);
        }
        return text;
    }

    private CwPipelineOutput Output(string text) => new(
        text,
        _keyDown,
        _level,
        _snrDb,
        _detector.Frequency,
        _decoder.EstimatedWpm,
        _decoder.PendingSymbols);
}

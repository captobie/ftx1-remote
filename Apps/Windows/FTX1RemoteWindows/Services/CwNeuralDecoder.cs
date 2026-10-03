using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using NAudio.Dsp;

namespace FTX1RemoteWindows.Services;

// The neural CW decoder — CWKit's Neural/ files (captobie/cwdecode,
// Sources/CWKit/Neural: NeuralFeatures.swift, AudioResampler.swift,
// StreamingCTCDecoder.swift, CWNetModel.swift, NeuralPipeline.swift)
// translated, which stay the source of truth: copy any fix made there. The
// model is CWKit's own, converted from Core ML to ONNX by
// Apps/Windows/Tools/cwnet_to_onnx.py (same weights) and run with ONNX
// Runtime instead of Core ML. Checked against CWKit's golden files (written
// by the Python reference) like its NeuralDecoderTests.

/// A decoder that turns audio chunks into text (CWKit's DecoderEngine).
/// Not thread-safe; confine each instance to one thread.
public interface ICwDecoderEngine
{
    double SampleRate { get; }
    void Update(CwPipelineSettings settings);
    CwPipelineOutput Process(float[] samples);
    /// Flushes whatever is still in progress, e.g. at the end of a file or
    /// when listening stops.
    CwPipelineOutput Finish();
}

public enum CwDecoderKind
{
    /// The CNN + CTC model trained on synthetic CW (cwdecode's ml/).
    Neural,
    /// Tone detection, threshold and timing rules.
    Classic,
}

/// Audio → the neural decoder's input, exactly as ml/cwmodel/features.py
/// computes it: 8 kHz audio, a 256-point periodic Hann window every 64
/// samples (8 ms) with 128 zeros of padding at each end, power in bins 8…40
/// (250–1250 Hz), log10, floored 60 dB below the loudest bin, then
/// standardized over the whole window.
public static class NeuralFeatures
{
    public const double SampleRate = 8000;
    public const int FftSize = 256;
    public const int Hop = 64;
    public const int BinLo = 8;
    public const int BinHi = 41;
    public const int BinCount = BinHi - BinLo;
    public const float DynamicRangeDb = 60;

    public static int FrameCount(int samples) => 1 + samples / Hop;

    /// Periodic Hann window, as torch.hann_window(256).
    private static readonly float[] Window = Enumerable.Range(0, FftSize)
        .Select(n => (float)(0.5 - 0.5 * Math.Cos(2 * Math.PI * n / FftSize))).ToArray();

    /// DFT basis for just the bins kept, [binCount × fftSize] (bin-major, so
    /// each dot product runs over contiguous memory), unnormalized like
    /// torch.stft.
    private static readonly float[] CosBasis = Basis(Math.Cos);
    private static readonly float[] SinBasis = Basis(Math.Sin);

    private static float[] Basis(Func<double, double> f)
    {
        var basis = new float[BinCount * FftSize];
        for (var j = 0; j < BinCount; j++)
        {
            var k = BinLo + j;
            for (var n = 0; n < FftSize; n++)
            {
                basis[j * FftSize + n] = (float)f(2 * Math.PI * (k * n) / FftSize);
            }
        }
        return basis;
    }

    /// [binCount × frames], bin-major (the layout of the model's
    /// [1, 1, 33, frames] input).
    public static float[] Spectrogram(ReadOnlySpan<float> audio)
    {
        var frames = FrameCount(audio.Length);
        const int pad = FftSize / 2;
        var padded = new float[audio.Length + 2 * pad];
        audio.CopyTo(padded.AsSpan(pad));

        var logs = new float[BinCount * frames];
        var windowed = new float[FftSize];
        var max = float.NegativeInfinity;
        for (var t = 0; t < frames; t++)
        {
            var frame = padded.AsSpan(t * Hop, FftSize);
            for (var n = 0; n < FftSize; n++)
            {
                windowed[n] = frame[n] * Window[n];
            }
            for (var b = 0; b < BinCount; b++)
            {
                var re = Dot(windowed, CosBasis.AsSpan(b * FftSize, FftSize));
                var im = Dot(windowed, SinBasis.AsSpan(b * FftSize, FftSize));
                var log = MathF.Log10(re * re + im * im + 1e-10f);
                logs[b * frames + t] = log;
                if (log > max)
                {
                    max = log;
                }
            }
        }

        var floor = max - DynamicRangeDb / 10;
        double sum = 0;
        for (var i = 0; i < logs.Length; i++)
        {
            if (logs[i] < floor)
            {
                logs[i] = floor;
            }
            sum += logs[i];
        }
        // Standardize with the unbiased standard deviation, as torch.Tensor.std does.
        var mean = (float)(sum / logs.Length);
        double squares = 0;
        for (var i = 0; i < logs.Length; i++)
        {
            logs[i] -= mean;
            squares += (double)logs[i] * logs[i];
        }
        var variance = (float)(squares / Math.Max(1, logs.Length - 1));
        var scale = 1 / (MathF.Sqrt(variance) + 1e-5f);
        for (var i = 0; i < logs.Length; i++)
        {
            logs[i] *= scale;
        }
        return logs;
    }

    private static float Dot(ReadOnlySpan<float> a, ReadOnlySpan<float> b)
    {
        var sum = 0f;
        var i = 0;
        if (System.Numerics.Vector.IsHardwareAccelerated)
        {
            var width = System.Numerics.Vector<float>.Count;
            var acc = System.Numerics.Vector<float>.Zero;
            for (; i <= a.Length - width; i += width)
            {
                acc += new System.Numerics.Vector<float>(a[i..]) * new System.Numerics.Vector<float>(b[i..]);
            }
            sum = System.Numerics.Vector.Sum(acc);
        }
        for (; i < a.Length; i++)
        {
            sum += a[i] * b[i];
        }
        return sum;
    }
}

/// Streams mono audio from any sample rate to the neural decoder's 8 kHz —
/// CWKit's AudioResampler (AVAudioConverter at max quality there; NAudio's
/// WDL resampler with its sinc filter here). Its output count is kept to
/// exactly input × 8000 / rate overall, so a flush emits what's still in
/// the filter.
public sealed class NeuralResampler
{
    public double InputRate { get; }
    private readonly WdlResampler? _resampler;
    private long _inputCount;
    private long _outputCount;

    public NeuralResampler(double inputRate, double outputRate = NeuralFeatures.SampleRate)
    {
        InputRate = inputRate;
        if (inputRate == outputRate)
        {
            return;
        }
        _resampler = new WdlResampler();
        _resampler.SetMode(true, 2, true, 64, 32);
        _resampler.SetFilterParms();
        _resampler.SetFeedMode(true);
        _resampler.SetRates(inputRate, outputRate);
        _ratio = outputRate / inputRate;
    }

    private readonly double _ratio = 1;

    public float[] Process(float[] samples)
    {
        if (_resampler is null)
        {
            return samples;
        }
        if (samples.Length == 0)
        {
            return [];
        }
        _inputCount += samples.Length;
        return Run(samples, samples.Length);
    }

    /// The resampler's remaining output, at the end of a stream.
    public float[] Flush()
    {
        if (_resampler is null)
        {
            return [];
        }
        var expected = (long)Math.Round(_inputCount * _ratio);
        var output = new List<float>();
        // Push silence through until the filter has given up everything the
        // real input accounts for.
        for (var guard = 0; _outputCount < expected && guard < 16; guard++)
        {
            var zeros = new float[1024];
            var produced = Run(zeros, zeros.Length);
            var wanted = (int)Math.Min(produced.Length, expected - (_outputCount - produced.Length));
            output.AddRange(produced.AsSpan(0, Math.Max(0, wanted)).ToArray());
        }
        _resampler.Reset();
        _inputCount = 0;
        _outputCount = 0;
        return [.. output];
    }

    private float[] Run(float[] input, int count)
    {
        var resampler = _resampler!;
        var needed = resampler.ResamplePrepare(count, 1, out var inBuffer, out var inOffset);
        Array.Copy(input, 0, inBuffer, inOffset, Math.Min(needed, count));
        var capacity = (int)(count * _ratio) + 64;
        var output = new float[capacity];
        var produced = resampler.ResampleOut(output, 0, count, capacity, 1);
        _outputCount += produced;
        return produced == capacity ? output : output[..produced];
    }
}

/// Per-frame token log-probabilities for one window: Frames rows of Classes values.
public sealed record CwLogProbabilities(int Frames, int Classes, float[] Values)
{
    public ReadOnlySpan<float> Row(int frame) => Values.AsSpan(frame * Classes, Classes);
}

/// The neural decoder's model: CWKit's CWNet, as Assets/CWNet.onnx, run on
/// the CPU with one thread (a window takes milliseconds) — CWKit's
/// CWNetModel. Checks the model's own metadata (vocabulary, feature
/// settings) against this code, as CWKit does.
public sealed class CwNetModel : IDisposable
{
    public IReadOnlyList<string> Vocabulary { get; }
    private readonly InferenceSession _session;
    private readonly string _inputName;

    /// The shortest window the model accepts, in spectrogram frames.
    public const int MinimumFrames = 64;

    public static string DefaultPath => Path.Combine(AppContext.BaseDirectory, "Assets", "CWNet.onnx");

    public CwNetModel(string? path = null)
    {
        path ??= DefaultPath;
        if (!File.Exists(path))
        {
            throw new InvalidOperationException("The neural decoder's model (Assets\\CWNet.onnx) is missing.");
        }
        var options = new SessionOptions
        {
            IntraOpNumThreads = 1,
            InterOpNumThreads = 1,
            GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
        };
        _session = new InferenceSession(path, options);
        _inputName = _session.InputMetadata.Keys.First();

        var metadata = _session.ModelMetadata.CustomMetadataMap;
        if (!metadata.TryGetValue("vocabulary", out var vocabularyJson)
            || JsonSerializer.Deserialize<List<string>>(vocabularyJson) is not { Count: > 0 } vocabulary
            || vocabulary[0] != "<blank>")
        {
            _session.Dispose();
            throw new InvalidOperationException("The neural decoder's model doesn't match this version of the app (no vocabulary).");
        }
        Vocabulary = vocabulary;
        if (!metadata.TryGetValue("features", out var featuresJson) || !FeaturesMatch(featuresJson))
        {
            _session.Dispose();
            throw new InvalidOperationException("The neural decoder's model doesn't match this version of the app (feature settings differ).");
        }
    }

    private static bool FeaturesMatch(string json)
    {
        try
        {
            var f = JsonDocument.Parse(json).RootElement;
            return f.GetProperty("sample_rate").GetDouble() == NeuralFeatures.SampleRate
                && f.GetProperty("n_fft").GetInt32() == NeuralFeatures.FftSize
                && f.GetProperty("hop").GetInt32() == NeuralFeatures.Hop
                && f.GetProperty("bin_lo").GetInt32() == NeuralFeatures.BinLo
                && f.GetProperty("bin_hi").GetInt32() == NeuralFeatures.BinHi
                && (float)f.GetProperty("dynamic_range_db").GetDouble() == NeuralFeatures.DynamicRangeDb
                && f.GetProperty("time_stride").GetInt32() == StreamingCtcDecoder.TimeStride;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <paramref name="spectrogram"/> is bin-major [binCount × frames];
    /// frames must be at least MinimumFrames.
    public CwLogProbabilities LogProbabilities(float[] spectrogram, int frames)
    {
        var input = new DenseTensor<float>(spectrogram, [1, 1, NeuralFeatures.BinCount, frames]);
        using var results = _session.Run([NamedOnnxValue.CreateFromTensor(_inputName, input)]);
        var output = results.First().AsTensor<float>();
        var outFrames = output.Dimensions[1];
        var classes = output.Dimensions[2];
        return new CwLogProbabilities(outFrames, classes, output.ToArray());
    }

    public void Dispose() => _session.Dispose();
}

/// Decodes a stream in overlapping windows — CWKit's StreamingCTCDecoder, a
/// line-for-line port of ml/cwmodel/stream.py, which golden tests hold it
/// to. Every `hop` seconds the last `window` seconds are decoded. Each
/// stretch of audio is committed from the window where it has at least
/// `context` seconds of audio after it, and the handoff between windows is
/// placed in the widest gap between emitted tokens near the nominal
/// boundary, so each character is committed exactly once. A token whose
/// timing depends on context (above all a space) can still land on
/// different sides of the handoff in neighboring windows, so the new
/// window's tokens from just before the handoff are aligned with what was
/// committed there: missed tokens are added, duplicates skipped. Text after
/// the handoff is tentative.
public sealed class StreamingCtcDecoder
{
    public delegate CwLogProbabilities Model(float[] spectrogram, int frames);

    public const int TimeStride = 2;
    public const double OutputFrameDuration = NeuralFeatures.Hop / NeuralFeatures.SampleRate * TimeStride;
    public const double HandoffSearch = 0.5;
    public const int MinimumSamples = (CwNetModel.MinimumFrames - 1) * NeuralFeatures.Hop;
    /// How far back before the handoff a new window's tokens are compared
    /// with committed text.
    public const double ReconcileWindow = 1.5;

    private readonly double _window;
    private readonly double _hop;
    private readonly double _context;
    private readonly IReadOnlyList<string> _vocabulary;
    private readonly Model _model;

    private readonly List<string> _committed = [];
    private List<string> _tentative = [];
    /// Committed tokens with their times.
    private readonly List<(string Token, double Time)> _recent = [];
    private readonly List<float> _audio = [];
    /// Absolute sample index of _audio[0].
    private int _origin;
    /// Absolute sample index where the last window ended.
    private int _decodedTo;
    private double _committedUntil;

    public StreamingCtcDecoder(IReadOnlyList<string> vocabulary, Model model, double window = 6, double hop = 1, double context = 2.5)
    {
        _vocabulary = vocabulary;
        _model = model;
        _window = window;
        _hop = hop;
        _context = context;
    }

    public string Text => string.Concat(_committed);
    public string TentativeText => string.Concat(_tentative);

    private static int Samples(double seconds) => (int)Math.Round(seconds * NeuralFeatures.SampleRate, MidpointRounding.AwayFromZero);

    /// Feeds 8 kHz audio; returns newly committed text.
    public string Process(float[] samples)
    {
        _audio.AddRange(samples);
        var end = _origin + _audio.Count;
        var hopSamples = Samples(_hop);
        var added = new List<string>();
        while (end - _decodedTo >= hopSamples)
        {
            _decodedTo += hopSamples;
            added.AddRange(Decode(_decodedTo, final: false));
        }
        return string.Concat(added);
    }

    /// Commits everything that's left, including the tentative tail.
    public string Finish()
    {
        var end = _origin + _audio.Count;
        var added = end > 0 ? Decode(end, final: true) : [];
        _decodedTo = end;
        return string.Concat(added);
    }

    private List<string> Decode(int end, bool final)
    {
        var windowSamples = Samples(_window);
        var start = Math.Max(_origin, end - windowSamples);
        var length = end - start;
        var chunk = new float[Math.Max(length, MinimumSamples)];
        _audio.CopyTo(start - _origin, chunk, 0, length);
        var startTime = start / NeuralFeatures.SampleRate;
        var endTime = end / NeuralFeatures.SampleRate;
        var frames = NeuralFeatures.FrameCount(chunk.Length);
        var logProbs = _model(NeuralFeatures.Spectrogram(chunk), frames);
        var tokens = Emissions(logProbs, startTime);

        double cut;
        if (final)
        {
            cut = double.PositiveInfinity;
        }
        else
        {
            var nominal = endTime - _context;
            var lo = Math.Max(_committedUntil, nominal - HandoffSearch);
            var hi = Math.Max(lo, nominal + HandoffSearch);
            cut = Handoff(tokens.Select(t => t.Time).ToList(), lo, hi);
        }

        var since = _committedUntil - ReconcileWindow;
        var before = tokens.Where(t => since <= t.Time && t.Time < _committedUntil).Select(t => t.Token).ToList();
        var after = tokens.Where(t => _committedUntil <= t.Time && t.Time < cut).ToList();
        var previous = _recent.Where(r => r.Time >= since).Select(r => r.Token).ToList();
        var (missed, skip) = Reconcile(previous, before, after.Select(t => t.Token).ToList());
        // Missed tokens are stamped at the old handoff; the rest keep this window's times.
        var kept = after.Skip(skip).ToList();
        var added = Append(
            [.. missed, .. kept.Select(t => t.Token)],
            [.. Enumerable.Repeat(_committedUntil, missed.Count), .. kept.Select(t => t.Time)]);
        _tentative = tokens.Where(t => t.Time >= cut).Select(t => t.Token).ToList();
        if (!final)
        {
            _committedUntil = cut;
            // Keep only what the next window can reach.
            var keepFrom = Math.Max(_origin, end + Samples(_hop) - windowSamples);
            _audio.RemoveRange(0, keepFrom - _origin);
            _origin = keepFrom;
        }
        return added;
    }

    /// Greedy CTC: best token per frame, runs collapsed, blanks dropped, each
    /// stamped with the time of its first frame.
    private List<(string Token, double Time)> Emissions(CwLogProbabilities logProbs, double startTime)
    {
        var output = new List<(string, double)>();
        var previous = 0;
        for (var frame = 0; frame < logProbs.Frames; frame++)
        {
            var row = logProbs.Row(frame);
            var best = 0;
            var bestValue = float.NegativeInfinity;
            for (var c = 0; c < row.Length; c++)
            {
                if (row[c] > bestValue)
                {
                    best = c;
                    bestValue = row[c];
                }
            }
            if (best != previous && best != 0)
            {
                output.Add((_vocabulary[best], startTime + frame * OutputFrameDuration));
            }
            previous = best;
        }
        return output;
    }

    /// The point in [lo, hi], on the model's frame grid, farthest from any emission.
    public static double Handoff(IReadOnlyList<double> times, double lo, double hi)
    {
        if (!(hi > lo))
        {
            return lo;
        }
        var count = (int)Math.Ceiling((hi + 1e-9 - lo) / OutputFrameDuration);
        var candidates = Enumerable.Range(0, count).Select(i => lo + i * OutputFrameDuration).ToList();
        if (times.Count == 0)
        {
            return candidates[candidates.Count / 2];
        }
        var best = candidates[0];
        var bestDistance = -1.0;
        foreach (var candidate in candidates)
        {
            var distance = times.Min(t => Math.Abs(candidate - t));
            if (distance > bestDistance)
            {
                best = candidate;
                bestDistance = distance;
            }
        }
        return best;
    }

    /// The last pair (i, j) with a[i] == b[j] in a longest common subsequence
    /// of a and b, backtracking from the end and preferring to drop from `a`
    /// on ties, as the Python does.
    public static (int I, int J)? LastMatch(IReadOnlyList<string> a, IReadOnlyList<string> b)
    {
        int n = a.Count, m = b.Count;
        var lengths = new int[n + 1, m + 1];
        for (var i = 0; i < n; i++)
        {
            for (var j = 0; j < m; j++)
            {
                lengths[i + 1, j + 1] = a[i] == b[j] ? lengths[i, j] + 1 : Math.Max(lengths[i, j + 1], lengths[i + 1, j]);
            }
        }
        int x = n, y = m;
        while (x > 0 && y > 0)
        {
            if (a[x - 1] == b[y - 1])
            {
                return (x - 1, y - 1);
            }
            if (lengths[x - 1, y] >= lengths[x, y - 1])
            {
                x--;
            }
            else
            {
                y--;
            }
        }
        return null;
    }

    /// Compares tokens committed in the last ReconcileWindow (previous) with
    /// the new window's tokens in that stretch (before) and after it (after).
    /// Returns tokens the earlier window missed, to commit first, and how
    /// many leading tokens of `after` it already committed.
    public static (List<string> Missed, int Skip) Reconcile(IReadOnlyList<string> previous, IReadOnlyList<string> before, IReadOnlyList<string> after)
    {
        if (previous.Count == 0 || before.Count == 0 || LastMatch(previous, before) is not var (i, j))
        {
            return ([], 0);
        }
        if (i == previous.Count - 1)
        {
            return (before.Skip(j + 1).ToList(), 0);
        }
        var already = j == before.Count - 1 ? previous.Skip(i + 1).ToList() : [];
        return ([], after.Take(already.Count).SequenceEqual(already) ? already.Count : 0);
    }

    /// Adds tokens to the committed text without leading or doubled spaces.
    private List<string> Append(List<string> tokens, List<double> times)
    {
        var added = new List<string>();
        for (var k = 0; k < tokens.Count; k++)
        {
            var last = added.Count > 0 ? added[^1] : _committed.Count > 0 ? _committed[^1] : " ";
            if (tokens[k] == " " && last == " ")
            {
                continue;
            }
            added.Add(tokens[k]);
            _recent.Add((tokens[k], times[k]));
        }
        _committed.AddRange(added);
        _recent.RemoveAll(r => r.Time < _committedUntil - 2 * ReconcileWindow);
        return added;
    }
}

/// Audio in, text out, with the neural decoder: resample to 8 kHz, then
/// decode overlapping windows with the CTC model — CWKit's NeuralPipeline.
/// The classic pipeline still runs alongside, but only for the signal
/// meter, tone and WPM display; its text is discarded.
public sealed class CwNeuralPipeline : ICwDecoderEngine
{
    public double SampleRate { get; }
    private readonly CwClassicDecoder _meters;
    private readonly NeuralResampler _resampler;
    private readonly StreamingCtcDecoder _decoder;
    private Exception? _failure;

    public CwNeuralPipeline(double sampleRate, CwPipelineSettings settings, CwNetModel model)
    {
        SampleRate = sampleRate;
        _meters = new CwClassicDecoder(sampleRate, settings);
        _resampler = new NeuralResampler(sampleRate);
        _decoder = new StreamingCtcDecoder(model.Vocabulary, model.LogProbabilities);
    }

    public void Update(CwPipelineSettings settings) => _meters.Update(settings);

    public CwPipelineOutput Process(float[] samples) =>
        Output(_meters.Process(samples), () => _decoder.Process(_resampler.Process(samples)));

    public CwPipelineOutput Finish() =>
        Output(_meters.Finish(), () =>
        {
            var tail = _decoder.Process(_resampler.Flush());
            return tail + _decoder.Finish();
        });

    private CwPipelineOutput Output(CwPipelineOutput meters, Func<string> decode)
    {
        string text;
        try
        {
            text = _failure is null ? decode() : "";
        }
        catch (Exception ex)
        {
            // A model error would repeat on every window; report it once and stop decoding.
            _failure = ex;
            AppLog.Write($"cw-decoder: neural decoder failed: {ex.Message}");
            text = "";
        }
        return meters with { Text = text, PendingSymbols = "", TentativeText = _decoder.TentativeText };
    }
}

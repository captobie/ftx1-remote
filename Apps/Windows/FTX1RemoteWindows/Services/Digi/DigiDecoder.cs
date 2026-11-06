using NAudio.Dsp;

namespace FTX1RemoteWindows.Services.Digi;

/// The keyboard modes Tools → RTTY/PSK decodes — the Mac's DigiMode.
public enum DigiMode
{
    Rtty,
    Bpsk31,
    Bpsk63,
}

public static class DigiModeExtensions
{
    /// Radio terms, not translated.
    public static string Title(this DigiMode mode) => mode switch
    {
        DigiMode.Rtty => "RTTY",
        DigiMode.Bpsk31 => "BPSK31",
        _ => "BPSK63",
    };

    public static bool IsPsk(this DigiMode mode) => mode != DigiMode.Rtty;

    public static double PskBaud(this DigiMode mode) => mode == DigiMode.Bpsk63 ? 62.5 : 31.25;

    /// Roughly how wide the signal is, for the tuning strip's marker.
    public static double BandwidthHz(this DigiMode mode, RttySettings rtty) => mode switch
    {
        DigiMode.Rtty => rtty.ShiftHz + rtty.Baud,
        DigiMode.Bpsk31 => 62.5,
        _ => 125,
    };
}

/// What one <see cref="DigiDecoder.Process"/> call produced.
internal sealed record DigiDecoderOutput(string Text, float[]? SpectrumRow, double CenterHz, float Quality);

/// Resample → demodulate → spectrum, for one mode and settings at a time —
/// the Mac's DigiDecoder. Not thread-safe: the receiver makes it on the UI
/// thread and from then on uses it only on its one worker.
internal sealed class DigiDecoder
{
    public const double SampleRate = 8000;
    /// The tuning strip shows 0 … this.
    public const double StripSpanHz = 3000;
    private const int FftSize = 2048;
    /// A spectrum row every 800 samples (0.1 s).
    private const int RowHop = 800;

    private readonly DigiMode _mode;
    private readonly DigiResampler _resampler = new(SampleRate);
    private readonly RttyDemodulator? _rtty;
    private readonly PskDemodulator? _psk;
    private float _rttySquelch;

    private readonly DigiSpectrum _spectrum = new(FftSize);
    private readonly float[] _history = new float[FftSize];
    private int _samplesSinceRow;

    public DigiDecoder(DigiMode mode, RttySettings rttySettings, double centerHz, bool afc, float squelch)
    {
        _mode = mode;
        if (mode == DigiMode.Rtty)
        {
            _rtty = new RttyDemodulator(rttySettings, centerHz) { AfcEnabled = afc };
        }
        else
        {
            _psk = new PskDemodulator(mode.PskBaud(), centerHz) { AfcEnabled = afc, Squelch = squelch };
        }
        _rttySquelch = squelch;
    }

    public DigiMode Mode => _mode;
    public double CenterHz => _rtty?.CenterHz ?? _psk?.CenterHz ?? 0;
    public float Quality => _rtty?.Quality ?? _psk?.Quality ?? 0;

    public void SetCenter(double hz)
    {
        _rtty?.SetCenter(hz);
        _psk?.SetCenter(hz);
    }

    public void SetAfc(bool on)
    {
        if (_rtty is not null)
        {
            _rtty.AfcEnabled = on;
        }
        if (_psk is not null)
        {
            _psk.AfcEnabled = on;
        }
    }

    public void SetSquelch(float value)
    {
        _rttySquelch = value;
        if (_psk is not null)
        {
            _psk.Squelch = value;
        }
    }

    /// Drops filter and framing state (after a pause or a source switch).
    public void Reset()
    {
        _rtty?.Reset();
        _psk?.Reset();
        _resampler.Reset();
    }

    /// <paramref name="samples"/> at any rate; resampled to 8 kHz here.
    public DigiDecoderOutput Process(float[] samples, int sampleRate)
    {
        var audio = sampleRate == (int)SampleRate ? samples : _resampler.Convert(samples, sampleRate);
        var text = "";
        if (_rtty is not null)
        {
            var decoded = _rtty.Process(audio);
            // RTTY prints only above this quality too (noise otherwise
            // prints a stream of random letters).
            if (_rtty.Quality >= _rttySquelch)
            {
                text = decoded;
            }
        }
        else if (_psk is not null)
        {
            text = _psk.Process(audio);
        }
        return new DigiDecoderOutput(text, SpectrumRow(audio), CenterHz, Quality);
    }

    private float[]? SpectrumRow(float[] audio)
    {
        if (audio.Length == 0)
        {
            return null;
        }
        if (audio.Length >= _history.Length)
        {
            Array.Copy(audio, audio.Length - _history.Length, _history, 0, _history.Length);
        }
        else
        {
            Array.Copy(_history, audio.Length, _history, 0, _history.Length - audio.Length);
            Array.Copy(audio, 0, _history, _history.Length - audio.Length, audio.Length);
        }
        _samplesSinceRow += audio.Length;
        if (_samplesSinceRow < RowHop)
        {
            return null;
        }
        _samplesSinceRow = 0;
        return _spectrum.Row(_history, SampleRate, StripSpanHz);
    }
}

/// Streaming resampler to mono 8 kHz: one long-lived WDL resampler (windowed
/// sinc, like the hub's audio encoder) so its filter state carries across
/// chunks. Rebuilt only when the source rate changes.
internal sealed class DigiResampler(double targetRate)
{
    private const int SincSize = 512;
    private const int SincInterpSize = 32;

    private WdlResampler? _resampler;
    private int _sourceRate;

    public float[] Convert(float[] samples, int sourceRate)
    {
        if (samples.Length == 0 || sourceRate <= 0)
        {
            return [];
        }
        if (_resampler is null || sourceRate != _sourceRate)
        {
            _resampler = new WdlResampler();
            _resampler.SetMode(true, 0, true, SincSize, SincInterpSize);
            _resampler.SetFeedMode(true);
            _resampler.SetRates(sourceRate, targetRate);
            _sourceRate = sourceRate;
        }
        var result = new List<float>((int)(samples.Length * targetRate / sourceRate) + 16);
        var scratch = new float[(int)(samples.Length * targetRate / sourceRate) + 64];
        var offset = 0;
        while (offset < samples.Length)
        {
            var remaining = samples.Length - offset;
            var accepted = _resampler.ResamplePrepare(remaining, 1, out var inBuffer, out var inOffset);
            if (accepted <= 0)
            {
                break;
            }
            accepted = Math.Min(accepted, remaining);
            Array.Copy(samples, offset, inBuffer, inOffset, accepted);
            offset += accepted;
            var produced = _resampler.ResampleOut(scratch, 0, accepted, scratch.Length, 1);
            for (var i = 0; i < produced; i++)
            {
                result.Add(scratch[i]);
            }
        }
        return [.. result];
    }

    public void Reset()
    {
        _resampler?.Reset();
    }
}

/// The tuning strip's rows: a Hann-windowed FFT of the last 2048 samples,
/// power in dB, mapped to 0…1 through a peak-hold-and-decay window (the
/// scope's auto-gain, same constants) over 0 … span Hz.
internal sealed class DigiSpectrum(int size)
{
    private const float DynamicRangeDb = 45;
    private const float HeadroomDb = 3;
    private const float PeakDecayPerRowDb = 0.5f;
    private const float MinimumPeakDb = -70;

    private readonly float[] _window = BuildWindow(size);
    private readonly float[] _re = new float[size];
    private readonly float[] _im = new float[size];
    private readonly float[] _cos = Enumerable.Range(0, size / 2).Select(i => (float)Math.Cos(-2 * Math.PI * i / size)).ToArray();
    private readonly float[] _sin = Enumerable.Range(0, size / 2).Select(i => (float)Math.Sin(-2 * Math.PI * i / size)).ToArray();
    private float _peakDb = MinimumPeakDb;

    private static float[] BuildWindow(int n)
    {
        // Scaled to RMS 1, like the scope's window, so dB levels match.
        var w = new float[n];
        for (var i = 0; i < n; i++)
        {
            w[i] = 0.8165f * (1 - (float)Math.Cos(2 * Math.PI * i / n));
        }
        return w;
    }

    public float[] Row(float[] samples, double sampleRate, double spanHz)
    {
        for (var i = 0; i < size; i++)
        {
            _re[i] = samples[i] * _window[i];
            _im[i] = 0;
        }
        Fft();
        var binHz = sampleRate / size;
        var bins = Math.Min(size / 2, (int)(spanHz / binHz));
        var db = new float[bins];
        var rowPeak = float.NegativeInfinity;
        for (var k = 0; k < bins; k++)
        {
            var power = (_re[k] * _re[k] + _im[k] * _im[k]) / ((float)size * size);
            db[k] = 10 * MathF.Log10(power + 1e-12f);
            rowPeak = MathF.Max(rowPeak, db[k]);
        }
        _peakDb = MathF.Max(MinimumPeakDb, MathF.Max(rowPeak, _peakDb - PeakDecayPerRowDb));
        var ceiling = _peakDb + HeadroomDb;
        var floor = ceiling - DynamicRangeDb;
        var row = new float[bins];
        for (var k = 0; k < bins; k++)
        {
            row[k] = Math.Clamp((db[k] - floor) / (ceiling - floor), 0, 1);
        }
        return row;
    }

    /// In-place radix-2 FFT of _re/_im.
    private void Fft()
    {
        var n = size;
        for (int i = 1, j = 0; i < n; i++)
        {
            var bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1)
            {
                j ^= bit;
            }
            j ^= bit;
            if (i < j)
            {
                (_re[i], _re[j]) = (_re[j], _re[i]);
                (_im[i], _im[j]) = (_im[j], _im[i]);
            }
        }
        for (var length = 2; length <= n; length <<= 1)
        {
            var half = length / 2;
            var step = n / length;
            for (var start = 0; start < n; start += length)
            {
                for (var k = 0; k < half; k++)
                {
                    var wr = _cos[k * step];
                    var wi = _sin[k * step];
                    var a = start + k;
                    var b = a + half;
                    var tr = _re[b] * wr - _im[b] * wi;
                    var ti = _re[b] * wi + _im[b] * wr;
                    _re[b] = _re[a] - tr;
                    _im[b] = _im[a] - ti;
                    _re[a] += tr;
                    _im[a] += ti;
                }
            }
        }
    }
}

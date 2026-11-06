namespace FTX1RemoteWindows.Services.Digi;

/// Small DSP building blocks shared by the RTTY and PSK demodulators — the
/// Mac's DigiDSP.swift (Sources/FTX1Digi/), which stays the source of truth.
/// Everything here runs on the decoder's own worker, never the UI thread,
/// and is used by one demodulator at a time (not thread-safe).
internal static class FirDesign
{
    /// Windowed-sinc (Blackman) low-pass taps, normalized to unity DC gain.
    /// <paramref name="cutoffHz"/> is the -6 dB point; <paramref name="count"/>
    /// should be odd.
    public static float[] LowPass(double cutoffHz, double sampleRate, int count)
    {
        var fc = cutoffHz / sampleRate;
        var middle = (count - 1) / 2.0;
        var taps = new float[count];
        var sum = 0.0;
        for (var i = 0; i < count; i++)
        {
            var n = i - middle;
            var sinc = n == 0 ? 2 * fc : Math.Sin(2 * Math.PI * fc * n) / (Math.PI * n);
            var x = i / (double)(count - 1);
            var window = 0.42 - 0.5 * Math.Cos(2 * Math.PI * x) + 0.08 * Math.Cos(4 * Math.PI * x);
            var value = sinc * window;
            taps[i] = (float)value;
            sum += value;
        }
        var scale = (float)(1 / sum);
        for (var i = 0; i < count; i++)
        {
            taps[i] *= scale;
        }
        return taps;
    }
}

/// A real-tap FIR over complex samples (separate I and Q), computing one
/// output every <c>decimation</c> inputs. The history is kept twice over
/// (<c>buffer[i]</c> and <c>buffer[i + n]</c>) so the newest n samples are
/// always contiguous.
internal sealed class DecimatingComplexFir
{
    private readonly float[] _taps;
    private readonly int _decimation;
    private readonly float[] _bufferI;
    private readonly float[] _bufferQ;
    private int _index;
    private int _phase;

    public DecimatingComplexFir(float[] taps, int decimation)
    {
        _taps = taps;
        _decimation = Math.Max(1, decimation);
        _bufferI = new float[taps.Length * 2];
        _bufferQ = new float[taps.Length * 2];
    }

    /// Pushes one sample; true (with the filtered value) on every
    /// decimation-th call.
    public bool Push(float i, float q, out float outI, out float outQ)
    {
        var n = _taps.Length;
        _bufferI[_index] = i;
        _bufferI[_index + n] = i;
        _bufferQ[_index] = q;
        _bufferQ[_index + n] = q;
        _index++;
        if (_index == n)
        {
            _index = 0;
        }
        _phase++;
        if (_phase < _decimation)
        {
            outI = outQ = 0;
            return false;
        }
        _phase = 0;
        // The newest n samples are buffer[_index ..< _index + n], oldest
        // first; the taps are symmetric, so their order doesn't matter.
        float sumI = 0, sumQ = 0;
        for (var k = 0; k < n; k++)
        {
            var tap = _taps[k];
            sumI += _bufferI[_index + k] * tap;
            sumQ += _bufferQ[_index + k] * tap;
        }
        outI = sumI;
        outQ = sumQ;
        return true;
    }

    public void Reset()
    {
        Array.Clear(_bufferI);
        Array.Clear(_bufferQ);
        _index = 0;
        _phase = 0;
    }
}

/// A numerically controlled oscillator: <see cref="Next"/> returns e^{-jφ}
/// and advances φ by the current frequency, so <c>sample * Next()</c> mixes a
/// tone at <see cref="FrequencyHz"/> down to 0 Hz.
internal sealed class Nco(double frequencyHz, double sampleRate)
{
    private double _phase;

    public double FrequencyHz { get; set; } = frequencyHz;

    public (float Cos, float Sin) Next()
    {
        var c = (float)Math.Cos(_phase);
        var s = (float)-Math.Sin(_phase);
        _phase += 2 * Math.PI * FrequencyHz / sampleRate;
        if (_phase > 2 * Math.PI)
        {
            _phase -= 2 * Math.PI;
        }
        else if (_phase < 0)
        {
            _phase += 2 * Math.PI;
        }
        return (c, s);
    }
}

/// One complex sample, for the demodulators' decimated paths.
internal readonly record struct Complex(float Re, float Im)
{
    public static readonly Complex Zero = new(0, 0);

    public float Magnitude => MathF.Sqrt(Re * Re + Im * Im);
    public float MagnitudeSquared => Re * Re + Im * Im;
    public float Phase => MathF.Atan2(Im, Re);

    /// this × conj(other)
    public Complex TimesConjugate(Complex other) =>
        new(Re * other.Re + Im * other.Im, Im * other.Re - Re * other.Im);

    public Complex Squared() => new(Re * Re - Im * Im, 2 * Re * Im);
}

namespace FTX1RemoteWindows.Services;

/// What the scope column shows — the Mac's ScopeDisplayMode. Off skips the
/// DSP entirely (the Mac's AudioCaptureEngine.displayEnabled): playback
/// is unaffected, and the Filter Function Display drops its spectrum.
public enum ScopeDisplayMode
{
    Waterfall,
    Oscilloscope,
    Off,
}

/// One chunk's display output, handed to the UI thread.
/// <param name="WaterfallRow">256 intensities 0-1 across 0-4 kHz (newest
/// waterfall row).</param>
/// <param name="Oscilloscope">256 samples scaled to ±1 (clamped) for the
/// trace.</param>
/// <param name="Spectrum">0-4 kHz bins normalized 0-1 through the same
/// auto-gain window as the waterfall, for the Filter Function Display.</param>
public sealed record ScopeFrame(float[] WaterfallRow, float[] Oscilloscope, float[] Spectrum);

/// Port of the DSP half of the Mac's AudioCaptureEngine: a 2048-point FFT
/// per chunk (Hann window, power in dB) with peak-hold-and-decay auto-gain,
/// turned into a waterfall row, an oscilloscope trace from the same raw
/// samples, and the 0-4 kHz spectrum the Filter Function Display overlays —
/// plus a Sub-channel spectrum (own auto-gain) while SUB is the selected
/// filter side. Same constants as the Mac, so the two apps look alike — with
/// one deliberate difference: the waterfall spans 0-4 kHz (the audio the rig
/// passes, and the Filter display's span), where the Mac's spans 0-Nyquist
/// (~22 kHz) and leaves most of its width dark.
///
/// Runs on the audio source's thread (MainWindow's Route callback): both
/// sources deliver 2048-sample chunks, so each chunk is one frame (~21.5 a
/// second at 44.1 kHz), padded or truncated to the FFT size like the Mac.
/// The settings below are written from the UI thread and read per chunk.
public sealed class ScopeProcessor
{
    public const int FftSize = 2048;
    public const int BinCount = 256;

    private const int Log2FftSize = 11;
    private const float WaterfallDynamicRangeDb = 45;
    private const float WaterfallHeadroomDb = 3;
    private const float WaterfallPeakDecayPerFrameDb = 0.5f;
    private const float WaterfallMinimumPeakDb = -70;
    private const float OscilloscopeMinimumPeakAmplitude = 0.02f;
    private const float OscilloscopePeakDecayPerFrame = 0.002f;

    /// Hann window scaled to RMS 1 — vDSP_HANN_NORM (0.8165 × (1 − cos)),
    /// so dB levels (and the -70 dB auto-gain floor) match the Mac's.
    private static readonly float[] Window = BuildWindow();
    private static readonly float[] Cos = new float[FftSize / 2];
    private static readonly float[] Sin = new float[FftSize / 2];
    private static readonly int[] BitReverse = new int[FftSize];

    static ScopeProcessor()
    {
        for (var i = 0; i < FftSize / 2; i++)
        {
            Cos[i] = (float)Math.Cos(-2 * Math.PI * i / FftSize);
            Sin[i] = (float)Math.Sin(-2 * Math.PI * i / FftSize);
        }
        for (var i = 0; i < FftSize; i++)
        {
            var r = 0;
            for (var b = 0; b < Log2FftSize; b++)
            {
                r |= ((i >> b) & 1) << (Log2FftSize - 1 - b);
            }
            BitReverse[i] = r;
        }
    }

    private readonly Action<ScopeFrame> _onFrame;
    private readonly Action<float[]> _onSubSpectrum;

    // Only touched on the audio thread.
    private readonly float[] _re = new float[FftSize];
    private readonly float[] _im = new float[FftSize];
    private readonly float[] _samples = new float[FftSize];
    private float _peakDb = WaterfallMinimumPeakDb;
    private float _subPeakDb = WaterfallMinimumPeakDb;
    private float _peakAmplitude = OscilloscopeMinimumPeakAmplitude;

    private volatile bool _displayEnabled = true;
    private volatile bool _subSpectrumEnabled;
    private volatile float _waterfallZoom = 1;
    private volatile float _oscilloscopeZoom = 1;

    /// <param name="onFrame">Called on the audio thread; marshal to the UI.</param>
    /// <param name="onSubSpectrum">Likewise, only while SubSpectrumEnabled.</param>
    public ScopeProcessor(Action<ScopeFrame> onFrame, Action<float[]> onSubSpectrum)
    {
        _onFrame = onFrame;
        _onSubSpectrum = onSubSpectrum;
    }

    public bool DisplayEnabled { get => _displayEnabled; set => _displayEnabled = value; }
    public bool SubSpectrumEnabled { get => _subSpectrumEnabled; set => _subSpectrumEnabled = value; }
    /// Narrows (above 1) or widens the dB span mapped to the palette.
    public float WaterfallZoom { get => _waterfallZoom; set => _waterfallZoom = value; }
    /// Vertical scale on top of the trace's auto-gain.
    public float OscilloscopeZoom { get => _oscilloscopeZoom; set => _oscilloscopeZoom = value; }

    /// One chunk per channel, already routed to their Main/Sub roles.
    public void Process(float[] main, float[] sub, int sampleRate)
    {
        if (!_displayEnabled || main.Length == 0)
        {
            return;
        }

        LoadPadded(main);
        var db = FftPowerDb();

        // Auto-gain: jump up to this frame's loudest bin at once, or decay
        // one step — never below the floor, so near-silence doesn't drag the
        // ceiling down to the noise and light up the whole palette.
        _peakDb = Math.Max(WaterfallMinimumPeakDb, Math.Max(Max(db), _peakDb - WaterfallPeakDecayPerFrameDb));
        var ceilingDb = _peakDb + WaterfallHeadroomDb;
        var floorDb = ceilingDb - WaterfallDynamicRangeDb / _waterfallZoom;
        var spectrum = NormalizedSpectrum(db, floorDb, ceilingDb, sampleRate);

        // The 0-4 kHz bins (~186 at 44.1 kHz) spread over BinCount columns.
        // Each column takes the peak of the bins it covers — at least one,
        // so with fewer bins than columns a bin spans neighboring columns.
        var row = new float[BinCount];
        var waterfallBins = Math.Min(db.Length, BinsBelow(4000, sampleRate));
        var range = ceilingDb - floorDb;
        for (var i = 0; i < BinCount; i++)
        {
            var start = i * waterfallBins / BinCount;
            var end = Math.Max(start + 1, (i + 1) * waterfallBins / BinCount);
            var bucketMax = float.NegativeInfinity;
            for (var j = start; j < end; j++)
            {
                bucketMax = Math.Max(bucketMax, db[j]);
            }
            row[i] = (Math.Clamp(bucketMax, floorDb, ceilingDb) - floorDb) / range;
        }

        // The trace: raw (unwindowed) samples, nearest-neighbor down to
        // BinCount points, scaled by its own peak-hold auto-gain and zoom.
        var maxAbs = 0f;
        foreach (var s in _samples)
        {
            maxAbs = Math.Max(maxAbs, Math.Abs(s));
        }
        _peakAmplitude = Math.Max(OscilloscopeMinimumPeakAmplitude, Math.Max(maxAbs, _peakAmplitude - OscilloscopePeakDecayPerFrame));
        var scale = _oscilloscopeZoom / _peakAmplitude;
        var trace = new float[BinCount];
        var step = (double)(FftSize - 1) / (BinCount - 1);
        for (var x = 0; x < BinCount; x++)
        {
            trace[x] = Math.Clamp(_samples[Math.Min((int)(x * step), FftSize - 1)] * scale, -1, 1);
        }

        _onFrame(new ScopeFrame(row, trace, spectrum));

        if (_subSpectrumEnabled && sub.Length > 0)
        {
            LoadPadded(sub);
            var subDb = FftPowerDb();
            _subPeakDb = Math.Max(WaterfallMinimumPeakDb, Math.Max(Max(subDb), _subPeakDb - WaterfallPeakDecayPerFrameDb));
            var subCeiling = _subPeakDb + WaterfallHeadroomDb;
            var subFloor = subCeiling - WaterfallDynamicRangeDb / _waterfallZoom;
            _onSubSpectrum(NormalizedSpectrum(subDb, subFloor, subCeiling, sampleRate));
        }
    }

    /// Zero-pads or truncates a chunk into _samples.
    private void LoadPadded(float[] chunk)
    {
        var count = Math.Min(chunk.Length, FftSize);
        Array.Copy(chunk, _samples, count);
        Array.Clear(_samples, count, FftSize - count);
    }

    /// Window + FFT of _samples, power in dB for the FftSize / 2 bins below
    /// Nyquist. Power is 4 × |X|², the Mac's vDSP_fft_zrip + vDSP_zvmags
    /// scale (zrip's output is twice the DFT), again so levels match.
    private float[] FftPowerDb()
    {
        for (var i = 0; i < FftSize; i++)
        {
            var j = BitReverse[i];
            _re[j] = _samples[i] * Window[i];
            _im[j] = 0;
        }
        // Iterative radix-2 Cooley-Tukey.
        for (var size = 2; size <= FftSize; size <<= 1)
        {
            var half = size >> 1;
            var twiddleStep = FftSize / size;
            for (var start = 0; start < FftSize; start += size)
            {
                for (var k = 0; k < half; k++)
                {
                    var wr = Cos[k * twiddleStep];
                    var wi = Sin[k * twiddleStep];
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
        var db = new float[FftSize / 2];
        for (var i = 0; i < db.Length; i++)
        {
            var power = 4 * (_re[i] * _re[i] + _im[i] * _im[i]);
            db[i] = 10 * MathF.Log10(Math.Max(power, 1e-20f));
        }
        return db;
    }

    /// The bins up to 4 kHz (~186 at 44.1 kHz), clipped to the auto-gain
    /// window and normalized 0-1.
    private static float[] NormalizedSpectrum(float[] db, float floorDb, float ceilingDb, int sampleRate)
    {
        var count = Math.Min(db.Length, BinsBelow(4000, sampleRate));
        var spectrum = new float[count];
        var range = Math.Max(ceilingDb - floorDb, 1e-6f);
        for (var i = 0; i < count; i++)
        {
            spectrum[i] = (Math.Clamp(db[i], floorDb, ceilingDb) - floorDb) / range;
        }
        return spectrum;
    }

    /// How many FFT bins lie below <paramref name="hz"/>.
    private static int BinsBelow(double hz, int sampleRate) => (int)(hz / ((double)sampleRate / FftSize));

    private static float Max(float[] values)
    {
        var max = float.NegativeInfinity;
        foreach (var v in values)
        {
            max = Math.Max(max, v);
        }
        return max;
    }

    private static float[] BuildWindow()
    {
        var window = new float[FftSize];
        for (var i = 0; i < FftSize; i++)
        {
            window[i] = (float)(0.8165 * (1 - Math.Cos(2 * Math.PI * i / FftSize)));
        }
        return window;
    }
}

namespace FTX1RemoteWindows.Services;

/// Port of Sources/FTX1Core/APRS/AFSKDemodulator.swift — same algorithm and
/// constants, so a tuning change made there can be copied here line for
/// line. Demodulates Bell 202 AFSK (1200 Hz mark / 2200 Hz space, 1200
/// baud) into NRZI-decoded line bits: flags and bit-stuffed data, what
/// <see cref="Ax25FrameDecoder"/> expects. Knows nothing about AX.25.
///
/// Stateful and incremental (tone-detector EMA state, bit-clock DPLL phase
/// and the last line level carry across calls), since audio arrives as a
/// stream of 2048-sample chunks, not one packet at a time. Not thread-safe:
/// one instance per audio channel, driven from one thread (AprsDecoder's).
public sealed class AfskDemodulator
{
    private const double MarkHz = 1200;
    private const double SpaceHz = 2200;
    private const double BaudRate = 1200;
    private const double TwoPi = 2 * Math.PI;

    private readonly double _sampleRate;

    // Quadrature correlators against the two tones, smoothed with an EMA
    // over one bit period — a non-coherent tone detector: whichever tone
    // has more energy is this sample's raw bit (mark = high).
    private double _markPhase;
    private double _spacePhase;
    private double _markI;
    private double _markQ;
    private double _spaceI;
    private double _spaceQ;
    private readonly double _emaAlpha;

    // Bit-clock recovery: a DPLL over the raw decision stream. The symbol is
    // latched when the phase crosses 0.5 (mid-bit); each raw transition
    // nudges the phase toward 0.
    private double _bitPhase;
    private readonly double _bitPhaseIncrement;
    /// Tuned on the Mac against a real recorded APRS capture — a stronger
    /// correction (up to 0.3) measurably hurt real-world decodes, since
    /// noise-driven transitions near a mark/space tie would be chased.
    private const double DampingFactor = 0.05;
    private bool? _lastRawBit;
    private bool _lastLineLevel = true;

    // Single-pole DC blocker ahead of the tone detector.
    private double _dcBlockerPreviousInput;
    private double _dcBlockerPreviousOutput;
    private const double DcBlockerR = 0.995;

    public AfskDemodulator(double sampleRate)
    {
        _sampleRate = sampleRate;
        _bitPhaseIncrement = BaudRate / sampleRate;
        // A full bit period (about one mark cycle, 1.8 space cycles) —
        // enough to tell the tones apart, short enough not to blur across a
        // bit transition.
        var samplesPerBit = sampleRate / BaudRate;
        _emaAlpha = 2.0 / (samplesPerBit + 1);
    }

    /// Feeds PCM samples and appends any newly recovered line bits
    /// (NRZI-decoded, not yet destuffed) to <paramref name="lineBits"/>.
    public void Process(ReadOnlySpan<float> samples, List<bool> lineBits)
    {
        foreach (var sample in samples)
        {
            if (ProcessSample(sample) is { } bit)
            {
                lineBits.Add(bit);
            }
        }
    }

    private bool? ProcessSample(double rawSample)
    {
        var sample = rawSample - _dcBlockerPreviousInput + DcBlockerR * _dcBlockerPreviousOutput;
        _dcBlockerPreviousInput = rawSample;
        _dcBlockerPreviousOutput = sample;

        _markPhase += TwoPi * MarkHz / _sampleRate;
        _spacePhase += TwoPi * SpaceHz / _sampleRate;
        if (_markPhase > TwoPi)
        {
            _markPhase -= TwoPi;
        }
        if (_spacePhase > TwoPi)
        {
            _spacePhase -= TwoPi;
        }

        _markI += _emaAlpha * (sample * Math.Cos(_markPhase) - _markI);
        _markQ += _emaAlpha * (sample * Math.Sin(_markPhase) - _markQ);
        _spaceI += _emaAlpha * (sample * Math.Cos(_spacePhase) - _spaceI);
        _spaceQ += _emaAlpha * (sample * Math.Sin(_spacePhase) - _spaceQ);

        var markEnergy = _markI * _markI + _markQ * _markQ;
        var spaceEnergy = _spaceI * _spaceI + _spaceQ * _spaceQ;
        var rawBit = markEnergy > spaceEnergy;

        var previousPhase = _bitPhase;
        _bitPhase += _bitPhaseIncrement;
        bool? sampledSymbol = previousPhase < 0.5 && _bitPhase >= 0.5 ? rawBit : null;
        if (_bitPhase >= 1.0)
        {
            _bitPhase -= 1.0;
        }

        if (_lastRawBit is { } last && last != rawBit)
        {
            var error = _bitPhase < 0.5 ? _bitPhase : _bitPhase - 1.0;
            _bitPhase -= error * DampingFactor;
        }
        _lastRawBit = rawBit;

        if (sampledSymbol is not { } level)
        {
            return null;
        }
        var decodedBit = level == _lastLineLevel;
        _lastLineLevel = level;
        return decodedBit;
    }
}

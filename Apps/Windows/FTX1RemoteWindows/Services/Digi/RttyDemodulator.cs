using System.Text;

namespace FTX1RemoteWindows.Services.Digi;

/// RTTY settings — the Mac's RTTYSettings. The centre is the audio frequency
/// halfway between the two tones. Normal RTTY puts mark on the higher RF
/// frequency, which on a lower sideband (LSB, the rig's RTTY mode) is the
/// lower audio tone and on an upper sideband (USB, DATA-U) the higher one;
/// <see cref="Reverse"/> is for a station sending the other way round. The
/// demodulator itself takes Reverse literally (off = mark is the lower tone)
/// — callers pass <see cref="EffectiveReverse"/>.
public sealed record RttySettings(double ShiftHz = 170, double Baud = 45.45, bool Reverse = false, bool UnshiftOnSpace = true)
{
    public static readonly double[] Shifts = [170, 200, 425, 850];
    public static readonly double[] Bauds = [45.45, 50, 75];

    /// Whether mark is the higher audio tone, for audio from (or to) a
    /// receiver on an upper sideband or not.
    public bool EffectiveReverse(bool upperSideband) => Reverse != upperSideband;

    /// The audio tones for a centre frequency, as sent or expected.
    public (double MarkHz, double SpaceHz) Tones(double centerHz, bool upperSideband)
    {
        var half = ShiftHz / 2;
        return EffectiveReverse(upperSideband)
            ? (centerHz + half, centerHz - half)
            : (centerHz - half, centerHz + half);
    }
}

/// Two-tone FSK demodulator for 5-bit Baudot RTTY at 8 kHz — the Mac's
/// RTTYDemodulator.swift (the source of truth; see its notes).
///
/// The input is mixed down to the centre and decimated to 2 kHz, then each
/// tone is mixed to 0 Hz and low-passed to about the baud rate (decimated to
/// 1 kHz). Their envelopes feed a decision with automatic threshold
/// correction: each tone's level is tracked on its own and the slicing
/// threshold sits halfway between, so selective fading of one tone doesn't
/// turn it into a run of wrong bits. Characters are framed from the
/// mark→space edge of the start bit, each bit integrated over its middle
/// half, and dropped unless the start bit is space and the stop bit mark.
internal sealed class RttyDemodulator
{
    public const double InputRate = 8000;
    private const int Stage1Decimation = 4;
    private const int Stage2Decimation = 2;
    private const double MidRate = InputRate / Stage1Decimation;
    public const double DecisionRate = MidRate / Stage2Decimation;

    private readonly RttySettings _settings;
    /// Where the operator put it; AFC stays within ± half the shift of it.
    private double _anchorHz;

    private readonly Nco _centerNco;
    private readonly DecimatingComplexFir _stage1;
    private readonly Nco _markNco;
    private readonly Nco _spaceNco;
    private readonly DecimatingComplexFir _markFilter;
    private readonly DecimatingComplexFir _spaceFilter;

    private float _markEnvelope;
    private float _spaceEnvelope;
    private readonly float _attack;
    private readonly float _decay;

    private float _previousDecision;
    private Complex _previousMark = Complex.Zero;
    private Complex _previousSpace = Complex.Zero;
    private double _afcErrorHz;
    private int _afcSamples;

    private readonly double _samplesPerBit;
    private bool _framing;
    private int _samplesSinceEdge;
    private readonly float[] _bitSums = new float[7];

    private readonly Baudot.Decoder _baudot;
    private bool _lastWasCarriageReturn;

    /// Average |m − s| / (m + s): near 1 when one tone or the other is
    /// clearly there, 0.2–0.4 for noise alone; a 0 dB RTTY signal still
    /// averages over 0.55.
    private float _contrast;

    public double CenterHz { get; private set; }
    public bool AfcEnabled { get; set; } = true;
    /// 0…1, from the tone contrast.
    public float Quality { get; private set; }

    public RttyDemodulator(RttySettings settings, double centerHz)
    {
        _settings = settings;
        CenterHz = centerHz;
        _anchorHz = centerHz;
        _centerNco = new Nco(centerHz, InputRate);
        var stage1Cutoff = settings.ShiftHz / 2 + settings.Baud * 1.5;
        _stage1 = new DecimatingComplexFir(FirDesign.LowPass(stage1Cutoff, InputRate, 97), Stage1Decimation);
        // Mark is the lower tone unless reversed.
        var markOffset = settings.Reverse ? settings.ShiftHz / 2 : -settings.ShiftHz / 2;
        _markNco = new Nco(markOffset, MidRate);
        _spaceNco = new Nco(-markOffset, MidRate);
        // Narrow enough that the other tone (at least 170 Hz away) is well
        // into the stop band, wide enough to pass the keying.
        var toneTaps = FirDesign.LowPass(settings.Baud * 0.75, MidRate, 161);
        _markFilter = new DecimatingComplexFir(toneTaps, Stage2Decimation);
        _spaceFilter = new DecimatingComplexFir(toneTaps, Stage2Decimation);

        _samplesPerBit = DecisionRate / settings.Baud;
        _attack = (float)Math.Min(1, 4 / _samplesPerBit);
        _decay = (float)(1 / (16 * _samplesPerBit));
        _baudot = new Baudot.Decoder(settings.UnshiftOnSpace);
    }

    /// Moves the centre (a click on the tuning strip): AFC re-anchors there.
    public void SetCenter(double hz)
    {
        CenterHz = hz;
        _anchorHz = hz;
        _centerNco.FrequencyHz = hz;
        _afcErrorHz = 0;
        _afcSamples = 0;
    }

    public void Reset()
    {
        _stage1.Reset();
        _markFilter.Reset();
        _spaceFilter.Reset();
        _markEnvelope = 0;
        _spaceEnvelope = 0;
        _contrast = 0;
        _framing = false;
        _baudot.Reset();
        Quality = 0;
    }

    /// Demodulates 8 kHz samples; returns the characters completed.
    public string Process(float[] samples)
    {
        var output = new StringBuilder();
        foreach (var x in samples)
        {
            var lo = _centerNco.Next();
            if (!_stage1.Push(x * lo.Cos, x * lo.Sin, out var midI, out var midQ))
            {
                continue;
            }
            var m = _markNco.Next();
            var s = _spaceNco.Next();
            var markReady = _markFilter.Push(midI * m.Cos - midQ * m.Sin, midI * m.Sin + midQ * m.Cos, out var markI, out var markQ);
            var spaceReady = _spaceFilter.Push(midI * s.Cos - midQ * s.Sin, midI * s.Sin + midQ * s.Cos, out var spaceI, out var spaceQ);
            if (!markReady || !spaceReady)
            {
                continue;
            }
            var character = Decide(new Complex(markI, markQ), new Complex(spaceI, spaceQ));
            if (character != '\0')
            {
                output.Append(character);
            }
        }
        return output.ToString();
    }

    // Decision and framing (1 kHz)

    private char Decide(Complex mark, Complex space)
    {
        var m = mark.Magnitude;
        var s = space.Magnitude;
        _markEnvelope += (m > _markEnvelope ? _attack : _decay) * (m - _markEnvelope);
        _spaceEnvelope += (s > _spaceEnvelope ? _attack : _decay) * (s - _spaceEnvelope);
        var sum = m + s;
        if (sum > 0)
        {
            _contrast += 0.01f * (MathF.Abs(m - s) / sum - _contrast);
        }
        Quality = Math.Clamp((_contrast - 0.35f) / 0.35f, 0, 1);
        TrackFrequency(mark, space, m, s);

        // Optimal ATC: clip each tone to its own envelope, then slice
        // halfway between the two envelopes.
        var d = MathF.Min(m, _markEnvelope) - MathF.Min(s, _spaceEnvelope) - 0.5f * (_markEnvelope - _spaceEnvelope);
        var character = Frame(d);
        _previousDecision = d;
        return character;
    }

    private char Frame(float d)
    {
        if (!_framing)
        {
            // Waiting for a start bit's mark→space edge.
            if (_previousDecision > 0 && d <= 0)
            {
                _framing = true;
                _samplesSinceEdge = 0;
                Array.Clear(_bitSums);
            }
            return '\0';
        }
        var position = _samplesSinceEdge / _samplesPerBit;
        _samplesSinceEdge++;
        var bit = (int)position;
        var fraction = position - bit;
        if (bit < _bitSums.Length && fraction >= 0.25 && fraction <= 0.75)
        {
            _bitSums[bit] += d;
        }
        // A start bit that wasn't space after all: a glitch.
        if (bit == 0 && fraction > 0.75 && _bitSums[0] >= 0)
        {
            _framing = false;
            return '\0';
        }
        // Start (0), five data bits (1…5), stop (6): decide once the stop
        // bit's middle half is in.
        if (position < 6.75)
        {
            return '\0';
        }
        _framing = false;
        if (_bitSums[6] <= 0)
        {
            return '\0'; // framing error
        }
        byte code = 0;
        for (var k = 0; k < 5; k++)
        {
            if (_bitSums[k + 1] > 0)
            {
                code |= (byte)(1 << k);
            }
        }
        return CharacterFor(code);
    }

    private char CharacterFor(byte code)
    {
        // CR LF, LF CR, CR CR LF… all print one line break.
        if (code == Baudot.CarriageReturn)
        {
            _lastWasCarriageReturn = true;
            return '\n';
        }
        var wasCr = _lastWasCarriageReturn;
        _lastWasCarriageReturn = false;
        var character = _baudot.Decode(code);
        if (character == '\n' && wasCr)
        {
            return '\0';
        }
        return character;
    }

    // AFC

    private void TrackFrequency(Complex mark, Complex space, float m, float s)
    {
        var previousMark = _previousMark;
        var previousSpace = _previousSpace;
        _previousMark = mark;
        _previousSpace = space;
        if (!AfcEnabled || Quality <= 0.3f)
        {
            return;
        }
        // Each tone's own phase rotation says how far it sits from its arm.
        double? errorHz = null;
        if (m > 2 * s && previousMark.MagnitudeSquared > 0)
        {
            errorHz = mark.TimesConjugate(previousMark).Phase * DecisionRate / (2 * Math.PI);
        }
        else if (s > 2 * m && previousSpace.MagnitudeSquared > 0)
        {
            errorHz = space.TimesConjugate(previousSpace).Phase * DecisionRate / (2 * Math.PI);
        }
        if (errorHz is not { } error)
        {
            return;
        }
        _afcErrorHz += 0.01 * (error - _afcErrorHz);
        _afcSamples++;
        if (_afcSamples < 100)
        {
            return;
        }
        _afcSamples = 0;
        var limit = _settings.ShiftHz / 2;
        CenterHz = Math.Min(_anchorHz + limit, Math.Max(_anchorHz - limit, CenterHz + 0.5 * _afcErrorHz));
        _centerNco.FrequencyHz = CenterHz;
        _afcErrorHz *= 0.5;
    }
}

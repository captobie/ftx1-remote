using System.Text;

namespace FTX1RemoteWindows.Services.Digi;

/// BPSK31/BPSK63 demodulator at 8 kHz — the Mac's PSKDemodulator.swift (the
/// source of truth; see its notes).
///
/// The input is mixed down to the carrier and decimated to 16 samples a
/// symbol (two low-pass stages). Symbol timing comes from the amplitude:
/// BPSK's envelope dips at every phase reversal, so the average amplitude at
/// each of the 16 sample slots peaks at the symbol centre. Bits are
/// differential (no phase change = 1, a reversal = 0) and go through the
/// Varicode decoder.
///
/// One complex average does double duty: d²/|d|², with d the phase step
/// between symbols, points the same way every symbol for a clean signal
/// whatever its frequency offset, and is random for noise. Its length is the
/// quality (squelch), its angle half the residual rotation per symbol (AFC,
/// and the decisions are de-rotated by it).
internal sealed class PskDemodulator
{
    public const double InputRate = 8000;
    public const int SamplesPerSymbol = 16;
    private const int Stage1Decimation = 8;
    private const double MidRate = InputRate / Stage1Decimation;
    /// How far AFC may move from where the operator put the carrier.
    public const double AfcLimitHz = 15;

    private readonly double _baud;
    private double _anchorHz;
    private readonly Nco _nco;
    private readonly DecimatingComplexFir _stage1;
    private readonly DecimatingComplexFir _stage2;

    private readonly float[] _syncBins = new float[SamplesPerSymbol];
    private int _slot;
    private int _decisionSlot;
    private Complex _previousSymbol = Complex.Zero;

    private float _averageRe;
    private float _averageIm;
    private readonly Varicode.Decoder _varicode = new();

    public double CenterHz { get; private set; }
    public bool AfcEnabled { get; set; } = true;
    /// 0…1: how cleanly the phase steps land on 0°/180°.
    public float Quality { get; private set; }
    /// Characters print only above this quality.
    public float Squelch { get; set; } = 0.3f;

    public PskDemodulator(double baud, double centerHz)
    {
        _baud = baud;
        CenterHz = centerHz;
        _anchorHz = centerHz;
        _nco = new Nco(centerHz, InputRate);
        _stage1 = new DecimatingComplexFir(FirDesign.LowPass(150, InputRate, 97), Stage1Decimation);
        var symbolRate = baud * SamplesPerSymbol;
        var decimation2 = Math.Max(1, (int)Math.Round(MidRate / symbolRate, MidpointRounding.AwayFromZero));
        _stage2 = new DecimatingComplexFir(FirDesign.LowPass(baud, MidRate, 129), decimation2);
    }

    public void SetCenter(double hz)
    {
        CenterHz = hz;
        _anchorHz = hz;
        _nco.FrequencyHz = hz;
        _averageRe = _averageIm = 0;
    }

    public void Reset()
    {
        _stage1.Reset();
        _stage2.Reset();
        Array.Clear(_syncBins);
        _varicode.Reset();
        _averageRe = _averageIm = 0;
        Quality = 0;
    }

    public string Process(float[] samples)
    {
        var output = new StringBuilder();
        foreach (var x in samples)
        {
            var lo = _nco.Next();
            if (!_stage1.Push(x * lo.Cos, x * lo.Sin, out var midI, out var midQ)
                || !_stage2.Push(midI, midQ, out var zI, out var zQ))
            {
                continue;
            }
            var character = SymbolSample(new Complex(zI, zQ));
            if (character != '\0')
            {
                output.Append(character);
            }
        }
        return output.ToString();
    }

    // 16 samples a symbol

    private char SymbolSample(Complex z)
    {
        _syncBins[_slot] += 0.05f * (z.Magnitude - _syncBins[_slot]);
        var atDecision = _slot == _decisionSlot;
        var result = atDecision ? Symbol(z) : '\0';
        _slot++;
        if (_slot == SamplesPerSymbol)
        {
            _slot = 0;
            _decisionSlot = PeakSlot(_syncBins);
        }
        return result;
    }

    /// The circular centroid of the amplitude above its minimum.
    public static int PeakSlot(float[] bins)
    {
        var floor = bins.Min();
        float x = 0, y = 0;
        for (var k = 0; k < bins.Length; k++)
        {
            var angle = 2 * MathF.PI * k / bins.Length;
            x += (bins[k] - floor) * MathF.Cos(angle);
            y += (bins[k] - floor) * MathF.Sin(angle);
        }
        if (x == 0 && y == 0)
        {
            return 0;
        }
        var position = MathF.Atan2(y, x) / (2 * MathF.PI) * bins.Length;
        if (position < 0)
        {
            position += bins.Length;
        }
        return (int)MathF.Round(position, MidpointRounding.AwayFromZero) % bins.Length;
    }

    private char Symbol(Complex z)
    {
        var d = z.TimesConjugate(_previousSymbol);
        _previousSymbol = z;
        var power = d.MagnitudeSquared;
        if (power <= 0)
        {
            return '\0';
        }
        var unitSquare = d.Squared();
        _averageRe += 0.05f * (unitSquare.Re / power - _averageRe);
        _averageIm += 0.05f * (unitSquare.Im / power - _averageIm);
        var average = new Complex(_averageRe, _averageIm);
        Quality = MathF.Min(1, average.Magnitude);

        // Residual rotation per symbol, from the average (so one noisy
        // symbol doesn't swing it).
        var rotation = average.Phase / 2;
        var corrected = d.Re * MathF.Cos(rotation) + d.Im * MathF.Sin(rotation);
        var bit = corrected > 0;

        if (AfcEnabled && Quality > 0.2f)
        {
            var errorHz = rotation / (2 * Math.PI) * _baud;
            CenterHz = Math.Min(_anchorHz + AfcLimitHz, Math.Max(_anchorHz - AfcLimitHz, CenterHz + 0.02 * errorHz));
            _nco.FrequencyHz = CenterHz;
        }

        if (_varicode.Push(bit) is not { } ascii || Quality < Squelch)
        {
            return '\0';
        }
        return Printable(ascii);
    }

    private static char Printable(byte ascii) => ascii switch
    {
        10 => '\n',
        9 => ' ',
        >= 32 and < 127 => (char)ascii,
        _ => '\0', // CR, other controls
    };
}

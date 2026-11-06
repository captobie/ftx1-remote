namespace FTX1RemoteWindows.Services.Digi;

/// Turns text into transmit audio at 8 kHz, one chunk at a time, pulling
/// characters as it reaches each character boundary — so text typed while
/// transmitting goes out as soon as the character before it is done. The
/// Mac's Modulators.swift.
internal interface IDigiModulator
{
    /// Called as each character starts going out (the transmit echo).
    Action<char>? OnCharacterStarted { get; set; }
    /// The closing tail has been sent.
    bool IsFinished { get; }
    /// <paramref name="count"/> samples, peak level as constructed.
    /// <paramref name="next"/> supplies the next character, or '\0' to idle
    /// (RTTY: LTRS, PSK: reversals).
    float[] Render(int count, Func<char> next);
    /// No more text: send what's in progress, then the tail, then silence.
    void BeginTail();
}

/// AFSK RTTY: phase-continuous tones; start bit, five bits LSB first, 1.5
/// stop bits per character.
internal sealed class RttyModulator : IDigiModulator
{
    public const double SampleRate = 8000;

    public Action<char>? OnCharacterStarted { get; set; }
    public bool IsFinished { get; private set; }

    private readonly double _markHz;
    private readonly double _spaceHz;
    private readonly double _samplesPerBit;
    private readonly float _level;
    private double _phase;

    /// Bits still to send: mark or space and length in bits.
    private readonly Queue<(bool Mark, double Bits)> _pending = new();
    private bool _hasCurrent;
    private bool _currentMark;
    private double _currentSamplesLeft;
    private bool _inFigures;
    private bool _tailing;
    private bool _tailQueued;

    public RttyModulator(double markHz, double spaceHz, double baud, float level)
    {
        _markHz = markHz;
        _spaceHz = spaceHz;
        _level = level;
        _samplesPerBit = SampleRate / baud;
        // Half a second of steady mark, then LTRS to set the shift.
        _pending.Enqueue((true, 0.5 * baud));
        Append(Baudot.Ltrs);
    }

    public void BeginTail() => _tailing = true;

    public float[] Render(int count, Func<char> next)
    {
        var output = new float[count];
        for (var n = 0; n < count; n++)
        {
            if (!_hasCurrent || _currentSamplesLeft <= 0)
            {
                if (!Advance(next))
                {
                    return output; // finished: rest silent
                }
            }
            var tone = _currentMark ? _markHz : _spaceHz;
            output[n] = _level * (float)Math.Sin(_phase);
            _phase += 2 * Math.PI * tone / SampleRate;
            if (_phase > 2 * Math.PI)
            {
                _phase -= 2 * Math.PI;
            }
            _currentSamplesLeft--;
        }
        return output;
    }

    /// Moves to the next bit, filling the queue first if it's empty.
    private bool Advance(Func<char> next)
    {
        var carry = _hasCurrent ? _currentSamplesLeft : 0; // ≤ 0: keeps bit timing exact
        if (_pending.Count == 0)
        {
            if (_tailQueued)
            {
                IsFinished = true;
                _hasCurrent = false;
                return false;
            }
            if (_tailing)
            {
                // Finish on LTRS and a moment of mark.
                Append(Baudot.Ltrs);
                _pending.Enqueue((true, 0.2 * SampleRate / _samplesPerBit));
                _tailQueued = true;
            }
            else
            {
                var character = next();
                if (character != '\0')
                {
                    Enqueue(character);
                }
                if (_pending.Count == 0)
                {
                    Append(Baudot.Ltrs); // unsendable or nothing typed: idle
                }
            }
        }
        var bit = _pending.Dequeue();
        _hasCurrent = true;
        _currentMark = bit.Mark;
        _currentSamplesLeft = bit.Bits * _samplesPerBit + carry;
        return true;
    }

    private void Enqueue(char character)
    {
        var codes = Codes(character, ref _inFigures);
        if (codes.Count == 0)
        {
            return;
        }
        OnCharacterStarted?.Invoke(character);
        foreach (var code in codes)
        {
            Append(code);
        }
    }

    private void Append(byte code)
    {
        _pending.Enqueue((false, 1));
        for (var k = 0; k < 5; k++)
        {
            _pending.Enqueue((((code >> k) & 1) == 1, 1));
        }
        _pending.Enqueue((true, 1.5));
    }

    /// The codes for one character, shifting as needed. A space drops back
    /// to letters on both ends (unshift on space), so figures after a space
    /// get a fresh FIGS.
    public static List<byte> Codes(char character, ref bool inFigures)
    {
        var upper = char.ToUpperInvariant(character);
        if (upper is '\n' or '\r')
        {
            return [Baudot.CarriageReturn, Baudot.LineFeed];
        }
        if (upper == ' ')
        {
            inFigures = false;
            return [Baudot.Space];
        }
        var letter = upper == '\0' ? -1 : Array.IndexOf(Baudot.Letters, upper);
        if (letter >= 0)
        {
            var codes = inFigures ? new List<byte> { Baudot.Ltrs, (byte)letter } : [(byte)letter];
            inFigures = false;
            return codes;
        }
        var figure = upper == '\0' ? -1 : Array.IndexOf(Baudot.Figures, upper);
        if (figure >= 0)
        {
            var codes = inFigures ? new List<byte> { (byte)figure } : [Baudot.Figs, (byte)figure];
            inFigures = true;
            return codes;
        }
        return [];
    }
}

/// BPSK31/63: a reversal (0) swings the amplitude through zero with a cosine
/// over the symbol, a 1 holds it. Preamble and idle are reversals; the tail
/// is steady carrier.
internal sealed class PskModulator : IDigiModulator
{
    public const double SampleRate = 8000;
    public const int PreambleSymbols = 32;
    public const int TailSymbols = 32;

    public Action<char>? OnCharacterStarted { get; set; }
    public bool IsFinished { get; private set; }

    private readonly double _carrierHz;
    private readonly int _samplesPerSymbol;
    private readonly float _level;
    private double _phase;
    private float _sign = 1;

    private readonly Queue<bool> _pending;
    private bool _bit;
    private int _sampleInSymbol;
    private bool _started;
    private bool _tailing;
    private bool _tailQueued;

    public PskModulator(double carrierHz, double baud, float level)
    {
        _carrierHz = carrierHz;
        _level = level;
        _samplesPerSymbol = (int)Math.Round(SampleRate / baud, MidpointRounding.AwayFromZero);
        _pending = new Queue<bool>(Enumerable.Repeat(false, PreambleSymbols));
    }

    public void BeginTail() => _tailing = true;

    public float[] Render(int count, Func<char> next)
    {
        var output = new float[count];
        for (var n = 0; n < count; n++)
        {
            if (!_started || _sampleInSymbol == _samplesPerSymbol)
            {
                if (_started && !_bit)
                {
                    _sign = -_sign;
                }
                if (!Advance(next))
                {
                    return output;
                }
                _started = true;
                _sampleInSymbol = 0;
            }
            var envelope = _bit
                ? _sign
                : _sign * (float)Math.Cos(Math.PI * _sampleInSymbol / _samplesPerSymbol);
            output[n] = _level * envelope * (float)Math.Cos(_phase);
            _phase += 2 * Math.PI * _carrierHz / SampleRate;
            if (_phase > 2 * Math.PI)
            {
                _phase -= 2 * Math.PI;
            }
            _sampleInSymbol++;
        }
        return output;
    }

    private bool Advance(Func<char> next)
    {
        if (_pending.Count == 0)
        {
            if (_tailQueued)
            {
                IsFinished = true;
                return false;
            }
            if (_tailing)
            {
                // Two zeros end the last character, then steady carrier.
                _pending.Enqueue(false);
                _pending.Enqueue(false);
                for (var k = 0; k < TailSymbols; k++)
                {
                    _pending.Enqueue(true);
                }
                _tailQueued = true;
            }
            else
            {
                var character = next();
                if (character != '\0' && Bits(character) is { } bits)
                {
                    OnCharacterStarted?.Invoke(character);
                    foreach (var b in bits)
                    {
                        _pending.Enqueue(b);
                    }
                }
                else
                {
                    _pending.Enqueue(false); // idle
                }
            }
        }
        _bit = _pending.Dequeue();
        return true;
    }

    /// Varicode bits plus the "00" separator; null for non-ASCII.
    public static List<bool>? Bits(char character)
    {
        var chars = character == '\n' ? new[] { '\r', '\n' } : [character];
        var bits = new List<bool>();
        foreach (var c in chars)
        {
            if (c >= 128)
            {
                return null;
            }
            bits.AddRange(Varicode.Codes[c].Select(b => b == '1'));
            bits.Add(false);
            bits.Add(false);
        }
        return bits;
    }
}

namespace FTX1RemoteWindows.Services.Digi;

/// ITA2 / US-TTY Baudot: the 5-bit code amateur RTTY uses — the Mac's
/// Baudot.swift. Letters and figures share the 32 codes; LTRS (31) and FIGS
/// (27) switch between them. The figures case is the US TTY one (S = bell,
/// J = apostrophe), which is what most amateur software sends.
public static class Baudot
{
    public const byte Ltrs = 31;
    public const byte Figs = 27;
    public const byte Space = 4;
    public const byte LineFeed = 2;
    public const byte CarriageReturn = 8;

    /// '\0' = no printable character (NUL, the shifts, CR, bell).
    public static readonly char[] Letters =
    [
        '\0', 'E', '\n', 'A', ' ', 'S', 'I', 'U',
        '\0', 'D', 'R', 'J', 'N', 'F', 'C', 'K',
        'T', 'Z', 'L', 'W', 'H', 'Y', 'P', 'Q',
        'O', 'B', 'G', '\0', 'M', 'X', 'V', '\0',
    ];

    public static readonly char[] Figures =
    [
        '\0', '3', '\n', '-', ' ', '\0', '8', '7',
        '\0', '$', '4', '\'', ',', '!', ':', '(',
        '5', '"', ')', '2', '#', '6', '0', '1',
        '9', '?', '&', '\0', '.', '/', ';', '\0',
    ];

    /// Turns 5-bit codes into text, keeping the LTRS/FIGS state.
    public sealed class Decoder(bool unshiftOnSpace = true)
    {
        /// A space in figures case drops back to letters, as most senders
        /// expect (a lost LTRS then costs one word, not the rest of the line).
        public bool UnshiftOnSpace { get; set; } = unshiftOnSpace;
        private bool _inFigures;

        /// '\0' when the code prints nothing.
        public char Decode(byte code)
        {
            code &= 0x1F;
            switch (code)
            {
                case Ltrs:
                    _inFigures = false;
                    return '\0';
                case Figs:
                    _inFigures = true;
                    return '\0';
                default:
                    var character = (_inFigures ? Figures : Letters)[code];
                    if (code == Space && UnshiftOnSpace)
                    {
                        _inFigures = false;
                    }
                    return character;
            }
        }

        public void Reset() => _inFigures = false;
    }

    /// Text → codes, shifting as needed (for tests and test signals).
    /// Unknown characters are skipped; lowercase is sent as uppercase.
    public static List<byte> Encode(string text)
    {
        var codes = new List<byte> { Ltrs };
        var inFigures = false;
        foreach (var character in text.ToUpperInvariant())
        {
            if (character == '\n')
            {
                codes.Add(CarriageReturn);
                codes.Add(LineFeed);
                continue;
            }
            var letter = Array.IndexOf(Letters, character);
            if (letter >= 0 && letter != LineFeed && character != '\0')
            {
                if (inFigures && letter != Space)
                {
                    codes.Add(Ltrs);
                    inFigures = false;
                }
                codes.Add((byte)letter);
                // Mirror unshift-on-space on the receiving side.
                if (letter == Space)
                {
                    inFigures = false;
                }
                continue;
            }
            var figure = Array.IndexOf(Figures, character);
            if (figure >= 0 && character != '\0')
            {
                if (!inFigures)
                {
                    codes.Add(Figs);
                    inFigures = true;
                }
                codes.Add((byte)figure);
            }
        }
        return codes;
    }
}

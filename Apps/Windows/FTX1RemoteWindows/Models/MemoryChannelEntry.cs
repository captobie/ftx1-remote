namespace FTX1RemoteWindows.Models;

/// One programmed memory channel, read with raw "MR" (MEMORY CHANNEL READ)
/// and "MT" (TAG) — the rows of the memory list window. The C# port of
/// Sources/FTX1Core/RigState/MemoryChannelEntry.swift, which stays the
/// source of truth (its field offsets are unit-tested against real rig
/// answers). A blank channel answers "MR" with "?;", so it never becomes
/// an entry.
public sealed class MemoryChannelEntry
{
    public int Channel { get; set; }
    public long FrequencyHz { get; set; }
    /// The raw "MR" P6 mode character (the same codes as "MD"), kept raw
    /// because a memory can hold modes RigMode has no member for.
    public string ModeCode { get; set; } = "";
    /// "MR" P8: 0 OFF, 1 CTCSS ENC/DEC, 2 CTCSS ENC, 3 DCS, 4 PR FREQ, 5 REV TONE.
    public int ToneMode { get; set; }
    /// "MR" P10: 0 simplex, 1 plus shift, 2 minus shift.
    public int Shift { get; set; }
    /// From "MT", trimmed; null when the channel has no tag.
    public string? Tag { get; set; }

    /// Parses an "MR" answer, e.g. "MR00001431075000+000000H10000;": P1
    /// channel (5), P2 frequency in Hz (9), P3 clarifier sign + offset (5),
    /// P4 RX CLAR, P5 TX CLAR, P6 mode, P7 VFO/memory type, P8 tone mode,
    /// P9 "00" (2), P10 shift — 27 characters after "MR". Null for "?;"
    /// (blank channel) or anything else that doesn't fit.
    public static MemoryChannelEntry? Parse(string reply)
    {
        if (!reply.StartsWith("MR", StringComparison.Ordinal))
        {
            return null;
        }
        var body = reply[2..].TrimEnd(';');
        if (body.Length != 27
            || !int.TryParse(body.AsSpan(0, 5), out var channel)
            || !long.TryParse(body.AsSpan(5, 9), out var hz)
            || !char.IsAsciiDigit(body[23])
            || !char.IsAsciiDigit(body[26]))
        {
            return null;
        }
        return new MemoryChannelEntry
        {
            Channel = channel,
            FrequencyHz = hz,
            ModeCode = body[21].ToString(),
            ToneMode = body[23] - '0',
            Shift = body[26] - '0',
        };
    }

    /// Same contents — lets a refresh that finds nothing new skip
    /// rebuilding the window's rows.
    public bool SameAs(MemoryChannelEntry other) =>
        Channel == other.Channel && FrequencyHz == other.FrequencyHz && ModeCode == other.ModeCode
        && ToneMode == other.ToneMode && Shift == other.Shift && Tag == other.Tag;

    /// The mode's name as the CAT manual's OPERATING MODE table spells it,
    /// or the raw code if it isn't in that table.
    public string ModeName => ModeCode switch
    {
        "1" => "LSB",
        "2" => "USB",
        "3" => "CW-U",
        "4" => "FM",
        "5" => "AM",
        "6" => "RTTY-L",
        "7" => "CW-L",
        "8" => "DATA-L",
        "9" => "RTTY-U",
        "A" => "DATA-FM",
        "B" => "FM-N",
        "C" => "DATA-U",
        "D" => "AM-N",
        "E" => "PSK",
        "F" => "DATA-FM-N",
        "H" => "C4FM-DN",
        "I" => "C4FM-VW",
        _ => ModeCode,
    };

    /// Short tone label for the list, empty when off.
    public string ToneName => ToneMode switch
    {
        1 => "TSQL",
        2 => "TONE",
        3 => "DCS",
        4 => "PR FREQ",
        5 => "REV TONE",
        _ => "",
    };

    /// "+"/"−" for a repeater shift, empty for simplex.
    public string ShiftName => Shift switch
    {
        1 => "+",
        2 => "−",
        _ => "",
    };
}

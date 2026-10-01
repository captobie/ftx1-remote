namespace FTX1RemoteWindows.Services;

/// One AX.25 address: a 6-character callsign (space padding trimmed) plus
/// SSID, and whether it's the last address in the address field. Port of
/// AX25Address in Sources/FTX1Core/APRS/AX25Frame.swift.
public sealed record Ax25Address(string Callsign, int Ssid, bool IsLast)
{
    /// "N0CALL-9", or the bare callsign for SSID 0.
    public string DisplayString => Ssid == 0 ? Callsign : $"{Callsign}-{Ssid}";
}

/// A parsed AX.25 UI frame (the only kind APRS uses). Port of AX25Frame.
public sealed record Ax25Frame(
    Ax25Address Destination,
    Ax25Address Source,
    IReadOnlyList<Ax25Address> Digipeaters,
    byte Control,
    byte Pid,
    byte[] Info)
{
    /// Everything between the flags except the FCS, which the caller has
    /// already checked and stripped.
    public static Ax25Frame? Parse(byte[] bytes)
    {
        if (bytes.Length < 16)
        {
            return null;
        }
        if (ParseAddress(bytes, 0) is not { IsLast: false } destination)
        {
            return null;
        }
        if (ParseAddress(bytes, 7) is not { } source)
        {
            return null;
        }

        var digipeaters = new List<Ax25Address>();
        var offset = 14;
        var last = source.IsLast;
        while (!last)
        {
            if (digipeaters.Count >= 8 || ParseAddress(bytes, offset) is not { } digi)
            {
                return null;
            }
            digipeaters.Add(digi);
            last = digi.IsLast;
            offset += 7;
        }

        if (bytes.Length < offset + 2)
        {
            return null;
        }
        return new Ax25Frame(destination, source, digipeaters, bytes[offset], bytes[offset + 1], bytes[(offset + 2)..]);
    }

    /// 7 bytes: six callsign characters, each shifted left one bit, then the
    /// SSID byte (0SSSSRRE — SSID in bits 1-4, end-of-addresses in bit 0).
    private static Ax25Address? ParseAddress(byte[] bytes, int offset)
    {
        if (bytes.Length < offset + 7)
        {
            return null;
        }
        var chars = new char[6];
        for (var i = 0; i < 6; i++)
        {
            chars[i] = (char)(bytes[offset + i] >> 1);
        }
        var ssidByte = bytes[offset + 6];
        return new Ax25Address(new string(chars).Trim(), (ssidByte >> 1) & 0x0F, (ssidByte & 0x01) != 0);
    }
}

/// AX.25's frame check sequence: CRC-16/X-25 (poly 0x8408 reflected, init
/// 0xFFFF, complemented). The CRC of ASCII "123456789" is 0x906E.
public static class Ax25Fcs
{
    public static ushort Compute(ReadOnlySpan<byte> bytes)
    {
        ushort crc = 0xFFFF;
        foreach (var b in bytes)
        {
            crc ^= b;
            for (var i = 0; i < 8; i++)
            {
                crc = (crc & 1) != 0 ? (ushort)((crc >> 1) ^ 0x8408) : (ushort)(crc >> 1);
            }
        }
        return (ushort)(crc ^ 0xFFFF);
    }
}

/// Recovers AX.25 frames from <see cref="AfskDemodulator"/>'s line bits.
/// Port of AX25FrameDecoder: buffers bits across calls, finds flag
/// boundaries (01111110) first, then destuffs and parses each segment
/// between two flags on its own.
public sealed class Ax25FrameDecoder
{
    /// Cumulative counts since this decoder was created, for the heartbeat
    /// log: flags climbing with CRC/destuff failures but no frames points at
    /// a corrupt signal, flags staying ~0 at no signal at all.
    public sealed class DecodeStats
    {
        public int FlagsFound { get; internal set; }
        public int DestuffFailures { get; internal set; }
        public int TooShortFailures { get; internal set; }
        public int CrcFailures { get; internal set; }
        public int AddressParseFailures { get; internal set; }
        public int FramesDecoded { get; internal set; }
    }

    /// Caps unsynced audio (no flag yet) — well past the longest APRS frame.
    private const int MaxUnsyncedBits = 4096;

    private readonly List<bool> _bits = [];
    private readonly List<int> _flagStarts = [];

    public DecodeStats Stats { get; } = new();

    /// Feeds line bits and returns any complete, CRC-valid frames found.
    public List<Ax25Frame> Process(List<bool> newBits)
    {
        _bits.AddRange(newBits);

        _flagStarts.Clear();
        var window = 0;
        for (var i = 0; i < _bits.Count; i++)
        {
            window = ((window << 1) | (_bits[i] ? 1 : 0)) & 0xFF;
            if (i >= 7 && window == 0b0111_1110)
            {
                _flagStarts.Add(i - 7);
            }
        }
        Stats.FlagsFound += _flagStarts.Count;

        var frames = new List<Ax25Frame>();
        if (_flagStarts.Count < 2)
        {
            if (_bits.Count > MaxUnsyncedBits)
            {
                _bits.RemoveRange(0, _bits.Count - MaxUnsyncedBits);
            }
            return frames;
        }

        for (var i = 0; i < _flagStarts.Count - 1; i++)
        {
            var segmentStart = _flagStarts[i] + 8;
            var segmentEnd = _flagStarts[i + 1];
            if (segmentEnd <= segmentStart)
            {
                continue;
            }
            var frame = DecodeSegment(_bits.GetRange(segmentStart, segmentEnd - segmentStart));
            if (frame is not null)
            {
                Stats.FramesDecoded++;
                frames.Add(frame);
            }
        }

        // Keep the bits from the last flag on: a frame may still be
        // arriving after it.
        _bits.RemoveRange(0, _flagStarts[^1]);
        return frames;
    }

    private Ax25Frame? DecodeSegment(List<bool> segmentBits)
    {
        if (Destuff(segmentBits) is not { } destuffed)
        {
            Stats.DestuffFailures++;
            return null;
        }
        if (BitsToBytes(destuffed) is not { Length: >= 18 } bytes)
        {
            Stats.TooShortFailures++;
            return null;
        }
        var payload = bytes[..^2];
        var receivedFcs = (ushort)(bytes[^2] | (bytes[^1] << 8));
        if (Ax25Fcs.Compute(payload) != receivedFcs)
        {
            Stats.CrcFailures++;
            return null;
        }
        if (Ax25Frame.Parse(payload) is not { } frame)
        {
            Stats.AddressParseFailures++;
            return null;
        }
        return frame;
    }

    /// Drops the 0 the sender stuffs after every five 1s. Six or more 1s
    /// inside a flag-delimited segment means a bit error or a mis-synced
    /// segment, so it's rejected rather than forced into a frame.
    private static List<bool>? Destuff(List<bool> segmentBits)
    {
        var result = new List<bool>(segmentBits.Count);
        var ones = 0;
        foreach (var bit in segmentBits)
        {
            if (bit)
            {
                if (++ones > 5)
                {
                    return null;
                }
                result.Add(true);
            }
            else
            {
                if (ones != 5)
                {
                    result.Add(false);
                }
                ones = 0;
            }
        }
        return result;
    }

    /// AX.25 sends each byte least-significant bit first.
    private static byte[]? BitsToBytes(List<bool> bits)
    {
        if (bits.Count == 0 || bits.Count % 8 != 0)
        {
            return null;
        }
        var bytes = new byte[bits.Count / 8];
        for (var i = 0; i < bytes.Length; i++)
        {
            byte value = 0;
            for (var b = 0; b < 8; b++)
            {
                if (bits[i * 8 + b])
                {
                    value |= (byte)(1 << b);
                }
            }
            bytes[i] = value;
        }
        return bytes;
    }
}

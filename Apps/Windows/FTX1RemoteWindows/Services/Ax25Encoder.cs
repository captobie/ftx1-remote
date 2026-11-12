namespace FTX1RemoteWindows.Services;

/// Builds what a TNC sends for one APRS packet: an AX.25 UI frame
/// (addresses, control 0x03, PID 0xF0, info, FCS), HDLC flags with bit
/// stuffing, NRZI, and Bell 202 AFSK at 1200 baud (mark 1200 Hz, space
/// 2200 Hz, continuous phase). The inverse of <see cref="AfskDemodulator"/> +
/// <see cref="Ax25FrameDecoder"/>. Port of Sources/FTX1Core/APRS/
/// AX25Encoder.swift, which stays the source of truth.
public static class Ax25Encoder
{
    public readonly record struct Address(string Callsign, int Ssid);

    /// An address as typed: "N0CALL", "N0CALL-9", "WIDE2-1". Null when the
    /// callsign is empty, longer than 6 characters, not letters/digits, or
    /// the SSID isn't 0–15.
    public static Address? ParseAddress(string text)
    {
        var parts = text.Trim(' ', '\t').ToUpperInvariant().Split('-');
        if (parts.Length is not (1 or 2))
        {
            return null;
        }
        var callsign = parts[0];
        if (callsign.Length is < 1 or > 6 || !callsign.All(c => c is (>= 'A' and <= 'Z') or (>= '0' and <= '9')))
        {
            return null;
        }
        var ssid = 0;
        if (parts.Length == 2)
        {
            if (!parts[1].All(char.IsAsciiDigit) || !int.TryParse(parts[1], out ssid) || ssid is < 0 or > 15)
            {
                return null;
            }
        }
        return new Address(callsign, ssid);
    }

    /// A digipeater path as typed ("WIDE1-1,WIDE2-1"); empty text = no path.
    /// Null when an entry isn't a valid address or there are more than 8.
    public static List<Address>? ParsePath(string text)
    {
        var entries = text.Split(',').Select(e => e.Trim(' ', '\t')).Where(e => e.Length > 0).ToList();
        if (entries.Count > 8)
        {
            return null;
        }
        var result = new List<Address>();
        foreach (var entry in entries)
        {
            if (ParseAddress(entry) is not { } address)
            {
                return null;
            }
            result.Add(address);
        }
        return result;
    }

    /// The frame's bytes, FCS included (no flags).
    public static byte[] Frame(Address destination, Address source, IReadOnlyList<Address> path, byte[] info)
    {
        var bytes = new List<byte>();
        bytes.AddRange(EncodeAddress(destination, last: false));
        bytes.AddRange(EncodeAddress(source, last: path.Count == 0));
        for (var i = 0; i < path.Count; i++)
        {
            bytes.AddRange(EncodeAddress(path[i], last: i == path.Count - 1));
        }
        bytes.Add(0x03); // UI frame
        bytes.Add(0xF0); // no layer 3
        bytes.AddRange(info);
        var fcs = Ax25Fcs.Compute(bytes.ToArray());
        bytes.Add((byte)(fcs & 0xFF));
        bytes.Add((byte)(fcs >> 8));
        return bytes.ToArray();
    }

    /// Line bits, LSB first: <paramref name="leadFlags"/> flags, the
    /// bit-stuffed frame, <paramref name="tailFlags"/> flags.
    public static List<bool> LineBits(byte[] frame, int leadFlags, int tailFlags)
    {
        var bits = new List<bool>((leadFlags + tailFlags) * 8 + frame.Length * 10);
        for (var i = 0; i < leadFlags; i++)
        {
            AddByte(bits, 0x7E);
        }
        var ones = 0;
        foreach (var b in frame)
        {
            for (var i = 0; i < 8; i++)
            {
                var bit = (b >> i & 1) == 1;
                bits.Add(bit);
                ones = bit ? ones + 1 : 0;
                if (ones == 5)
                {
                    bits.Add(false);
                    ones = 0;
                }
            }
        }
        for (var i = 0; i < tailFlags; i++)
        {
            AddByte(bits, 0x7E);
        }
        return bits;
    }

    /// Bell 202 audio for the line bits (NRZI: a 0 is a change of tone, a 1
    /// none; starts on mark).
    public static float[] Afsk(IReadOnlyList<bool> lineBits, double sampleRate, float amplitude)
    {
        var samplesPerBit = sampleRate / 1200;
        var samples = new List<float>((int)(lineBits.Count * samplesPerBit) + 1);
        var mark = true;
        var phase = 0.0;
        var bitEnd = 0.0;
        var index = 0;
        foreach (var bit in lineBits)
        {
            if (!bit)
            {
                mark = !mark;
            }
            var step = 2 * Math.PI * (mark ? 1200 : 2200) / sampleRate;
            bitEnd += samplesPerBit;
            while (index < bitEnd)
            {
                samples.Add(amplitude * (float)Math.Sin(phase));
                phase += step;
                index++;
            }
            phase %= 2 * Math.PI;
        }
        return samples.ToArray();
    }

    /// Flags for <paramref name="seconds"/> of preamble (TXDELAY) at 1200
    /// baud, at least 2.
    public static int Flags(double seconds) => Math.Max(2, (int)Math.Ceiling(seconds * 1200 / 8));

    private static byte[] EncodeAddress(Address address, bool last)
    {
        var bytes = new byte[7];
        var callsign = address.Callsign.ToUpperInvariant();
        for (var i = 0; i < 6; i++)
        {
            bytes[i] = (byte)((i < callsign.Length ? callsign[i] : ' ') << 1);
        }
        bytes[6] = (byte)(0x60 | (address.Ssid & 0x0F) << 1 | (last ? 1 : 0));
        return bytes;
    }

    private static void AddByte(List<bool> bits, byte value)
    {
        for (var i = 0; i < 8; i++)
        {
            bits.Add((value >> i & 1) == 1);
        }
    }
}

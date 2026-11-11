using System.Globalization;
using System.Text;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

// The KiwiSDR sound/waterfall stream protocol — a port of the Mac's
// Sources/FTX1Core/KiwiSDR/KiwiProtocol.swift, which stays the source of
// truth (and Tests/KiwiSDRFixtures/ the recorded frames). Pure parsing and
// command building, no networking and no WinUI types, so the test project
// compiles it directly.

public abstract record KiwiFrame
{
    public sealed record Message(IReadOnlyList<KiwiMessageItem> Items) : KiwiFrame;
    public sealed record Sound(KiwiSoundFrame Frame) : KiwiFrame;
    public sealed record Waterfall(KiwiWaterfallFrame Frame) : KiwiFrame;
    public sealed record Other(string Tag) : KiwiFrame;
}

public readonly record struct KiwiMessageItem(string Name, string? Value);

[Flags]
public enum KiwiSoundFlags : byte
{
    None = 0,
    LowPassFilter = 0x01,
    AdcOverflow = 0x02,
    NewFrequency = 0x04,
    Stereo = 0x08,
    Compressed = 0x10,
    Restart = 0x20,
    LittleEndian = 0x80,
}

/// One "SND" frame: flags, sequence, S-meter, then the samples' bytes.
public sealed class KiwiSoundFrame
{
    public KiwiSoundFlags Flags { get; }
    public uint Sequence { get; }
    public ushort SmeterRaw { get; }
    /// The sample bytes after the 10-byte header ("SND" + 7).
    public byte[] Payload { get; }

    /// dBm = 0.1 × raw − 127.
    public double SmeterDbm => 0.1 * SmeterRaw - 127;

    private KiwiSoundFrame(KiwiSoundFlags flags, uint sequence, ushort smeter, byte[] payload)
    {
        Flags = flags;
        Sequence = sequence;
        SmeterRaw = smeter;
        Payload = payload;
    }

    public static KiwiSoundFrame? TryParse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 10)
        {
            return null;
        }
        var sequence = (uint)(bytes[4] | bytes[5] << 8 | bytes[6] << 16 | bytes[7] << 24);
        var smeter = (ushort)(bytes[8] << 8 | bytes[9]);
        return new KiwiSoundFrame((KiwiSoundFlags)bytes[3], sequence, smeter, bytes[10..].ToArray());
    }

    /// Uncompressed mono samples: Int16, big-endian unless the frame says
    /// little-endian. Empty for compressed or stereo frames.
    public short[] PcmSamples()
    {
        if (Flags.HasFlag(KiwiSoundFlags.Compressed) || Flags.HasFlag(KiwiSoundFlags.Stereo))
        {
            return [];
        }
        var little = Flags.HasFlag(KiwiSoundFlags.LittleEndian);
        var samples = new short[Payload.Length / 2];
        for (var i = 0; i < samples.Length; i++)
        {
            int a = Payload[2 * i], b = Payload[2 * i + 1];
            samples[i] = (short)(little ? a | b << 8 : a << 8 | b);
        }
        return samples;
    }
}

/// One "W/F" frame: a byte, x_bin (UInt32 LE), flags &lt;&lt; 16 | zoom
/// (UInt32 LE), sequence (UInt32 LE), then one byte per bin (uncompressed,
/// "SET wf_comp=0"). x_bin and zoom are what the server used for *this* row
/// — rows still in flight after a pan or zoom carry the old ones, so place
/// every row by its own header.
public sealed class KiwiWaterfallFrame
{
    public const ushort CompressedFlag = 0x0001;

    public int XBin { get; }
    public int Zoom { get; }
    public ushort Flags { get; }
    public uint Sequence { get; }
    /// One byte per bin, lowest frequency first.
    public byte[] Bins { get; }

    public bool IsCompressed => (Flags & CompressedFlag) != 0;

    public KiwiWaterfallFrame(int xBin, int zoom, ushort flags, uint sequence, byte[] bins)
    {
        XBin = xBin;
        Zoom = zoom;
        Flags = flags;
        Sequence = sequence;
        Bins = bins;
    }

    public static KiwiWaterfallFrame? TryParse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 16)
        {
            return null;
        }
        var zoomWord = U32(bytes, 8);
        return new KiwiWaterfallFrame((int)U32(bytes, 4), (int)(zoomWord & 0xFFFF), (ushort)(zoomWord >> 16),
                                      U32(bytes, 12), bytes[16..].ToArray());
    }

    private static uint U32(ReadOnlySpan<byte> bytes, int at) =>
        (uint)(bytes[at] | bytes[at + 1] << 8 | bytes[at + 2] << 16 | bytes[at + 3] << 24);

    /// The Kiwi's dB_wire_to_dBm: byte − 255 + wf_cal. 55 and below (≤ −200
    /// dBm before calibration) marks a masked bin.
    public static int Dbm(byte value, int cal) => value - 255 + cal;
}

public static class KiwiProtocol
{
    // MARK: Server frames

    /// Parses one binary WebSocket frame. Null if it is too short for a tag.
    public static KiwiFrame? ParseFrame(ReadOnlySpan<byte> data)
    {
        if (data.Length < 3)
        {
            return null;
        }
        var tag = Encoding.UTF8.GetString(data[..3]);
        switch (tag)
        {
            case "MSG":
                // Byte 3 is a separator/flag byte the page skips too.
                var text = data.Length > 4 ? Encoding.UTF8.GetString(data[4..]) : "";
                return new KiwiFrame.Message(ParseMessage(text));
            case "SND":
                return KiwiSoundFrame.TryParse(data) is { } sound ? new KiwiFrame.Sound(sound) : new KiwiFrame.Other(tag);
            case "W/F":
                return KiwiWaterfallFrame.TryParse(data) is { } row ? new KiwiFrame.Waterfall(row) : new KiwiFrame.Other(tag);
            default:
                return new KiwiFrame.Other(tag);
        }
    }

    /// "a=1 b c=%20x" → [(a, "1"), (b, null), (c, " x")]. Values are
    /// percent-decoded; a key without "=" has a null value.
    public static List<KiwiMessageItem> ParseMessage(string text)
    {
        var items = new List<KiwiMessageItem>();
        foreach (var pair in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            if (eq < 0)
            {
                items.Add(new KiwiMessageItem(pair, null));
                continue;
            }
            var raw = pair[(eq + 1)..];
            string value;
            try
            {
                value = Uri.UnescapeDataString(raw);
            }
            catch (UriFormatException)
            {
                value = raw;
            }
            items.Add(new KiwiMessageItem(pair[..eq], value));
        }
        return items;
    }

    // MARK: Client commands

    /// "SET auth t=kiwi p=&lt;password&gt;", the password percent-encoded so
    /// a space or "&amp;" can't split the command.
    public static string Auth(string password) => $"SET auth t=kiwi p={PercentEncode(password)}";

    public static string AudioRateOk(int inRate, int outRate = 44100) => $"SET AR OK in={inRate} out={outRate}";

    /// Sent once sample_rate arrives, in kiwiclient's order (the tune
    /// follows). A new connection starts with the blanker and filter off, so
    /// their commands go out only when they are on.
    public static List<string> SetupCommands(string identUser, bool compression, KiwiReceiverSettings receiver)
    {
        var commands = new List<string>
        {
            "SET squelch=0 max=0",
            "SET genattn=0",
            "SET gen=0 mix=-1",
            receiver.AgcCommand,
            $"SET compression={(compression ? 1 : 0)}",
            $"SET ident_user={PercentEncode(identUser)}",
        };
        if (receiver.NoiseBlanker != KiwiNoiseBlanker.Off)
        {
            commands.AddRange(receiver.NoiseBlankerCommands);
        }
        if (receiver.NoiseFilter != KiwiNoiseFilter.Off)
        {
            commands.AddRange(receiver.NoiseFilterCommands);
        }
        return commands;
    }

    /// "SET mod=usb low_cut=300 high_cut=2700 freq=14074.000". carrierHz is
    /// what the Kiwi calls freq_car — see <see cref="KiwiSdrModeExtensions.CarrierHz"/>.
    public static string Tune(int carrierHz, KiwiSdrMode mode, int lowCut, int highCut)
    {
        var kHz = (carrierHz / 1000.0).ToString("F3", CultureInfo.InvariantCulture);
        return $"SET mod={mode.KiwiToken()} low_cut={lowCut} high_cut={highCut} freq={kHz}";
    }

    public const string Keepalive = "SET keepalive";

    // MARK: Waterfall commands

    /// Sent once the waterfall stream's wf_setup arrives (the Kiwi page's
    /// order): full span first, a fixed dB window (colouring is done here),
    /// uncompressed rows, the fastest rate (~19–23 rows a second).
    public static List<string> WaterfallSetupCommands(string identUser) =>
    [
        "SET zoom=0 start=0",
        "SET maxdb=0 mindb=-100",
        "SET wf_comp=0",
        "SET wf_speed=4",
        $"SET ident_user={PercentEncode(identUser)}",
    ];

    /// "SET zoom=8 start=3923264": the waterfall's zoom and left edge, in
    /// bins at the maximum zoom (<see cref="KiwiWaterfallGeometry"/>).
    public static string WaterfallView(int zoom, int start) => $"SET zoom={zoom} start={start}";

    /// Unreserved characters only, like JavaScript's encodeURIComponent.
    public static string PercentEncode(string text)
    {
        var builder = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(text))
        {
            var c = (char)b;
            if (b < 128 && (char.IsAsciiLetterOrDigit(c) || "-_.!~*'()".Contains(c)))
            {
                builder.Append(c);
            }
            else
            {
                builder.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
        }
        return builder.ToString();
    }

    /// The ws://host:port/&lt;timestamp&gt;/SND URL for "host" or
    /// "host:port" (8073 when absent). Null if it can't form a URL.
    public static Uri? SoundUrl(string hostPort, long timestamp) => StreamUrl(hostPort, "SND", timestamp);

    /// The /&lt;timestamp&gt;/W/F URL. Give it the sound stream's timestamp:
    /// the Kiwi pairs the two streams of one listener by it, so the waterfall
    /// takes no channel of its own.
    public static Uri? WaterfallUrl(string hostPort, long timestamp) => StreamUrl(hostPort, "W/F", timestamp);

    public static long TimestampNow() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    private static Uri? StreamUrl(string hostPort, string stream, long timestamp)
    {
        var text = hostPort.Trim();
        foreach (var scheme in new[] { "http://", "https://", "ws://", "wss://" })
        {
            if (text.StartsWith(scheme, StringComparison.OrdinalIgnoreCase))
            {
                text = text[scheme.Length..];
            }
        }
        text = text.TrimEnd('/');
        if (text.Length == 0 || text.Contains('/') || text.Contains(' ') || text.StartsWith('['))
        {
            return null;
        }
        // "host:port" only; a bare IPv6 address isn't supported.
        var colons = text.Count(c => c == ':');
        if (colons > 1)
        {
            return null;
        }
        string host;
        var port = 8073;
        if (colons == 1)
        {
            var colon = text.IndexOf(':');
            host = text[..colon];
            if (!int.TryParse(text[(colon + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out port)
                || port is < 1 or > 65535)
            {
                return null;
            }
        }
        else
        {
            host = text;
        }
        if (host.Length == 0 || Uri.CheckHostName(host) == UriHostNameType.Unknown)
        {
            return null;
        }
        return Uri.TryCreate($"ws://{host}:{port}/{timestamp}/{stream}", UriKind.Absolute, out var url) ? url : null;
    }
}

/// The waterfall's frequency arithmetic, from what the Kiwi reports
/// (bandwidth, wf_fft_size, zoom_max). Positions ("x_bin", the start= value)
/// count bins at the maximum zoom: Hz = x_bin × bandwidth / (fftSize ×
/// 2^zoomMax). One displayed bin at zoom z is 2^(zoomMax − z) of those units,
/// and the span is bandwidth / 2^z.
public sealed record KiwiWaterfallGeometry(double BandwidthHz = 30_000_000, int FftSize = 1024, int ZoomMax = 14)
{
    /// x_bin units across the whole band.
    public int MaxBins => FftSize << ZoomMax;

    public int ClampZoom(int zoom) => Math.Min(Math.Max(zoom, 0), ZoomMax);

    public int UnitsPerBin(int zoom) => 1 << (ZoomMax - ClampZoom(zoom));

    public int SpanUnits(int zoom) => FftSize * UnitsPerBin(zoom);

    public double SpanHz(int zoom) => BandwidthHz / (1 << ClampZoom(zoom));

    public double BinHz(int zoom) => SpanHz(zoom) / FftSize;

    public double Hz(double xBin) => xBin * BandwidthHz / MaxBins;

    public double XBin(double hz) => hz / BandwidthHz * MaxBins;

    /// A left edge kept inside the band (0 … maxBins − span) and on a whole
    /// displayed bin, so a pan moves the picture by whole bins.
    public int ClampStart(int start, int zoom)
    {
        var unit = UnitsPerBin(zoom);
        var highest = MaxBins - SpanUnits(zoom);
        var aligned = (int)Math.Round((double)start / unit, MidpointRounding.AwayFromZero) * unit;
        return Math.Min(Math.Max(aligned, 0), highest);
    }

    /// The left edge that puts hz in the middle of the span (clamped).
    public int Start(double centredOnHz, int zoom) =>
        ClampStart((int)Math.Round(XBin(centredOnHz), MidpointRounding.AwayFromZero) - SpanUnits(zoom) / 2, zoom);

    /// How many displayed bins a row at "to" sits right of one at "from"
    /// (positive = the view moved up in frequency, so old rows move left).
    /// Null when the zooms differ.
    public int? BinsToShift((int XBin, int Zoom) from, (int XBin, int Zoom) to)
    {
        if (from.Zoom != to.Zoom)
        {
            return null;
        }
        return (int)Math.Round((double)(to.XBin - from.XBin) / UnitsPerBin(to.Zoom), MidpointRounding.AwayFromZero);
    }

    /// The frequency at a fractional column (0 = left edge of bin 0, fftSize
    /// = right edge of the last) of a row at (start, zoom).
    public double HzAtColumn(double column, int start, int zoom) => Hz(start + column * UnitsPerBin(zoom));

    /// The fractional column of hz in a row at (start, zoom).
    public double Column(double hz, int start, int zoom) => (XBin(hz) - start) / UnitsPerBin(zoom);

    /// A new left edge that keeps the passband [lowHz, highHz] visible at
    /// least marginFraction of the span from either edge, or null if it
    /// already is (tuning inside the span never moves the waterfall). Moves
    /// just far enough when the passband is near or slightly past an edge;
    /// centres on it when it's far away or wider than the span allows.
    public int? StartKeeping(double lowHz, double highHz, int start, int zoom, double marginFraction = 0.1)
    {
        double span = SpanUnits(zoom);
        var margin = span * marginFraction;
        double low = XBin(lowHz), high = XBin(highHz);
        double left = start, right = start + span;
        if (low >= left + margin && high <= right - margin)
        {
            return null;
        }
        double proposed;
        var farAway = high < left - span / 2 || low > right + span / 2;
        if (farAway || high - low > span - 2 * margin)
        {
            proposed = (low + high) / 2 - span / 2;
        }
        else if (low < left + margin)
        {
            proposed = low - margin;
        }
        else
        {
            proposed = high + margin - span;
        }
        var clamped = ClampStart((int)Math.Round(proposed, MidpointRounding.AwayFromZero), zoom);
        return clamped == start ? null : clamped;
    }
}

/// IMA ADPCM as the Kiwi encodes it ("SET compression=1"): two samples per
/// byte, low nibble first, the step index and previous sample carried across
/// frames. A port of kiwiclient's ImaAdpcmDecoder. Unused by the client
/// (compression is off) but kept in step with the Mac.
public sealed class KiwiAdpcmDecoder
{
    private static readonly int[] StepSizes =
    [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34,
        37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494,
        544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552,
        1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ];

    private static readonly int[] IndexAdjust = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];

    private int _index;
    private int _previous;

    public void Reset()
    {
        _index = 0;
        _previous = 0;
    }

    public short[] Decode(ReadOnlySpan<byte> data)
    {
        var samples = new short[data.Length * 2];
        for (var i = 0; i < data.Length; i++)
        {
            samples[2 * i] = DecodeNibble((byte)(data[i] & 0x0F));
            samples[2 * i + 1] = DecodeNibble((byte)(data[i] >> 4));
        }
        return samples;
    }

    private short DecodeNibble(byte code)
    {
        var step = StepSizes[_index];
        _index = Math.Min(Math.Max(_index + IndexAdjust[code], 0), StepSizes.Length - 1);
        var difference = step >> 3;
        if ((code & 1) != 0) { difference += step >> 2; }
        if ((code & 2) != 0) { difference += step >> 1; }
        if ((code & 4) != 0) { difference += step; }
        if ((code & 8) != 0) { difference = -difference; }
        _previous = Math.Min(Math.Max(_previous + difference, -32768), 32767);
        return (short)_previous;
    }
}

/// Turns SND frames into samples, uncompressed or ADPCM, keeping the decoder
/// state the way the Kiwi's page does.
public sealed class KiwiSoundDecoder
{
    private readonly KiwiAdpcmDecoder _adpcm = new();
    private bool? _lastCompressed;

    public short[] Samples(KiwiSoundFrame frame)
    {
        if (frame.Flags.HasFlag(KiwiSoundFlags.Stereo))
        {
            return [];
        }
        var compressed = frame.Flags.HasFlag(KiwiSoundFlags.Compressed);
        if (_lastCompressed != compressed)
        {
            _adpcm.Reset();
            _lastCompressed = compressed;
        }
        return compressed ? _adpcm.Decode(frame.Payload) : frame.PcmSamples();
    }
}

/// The demodulators the MyKiwiSDR window offers, with the Kiwi page's own
/// default passbands (passbands_fallback in openwebrx.js).
public enum KiwiSdrMode
{
    Usb,
    Lsb,
    Cw,
    Am,
    Fm,
}

public static class KiwiSdrModeExtensions
{
    /// The saved/wire name (the Mac's rawValue).
    public static string RawValue(this KiwiSdrMode mode) => mode.ToString().ToLowerInvariant();

    public static KiwiSdrMode? FromRawValue(string? raw) =>
        Enum.GetValues<KiwiSdrMode>().Cast<KiwiSdrMode?>().FirstOrDefault(m => m!.Value.RawValue() == raw);

    public static string KiwiToken(this KiwiSdrMode mode) => mode switch
    {
        KiwiSdrMode.Usb => "usb",
        KiwiSdrMode.Lsb => "lsb",
        KiwiSdrMode.Cw => "cw",
        KiwiSdrMode.Am => "am",
        _ => "nbfm",
    };

    public static string Label(this KiwiSdrMode mode) => mode.ToString().ToUpperInvariant();

    public static (int Low, int High) DefaultPassband(this KiwiSdrMode mode) => mode switch
    {
        KiwiSdrMode.Usb => (300, 2700),
        KiwiSdrMode.Lsb => (-2700, -300),
        KiwiSdrMode.Cw => (300, 700),
        KiwiSdrMode.Am => (-4900, 4900),
        _ => (-6000, 6000),
    };

    /// The frequency to send for a dial frequency. In CW the Kiwi's dial
    /// shows the signal, which sits at the passband's centre above the
    /// carrier (freq_dsp_to_car); every other mode sends the dial as is.
    public static int CarrierHz(this KiwiSdrMode mode, int dialHz, int lowCut, int highCut, int cwShiftHz = 0) =>
        mode == KiwiSdrMode.Cw ? dialHz - (lowCut + (highCut - lowCut) / 2 - cwShiftHz) : dialHz;

    /// The waterfall's click snap and scroll step.
    public static int WaterfallStepHz(this KiwiSdrMode mode) => mode switch
    {
        KiwiSdrMode.Cw => 10,
        KiwiSdrMode.Usb or KiwiSdrMode.Lsb => 100,
        KiwiSdrMode.Am => 1_000,
        _ => 5_000,
    };

    /// The Kiwi mode a rig mode follows to, or null to tune the frequency
    /// only and leave the Kiwi's mode as it is. DATA-U is plain USB
    /// demodulation on the rig; RTTY, DATA-FM and C4FM have no sensible Kiwi
    /// equivalent (C4FM arrives here as a null rig mode).
    public static KiwiSdrMode? FromRigMode(RigMode? rigMode) => rigMode switch
    {
        RigMode.Usb or RigMode.DataUsb => KiwiSdrMode.Usb,
        RigMode.Lsb => KiwiSdrMode.Lsb,
        RigMode.Cw => KiwiSdrMode.Cw,
        RigMode.Am => KiwiSdrMode.Am,
        RigMode.Fm => KiwiSdrMode.Fm,
        _ => null,
    };

    /// The rig mode with the same demodulation.
    public static RigMode ToRigMode(this KiwiSdrMode mode) => mode switch
    {
        KiwiSdrMode.Usb => RigMode.Usb,
        KiwiSdrMode.Lsb => RigMode.Lsb,
        KiwiSdrMode.Cw => RigMode.Cw,
        KiwiSdrMode.Am => RigMode.Am,
        _ => RigMode.Fm,
    };

    /// The rig mode to set when the Kiwi is tuned to this mode, or null to
    /// leave the rig's mode alone: when the rig's mode already follows to
    /// this one (so DATA-U stays DATA-U under a Kiwi in USB), and when the
    /// rig's mode has no Kiwi equivalent.
    public static RigMode? RigModeFor(this KiwiSdrMode mode, RigMode? current)
    {
        var followed = FromRigMode(current);
        return followed is null || followed == mode ? null : mode.ToRigMode();
    }
}

/// What a KiwiSDR demodulates: mode, passband (Hz relative to the carrier,
/// negative below it) and the dial frequency.
public sealed record KiwiTuning(int DialHz, KiwiSdrMode Mode, int LowCut, int HighCut, int CwShiftHz = 0)
{
    public static KiwiTuning Of(int dialHz, KiwiSdrMode mode)
    {
        var band = mode.DefaultPassband();
        return new KiwiTuning(dialHz, mode, band.Low, band.High);
    }

    public int CarrierHz => Mode.CarrierHz(DialHz, LowCut, HighCut, CwShiftHz);

    public string Command => KiwiProtocol.Tune(CarrierHz, Mode, LowCut, HighCut);
}

/// The Kiwi's plain-text /status page ("users=1\nusers_max=4\n…").
public sealed class KiwiStatus
{
    public IReadOnlyDictionary<string, string> Values { get; }

    public KiwiStatus(string text)
    {
        var values = new Dictionary<string, string>();
        foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = line.IndexOf('=');
            if (eq >= 0)
            {
                values[line[..eq]] = line[(eq + 1)..];
            }
        }
        Values = values;
    }

    public int? Users => Values.TryGetValue("users", out var v) && int.TryParse(v, out var n) ? n : null;
    public int? UsersMax => Values.TryGetValue("users_max", out var v) && int.TryParse(v, out var n) ? n : null;
}

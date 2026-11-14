namespace FTX1RemoteWindows.Services.Ft8;

/// Encodes PSK Reporter's reception-report datagrams: a simplified IPFIX
/// (RFC 5101) over UDP to report.pskreporter.info:4739, laid out as in the
/// "Cookie Cutter" section of https://pskreporter.info/pskdev.html — the Mac's
/// PSKReporterPacket.swift (Sources/FTX1Core/PSKReporter/), which stays the
/// source of truth. Big-endian throughout.
///
/// A datagram is the header, optionally the two record format descriptors
/// (templates — the server caches them per source address/port, so they're
/// only needed in the first few datagrams and then hourly), then the one
/// receiver record (us) and a block of sender records (the stations heard).
/// Strings are a 1-byte length + ASCII, at most 254 bytes; each set is
/// null-padded to a multiple of 4.
///
/// (Which spots become reports is <see cref="PskReporterReports"/>.)
///
/// No SNR is sent: FT8's "SNR" here is ft8_lib's sync score × 0.5, not a
/// calibrated noise-floor SNR.
public static class PskReporterPacket
{
    public const string Host = "report.pskreporter.info";
    public const int Port = 4739;
    /// The doc warns that a datagram much over the path MTU gets lost.
    public const int DefaultMaxBytes = 1400;

    private const ushort ReceiverTemplateId = 0x9992;
    private const ushort SenderTemplateId = 0x9993;

    public sealed record Receiver(string Callsign, string Locator, string Software);

    /// <param name="Mode">An ADIF MODE/SUBMODE value, e.g. "FT8".</param>
    /// <param name="Locator">The sender's grid when the message carried one;
    /// null is sent as an empty string (only used by <see cref="SenderTemplate.WithLocator"/>).</param>
    public sealed record Report(string Callsign, uint FrequencyHz, string Mode, string? Locator, DateTimeOffset Time);

    /// The doc's two SNR-less sender descriptors. The app uses WithLocator;
    /// Basic exists so the doc's own example datagram can be checked byte for byte.
    public enum SenderTemplate
    {
        /// senderCallsign, frequency, mode, informationSource, flowStartSeconds.
        Basic,
        /// The same plus senderLocator (before flowStartSeconds).
        WithLocator,
    }

    public sealed record Datagram(byte[] Data, int ReportCount);

    private static byte[] Descriptor(SenderTemplate template) => template == SenderTemplate.Basic
        ?
        [
            0x00, 0x02, 0x00, 0x2C, 0x99, 0x93, 0x00, 0x05,
            0x80, 0x01, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
            0x80, 0x05, 0x00, 0x04, 0x00, 0x00, 0x76, 0x8F,
            0x80, 0x0A, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
            0x80, 0x0B, 0x00, 0x01, 0x00, 0x00, 0x76, 0x8F,
            0x00, 0x96, 0x00, 0x04,
        ]
        :
        [
            0x00, 0x02, 0x00, 0x34, 0x99, 0x93, 0x00, 0x06,
            0x80, 0x01, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
            0x80, 0x05, 0x00, 0x04, 0x00, 0x00, 0x76, 0x8F,
            0x80, 0x0A, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
            0x80, 0x0B, 0x00, 0x01, 0x00, 0x00, 0x76, 0x8F,
            0x80, 0x03, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
            0x00, 0x96, 0x00, 0x04,
        ];

    /// receiverCallsign, receiverLocator, decodingSoftware.
    private static readonly byte[] ReceiverDescriptor =
    [
        0x00, 0x03, 0x00, 0x24, 0x99, 0x92, 0x00, 0x03, 0x00, 0x01,
        0x80, 0x02, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
        0x80, 0x04, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
        0x80, 0x08, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
        0x00, 0x00,
    ];

    /// 1 = automatically extracted; the server ignores records without it.
    private const byte InformationSourceAutomatic = 1;

    /// Packs <paramref name="reports"/> into as many datagrams as needed, each
    /// at most <paramref name="maxBytes"/>. The header's sequence number is
    /// the count of reports sent before that datagram (the doc: "the count of
    /// reports and not the count of packets"), starting at
    /// <paramref name="sequence"/>. Templates go into every datagram of this
    /// call when <paramref name="includeTemplates"/> is set.
    public static List<Datagram> Encode(
        Receiver receiver,
        IReadOnlyList<Report> reports,
        bool includeTemplates,
        uint sequence,
        uint domainId,
        DateTimeOffset exportTime,
        SenderTemplate template = SenderTemplate.WithLocator,
        int maxBytes = DefaultMaxBytes)
    {
        var receiverSet = ReceiverRecord(receiver);
        var descriptor = Descriptor(template);
        var fixedSize = 16
            + (includeTemplates ? ReceiverDescriptor.Length + descriptor.Length : 0)
            + receiverSet.Length
            + 4 + 3; // sender set header + worst-case padding

        var datagrams = new List<Datagram>();
        var nextSequence = sequence;
        var index = 0;
        while (index < reports.Count)
        {
            var records = new List<byte>();
            var count = 0;
            while (index + count < reports.Count)
            {
                var record = SenderRecord(reports[index + count], template);
                if (count > 0 && fixedSize + records.Count + record.Length > maxBytes)
                {
                    break;
                }
                records.AddRange(record);
                count++;
            }

            var body = new List<byte>();
            if (includeTemplates)
            {
                body.AddRange(ReceiverDescriptor);
                body.AddRange(descriptor);
            }
            body.AddRange(receiverSet);
            body.AddRange(Set(SenderTemplateId, records));

            var data = new List<byte>();
            Append16(data, 0x000A);
            Append16(data, (ushort)Math.Min(16 + body.Count, ushort.MaxValue));
            Append32(data, (uint)Math.Clamp(exportTime.ToUnixTimeSeconds(), 0, uint.MaxValue));
            Append32(data, nextSequence);
            Append32(data, domainId);
            data.AddRange(body);

            datagrams.Add(new Datagram([.. data], count));
            unchecked { nextSequence += (uint)count; }
            index += count;
        }
        return datagrams;
    }

    private static byte[] ReceiverRecord(Receiver receiver)
    {
        var content = new List<byte>();
        AppendString(content, receiver.Callsign);
        AppendString(content, receiver.Locator);
        AppendString(content, receiver.Software);
        return Set(ReceiverTemplateId, content);
    }

    private static byte[] SenderRecord(Report report, SenderTemplate template)
    {
        var bytes = new List<byte>();
        AppendString(bytes, report.Callsign);
        Append32(bytes, report.FrequencyHz);
        AppendString(bytes, report.Mode);
        bytes.Add(InformationSourceAutomatic);
        if (template == SenderTemplate.WithLocator)
        {
            AppendString(bytes, report.Locator ?? "");
        }
        Append32(bytes, (uint)Math.Clamp(report.Time.ToUnixTimeSeconds(), 0, uint.MaxValue));
        return [.. bytes];
    }

    /// A set: its ID (the template it follows), its length including this
    /// header and the padding, then the content null-padded to 4 bytes.
    private static byte[] Set(ushort id, IReadOnlyCollection<byte> content)
    {
        var padding = (4 - (4 + content.Count) % 4) % 4;
        var bytes = new List<byte>();
        Append16(bytes, id);
        Append16(bytes, (ushort)Math.Min(4 + content.Count + padding, ushort.MaxValue));
        bytes.AddRange(content);
        bytes.AddRange(new byte[padding]);
        return [.. bytes];
    }

    /// Non-ASCII is replaced with "?" (callsigns and grids are ASCII; the
    /// doc allows UTF-8 but truncating that at 254 bytes could split a
    /// character).
    private static void AppendString(List<byte> bytes, string value)
    {
        var clipped = value.Take(254).Select(c => c < 128 ? (byte)c : (byte)'?').ToArray();
        bytes.Add((byte)clipped.Length);
        bytes.AddRange(clipped);
    }

    private static void Append16(List<byte> bytes, ushort value)
    {
        bytes.Add((byte)(value >> 8));
        bytes.Add((byte)(value & 0xFF));
    }

    private static void Append32(List<byte> bytes, uint value)
    {
        bytes.Add((byte)(value >> 24));
        bytes.Add((byte)((value >> 16) & 0xFF));
        bytes.Add((byte)((value >> 8) & 0xFF));
        bytes.Add((byte)(value & 0xFF));
    }
}

/// Which decoded spots PSK Reporter is told about (the Mac's
/// PSKReporterUploader.report(from:)).
public static class PskReporterReports
{
    /// Only spots with a real, unhashed sender callsign on a known dial
    /// frequency; the grid only when it's a 4-character Maidenhead square.
    public static PskReporterPacket.Report? From(long dialFrequencyHz, double absoluteFrequencyHz, string? spottedCallsign, string? spottedGrid, string mode, DateTimeOffset time)
    {
        if (dialFrequencyHz <= 0 || spottedCallsign is null)
        {
            return null;
        }
        var call = spottedCallsign.ToUpperInvariant();
        if (call.Length < 3 || call.Contains('<')
            || !call.Any(char.IsAsciiDigit) || !call.Any(char.IsAsciiLetter)
            || !call.All(c => char.IsAsciiLetterOrDigit(c) || c == '/'))
        {
            return null;
        }
        var frequency = Math.Round(absoluteFrequencyHz, MidpointRounding.ToEven);
        if (frequency <= 0 || frequency >= uint.MaxValue)
        {
            return null;
        }
        return new PskReporterPacket.Report(call, (uint)frequency, mode, spottedGrid is null ? null : ValidGrid(spottedGrid), time);
    }

    private static string? ValidGrid(string grid)
    {
        var chars = grid.ToUpperInvariant();
        if (chars.Length != 4
            || chars[0] is < 'A' or > 'R' || chars[1] is < 'A' or > 'R'
            || !char.IsAsciiDigit(chars[2]) || !char.IsAsciiDigit(chars[3])
            || grid == "RR73")
        {
            return null;
        }
        return chars;
    }
}

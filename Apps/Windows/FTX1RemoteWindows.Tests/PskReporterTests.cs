using FTX1RemoteWindows.Services.Ft8;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// Checks PskReporterPacket against the example datagrams in
/// https://pskreporter.info/pskdev.html (the same bytes as the Mac's
/// PSKReporterPacketTests.swift, copied from the page, not produced by this code).
public class PskReporterTests
{
    private static readonly PskReporterPacket.Receiver Receiver = new("N1DQ", "FN42hn", "Homebrew v5.6");

    private static List<PskReporterPacket.Report> Reports() =>
    [
        new("N1DQ", 14_070_567, "PSK", null, DateTimeOffset.FromUnixTimeSeconds(1_200_960_084)),
        new("KB1MBX", 14_070_987, "PSK", null, DateTimeOffset.FromUnixTimeSeconds(1_200_960_104)),
    ];

    private static byte[] Bytes(string hex) =>
        hex.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(h => Convert.ToByte(h, 16)).ToArray();

    [Fact]
    public void DocExampleWithTemplates()
    {
        var expected = Bytes("""
            00 0A 00 AC 47 95 32 72 00 00 00 01 00 00 00 00
            00 03 00 24  99 92 00 03 00 01  80 02 FF FF 00 00 76 8F  80 04 FF FF 00 00 76 8F  80 08 FF FF 00 00 76 8F  00 00
            00 02 00 2C  99 93 00 05  80 01 FF FF 00 00 76 8F  80 05 00 04 00 00 76 8F  80 0A FF FF 00 00 76 8F  80 0B 00 01 00 00 76 8F  00 96 00 04
            99 92 00 20  04 4E 31 44 51  06 46 4E 34 32 68 6E  0D 48 6F 6D 65 62 72 65 77 20 76 35 2E 36  00 00
            99 93 00 2C  04 4E 31 44 51  00 D6 B3 27  03 50 53 4B  01  47 95 32 54
                         06 4B 42 31 4D 42 58  00 D6 B4 CB  03 50 53 4B  01  47 95 32 68
                         00 00
            """);
        var datagrams = PskReporterPacket.Encode(Receiver, Reports(), includeTemplates: true, sequence: 1, domainId: 0,
            exportTime: DateTimeOffset.FromUnixTimeSeconds(1_200_960_114), template: PskReporterPacket.SenderTemplate.Basic);
        var datagram = Assert.Single(datagrams);
        Assert.Equal(expected, datagram.Data);
        Assert.Equal(2, datagram.ReportCount);
    }

    [Fact]
    public void DocExampleWithoutTemplates()
    {
        var expected = Bytes("""
            00 0A 00 5C 47 95 32 72 00 00 00 04 00 00 00 00
            99 92 00 20  04 4E 31 44 51  06 46 4E 34 32 68 6E  0D 48 6F 6D 65 62 72 65 77 20 76 35 2E 36  00 00
            99 93 00 2C  04 4E 31 44 51  00 D6 B3 27  03 50 53 4B  01  47 95 32 54
                         06 4B 42 31 4D 42 58  00 D6 B4 CB  03 50 53 4B  01  47 95 32 68
                         00 00
            """);
        var datagrams = PskReporterPacket.Encode(Receiver, Reports(), includeTemplates: false, sequence: 4, domainId: 0,
            exportTime: DateTimeOffset.FromUnixTimeSeconds(1_200_960_114), template: PskReporterPacket.SenderTemplate.Basic);
        Assert.Equal(expected, Assert.Single(datagrams).Data);
    }

    /// The 6-field descriptor: the locator sits before the time, and a
    /// missing one is a zero-length string.
    [Fact]
    public void LocatorTemplate()
    {
        var reports = Reports();
        reports[0] = reports[0] with { Locator = "FN42" };
        var data = PskReporterPacket.Encode(Receiver, reports, includeTemplates: true, sequence: 0, domainId: 0x01020304,
            exportTime: DateTimeOffset.FromUnixTimeSeconds(1_200_960_114))[0].Data;

        Assert.Equal(new byte[] { 0x01, 0x02, 0x03, 0x04 }, data[12..16]);
        // Header 16 + receiver descriptor 36 + sender descriptor 52.
        Assert.Equal(new byte[] { 0x00, 0x02, 0x00, 0x34, 0x99, 0x93, 0x00, 0x06 }, data[52..60]);
        var senderSet = data[(16 + 36 + 52 + 32)..];
        // N1DQ(5) freq(4) PSK(4) src(1) FN42(5) time(4) = 23; KB1MBX 7+4+4+1+1+4 = 21.
        Assert.Equal(new byte[] { 0x99, 0x93, 0x00, 0x30 }, senderSet[0..4]);
        Assert.Equal(new byte[] { 0x04, 0x46, 0x4E, 0x34, 0x32 }, senderSet[18..23]);
        Assert.Equal(0x00, senderSet[4 + 23 + 7 + 4 + 4 + 1]); // KB1MBX's empty locator
        Assert.Equal(0x30, senderSet.Length);
        Assert.Equal(data.Length, data[2] << 8 | data[3]);
    }

    /// Splits at the size limit; every datagram is complete on its own and
    /// the sequence number counts reports, not datagrams.
    [Fact]
    public void SplitsAndCountsSequence()
    {
        var many = Enumerable.Range(0, 200)
            .Select(i => new PskReporterPacket.Report($"K{i}ABC", (uint)(14_074_000 + i), "FT8", "FN31", DateTimeOffset.FromUnixTimeSeconds(1_800_000_000)))
            .ToList();
        var datagrams = PskReporterPacket.Encode(Receiver, many, includeTemplates: false, sequence: 10, domainId: 7,
            exportTime: DateTimeOffset.FromUnixTimeSeconds(1_800_000_010));

        Assert.True(datagrams.Count > 1);
        Assert.Equal(200, datagrams.Sum(d => d.ReportCount));
        uint expectedSequence = 10;
        foreach (var datagram in datagrams)
        {
            var data = datagram.Data;
            Assert.True(data.Length <= PskReporterPacket.DefaultMaxBytes);
            Assert.Equal(data.Length, data[2] << 8 | data[3]);
            Assert.Equal(0, data.Length % 4);
            var sequence = (uint)data[8] << 24 | (uint)data[9] << 16 | (uint)data[10] << 8 | data[11];
            Assert.Equal(expectedSequence, sequence);
            expectedSequence += (uint)datagram.ReportCount;
        }
    }

    [Fact]
    public void NoReportsNoDatagrams()
    {
        Assert.Empty(PskReporterPacket.Encode(Receiver, [], includeTemplates: true, sequence: 0, domainId: 0, exportTime: DateTimeOffset.UtcNow));
    }

    [Theory]
    [InlineData("K1ABC", "FN42", "FN42")]
    [InlineData("k1abc", "fn42", "FN42")]
    [InlineData("DL1ABC/P", "JO62", "JO62")]
    [InlineData("K1ABC", "RR73", null)]
    [InlineData("K1ABC", "FN42xx", null)]
    [InlineData("K1ABC", "ZZ99", null)]
    [InlineData("K1ABC", null, null)]
    public void ReportKeepsOnlyAValidGrid(string call, string? grid, string? expectedGrid)
    {
        var report = PskReporterReports.From(14_074_000, 14_075_500, call, grid, "FT8", DateTimeOffset.UtcNow);
        Assert.NotNull(report);
        Assert.Equal(call.ToUpperInvariant(), report.Callsign);
        Assert.Equal(expectedGrid, report.Locator);
        Assert.Equal(14_075_500u, report.FrequencyHz);
    }

    [Theory]
    [InlineData("<...>")]
    [InlineData("CQ")]
    [InlineData("ABCDE")]
    [InlineData("12345")]
    [InlineData("K1 ABC")]
    [InlineData(null)]
    public void ReportRejectsHashedAndMalformedCalls(string? call)
    {
        Assert.Null(PskReporterReports.From(14_074_000, 14_075_500, call, "FN42", "FT8", DateTimeOffset.UtcNow));
    }

    [Fact]
    public void ReportNeedsADialFrequency()
    {
        Assert.Null(PskReporterReports.From(0, 1_500, "K1ABC", "FN42", "FT8", DateTimeOffset.UtcNow));
    }
}

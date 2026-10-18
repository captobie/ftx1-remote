import XCTest
@testable import FTX1Core

/// Checks `PSKReporterPacket` against the example datagrams in
/// https://pskreporter.info/pskdev.html (copied from the page 2026-10-18,
/// not produced by this code).
final class PSKReporterPacketTests: XCTestCase {
    private let receiver = PSKReporterPacket.Receiver(callsign: "N1DQ", locator: "FN42hn", software: "Homebrew v5.6")
    private let reports = [
        PSKReporterPacket.Report(callsign: "N1DQ", frequencyHz: 14_070_567, mode: "PSK", locator: nil,
                                 time: Date(timeIntervalSince1970: 1_200_960_084)),
        PSKReporterPacket.Report(callsign: "KB1MBX", frequencyHz: 14_070_987, mode: "PSK", locator: nil,
                                 time: Date(timeIntervalSince1970: 1_200_960_104)),
    ]

    private static func bytes(_ hex: String) -> Data {
        let digits = hex.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! }
        return Data(digits)
    }

    func testDocExampleWithTemplates() {
        let expected = Self.bytes("""
            00 0A 00 AC 47 95 32 72 00 00 00 01 00 00 00 00
            00 03 00 24  99 92 00 03 00 01  80 02 FF FF 00 00 76 8F  80 04 FF FF 00 00 76 8F  80 08 FF FF 00 00 76 8F  00 00
            00 02 00 2C  99 93 00 05  80 01 FF FF 00 00 76 8F  80 05 00 04 00 00 76 8F  80 0A FF FF 00 00 76 8F  80 0B 00 01 00 00 76 8F  00 96 00 04
            99 92 00 20  04 4E 31 44 51  06 46 4E 34 32 68 6E  0D 48 6F 6D 65 62 72 65 77 20 76 35 2E 36  00 00
            99 93 00 2C  04 4E 31 44 51  00 D6 B3 27  03 50 53 4B  01  47 95 32 54
                         06 4B 42 31 4D 42 58  00 D6 B4 CB  03 50 53 4B  01  47 95 32 68
                         00 00
            """)
        let datagrams = PSKReporterPacket.encode(
            receiver: receiver, reports: reports, template: .basic, includeTemplates: true,
            sequence: 1, domainID: 0, exportTime: Date(timeIntervalSince1970: 1_200_960_114))
        XCTAssertEqual(datagrams.count, 1)
        XCTAssertEqual(datagrams.first?.data, expected)
        XCTAssertEqual(datagrams.first?.reportCount, 2)
    }

    func testDocExampleWithoutTemplates() {
        let expected = Self.bytes("""
            00 0A 00 5C 47 95 32 72 00 00 00 04 00 00 00 00
            99 92 00 20  04 4E 31 44 51  06 46 4E 34 32 68 6E  0D 48 6F 6D 65 62 72 65 77 20 76 35 2E 36  00 00
            99 93 00 2C  04 4E 31 44 51  00 D6 B3 27  03 50 53 4B  01  47 95 32 54
                         06 4B 42 31 4D 42 58  00 D6 B4 CB  03 50 53 4B  01  47 95 32 68
                         00 00
            """)
        let datagrams = PSKReporterPacket.encode(
            receiver: receiver, reports: reports, template: .basic, includeTemplates: false,
            sequence: 4, domainID: 0, exportTime: Date(timeIntervalSince1970: 1_200_960_114))
        XCTAssertEqual(datagrams.map(\.data), [expected])
    }

    /// The doc's 6-field descriptor; the locator sits before the time, and
    /// a missing one is a zero-length string.
    func testLocatorTemplate() {
        var withGrid = reports
        withGrid[0].locator = "FN42"
        let datagrams = PSKReporterPacket.encode(
            receiver: receiver, reports: withGrid, includeTemplates: true,
            sequence: 0, domainID: 0x0102_0304, exportTime: Date(timeIntervalSince1970: 1_200_960_114))
        let data = [UInt8](datagrams[0].data)

        XCTAssertEqual(Array(data[12..<16]), [0x01, 0x02, 0x03, 0x04])
        // Header 16 + receiver descriptor 36 + sender descriptor 52.
        XCTAssertEqual(Array(data[52..<60]), [0x00, 0x02, 0x00, 0x34, 0x99, 0x93, 0x00, 0x06])
        let senderSet = Array(data[(16 + 36 + 52 + 32)...])
        // N1DQ(5) freq(4) PSK(4) src(1) FN42(5) time(4) = 23; KB1MBX 7+4+4+1+1+4 = 21.
        XCTAssertEqual(Array(senderSet[0..<4]), [0x99, 0x93, 0x00, 0x30])
        XCTAssertEqual(Array(senderSet[18..<23]), [0x04, 0x46, 0x4E, 0x34, 0x32])
        XCTAssertEqual(senderSet[4 + 23 + 7 + 4 + 4 + 1], 0x00)  // KB1MBX's empty locator
        XCTAssertEqual(senderSet.count, 0x30)
        XCTAssertEqual(data.count, Int(data[2]) << 8 | Int(data[3]))
    }

    /// Splits at the size limit; every datagram is complete on its own and
    /// the sequence number counts reports, not datagrams.
    func testSplitsAndCountsSequence() {
        let many = (0..<200).map { i in
            PSKReporterPacket.Report(callsign: "K\(i)ABC", frequencyHz: 14_074_000 + UInt32(i), mode: "FT8",
                                     locator: "FN31", time: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let datagrams = PSKReporterPacket.encode(
            receiver: receiver, reports: many, includeTemplates: false,
            sequence: 10, domainID: 7, exportTime: Date(timeIntervalSince1970: 1_800_000_010))

        XCTAssertGreaterThan(datagrams.count, 1)
        XCTAssertEqual(datagrams.map(\.reportCount).reduce(0, +), 200)
        var expectedSequence: UInt32 = 10
        for datagram in datagrams {
            let data = [UInt8](datagram.data)
            XCTAssertLessThanOrEqual(data.count, PSKReporterPacket.defaultMaxBytes)
            XCTAssertEqual(data.count, Int(data[2]) << 8 | Int(data[3]))
            XCTAssertEqual(data.count % 4, 0)
            let sequence = UInt32(data[8]) << 24 | UInt32(data[9]) << 16 | UInt32(data[10]) << 8 | UInt32(data[11])
            XCTAssertEqual(sequence, expectedSequence)
            expectedSequence += UInt32(datagram.reportCount)
        }
    }

    func testNoReportsNoDatagrams() {
        XCTAssertTrue(PSKReporterPacket.encode(
            receiver: receiver, reports: [], includeTemplates: true,
            sequence: 0, domainID: 0, exportTime: Date()).isEmpty)
    }
}

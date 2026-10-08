import XCTest
@testable import FTX1Core

/// Checks `WSJTXMessage`/`ADIFRecord` against the layout in WSJT-X's
/// `Network/NetworkMessage.hpp`, decoding with a reader written here
/// rather than reusing the encoder. Reference Julian days were computed
/// with Python's `date.toordinal() + 1721425`, not with this code.
final class WSJTXMessageTests: XCTestCase {
    /// 2026-10-04 14:16:37 UTC → 14:21:07 UTC.
    private let qso = LoggedQSO(
        call: "K6NA",
        grid: "DM12",
        start: Date(timeIntervalSince1970: 1_791_123_397),
        end: Date(timeIntervalSince1970: 1_791_123_667),
        frequencyHz: 7_028_500,
        mode: "CW",
        rstSent: "599",
        rstReceived: "579",
        txPower: "100",
        myCall: "N0CALL",
        myGrid: "FN31pr"
    )

    func testQSOLoggedLayout() throws {
        var reader = Reader(WSJTXMessage.qsoLogged(qso))
        XCTAssertEqual(try reader.uint32(), 0xadbc_cbda)
        XCTAssertEqual(try reader.uint32(), 3)
        XCTAssertEqual(try reader.uint32(), 5)
        XCTAssertEqual(try reader.utf8(), "WSJT-X - FTX1Remote")

        let off = try reader.dateTime()
        XCTAssertEqual(off.julianDay, 2_461_318)
        XCTAssertEqual(off.msOfDay, (14 * 3600 + 21 * 60 + 7) * 1000)
        XCTAssertEqual(off.timespec, 1)

        XCTAssertEqual(try reader.utf8(), "K6NA")
        XCTAssertEqual(try reader.utf8(), "DM12")
        XCTAssertEqual(try reader.uint64(), 7_028_500)
        XCTAssertEqual(try reader.utf8(), "CW")
        XCTAssertEqual(try reader.utf8(), "599")
        XCTAssertEqual(try reader.utf8(), "579")
        XCTAssertEqual(try reader.utf8(), "100")
        XCTAssertEqual(try reader.utf8(), "")      // comments
        XCTAssertEqual(try reader.utf8(), "")      // name

        let on = try reader.dateTime()
        XCTAssertEqual(on.julianDay, 2_461_318)
        XCTAssertEqual(on.msOfDay, 51_397_000)

        XCTAssertEqual(try reader.utf8(), "N0CALL")  // operator
        XCTAssertEqual(try reader.utf8(), "N0CALL")  // my call
        XCTAssertEqual(try reader.utf8(), "FN31pr")
        XCTAssertEqual(try reader.utf8(), "")
        XCTAssertEqual(try reader.utf8(), "")
        XCTAssertEqual(try reader.utf8(), "")
        XCTAssertTrue(reader.atEnd)
    }

    func testDateTimeBeforeEpochUsesPreviousDay() throws {
        var writer = WSJTXMessage.Writer(type: .heartbeat, id: "")
        writer.dateTime(Date(timeIntervalSince1970: -1))
        var reader = Reader(writer.data)
        _ = try (reader.uint32(), reader.uint32(), reader.uint32(), reader.utf8())
        let value = try reader.dateTime()
        XCTAssertEqual(value.julianDay, 2_440_587)
        XCTAssertEqual(value.msOfDay, 86_399_000)
    }

    func testStatusLayout() throws {
        var reader = Reader(WSJTXMessage.status(dialFrequencyHz: 7_028_500, mode: "CW", dxCall: "K6NA", deCall: "N0CALL", deGrid: "FN31"))
        _ = try (reader.uint32(), reader.uint32())
        XCTAssertEqual(try reader.uint32(), 1)
        XCTAssertEqual(try reader.utf8(), "WSJT-X - FTX1Remote")
        XCTAssertEqual(try reader.uint64(), 7_028_500)
        XCTAssertEqual(try reader.utf8(), "CW")
        XCTAssertEqual(try reader.utf8(), "K6NA")
        XCTAssertEqual(try reader.utf8(), "")        // report
        XCTAssertEqual(try reader.utf8(), "CW")      // TX mode
        XCTAssertEqual(Array(try reader.take(3)), [0, 0, 0])
        XCTAssertEqual(try reader.uint32(), 0)
        XCTAssertEqual(try reader.uint32(), 0)
        XCTAssertEqual(try reader.utf8(), "N0CALL")
        XCTAssertEqual(try reader.utf8(), "FN31")
        XCTAssertEqual(try reader.utf8(), "")        // DX grid
        XCTAssertEqual(Array(try reader.take(1)), [0])
        XCTAssertEqual(try reader.utf8(), "")        // sub-mode
        XCTAssertEqual(Array(try reader.take(2)), [0, 0])
        XCTAssertEqual(try reader.uint32(), 0xffff_ffff)
        XCTAssertEqual(try reader.uint32(), 0xffff_ffff)
        XCTAssertEqual(try reader.utf8(), "")
        XCTAssertEqual(try reader.utf8(), "")
        XCTAssertTrue(reader.atEnd)
    }

    func testHeartbeatLayout() throws {
        var reader = Reader(WSJTXMessage.heartbeat())
        XCTAssertEqual(try reader.uint32(), 0xadbc_cbda)
        XCTAssertEqual(try reader.uint32(), 3)
        XCTAssertEqual(try reader.uint32(), 0)
        XCTAssertEqual(try reader.utf8(), "WSJT-X - FTX1Remote")
        XCTAssertEqual(try reader.uint32(), 3)     // maximum schema
        XCTAssertEqual(try reader.utf8(), "")
        XCTAssertEqual(try reader.utf8(), "")
        XCTAssertTrue(reader.atEnd)
    }

    func testLoggedADIFCarriesTheADIFFile() throws {
        var reader = Reader(WSJTXMessage.loggedADIF(qso))
        _ = try (reader.uint32(), reader.uint32())
        XCTAssertEqual(try reader.uint32(), 12)
        XCTAssertEqual(try reader.utf8(), "WSJT-X - FTX1Remote")
        XCTAssertEqual(try reader.utf8(), ADIFRecord.file(for: qso))
        XCTAssertTrue(reader.atEnd)
    }

    func testADIFRecord() {
        XCTAssertEqual(
            ADIFRecord.record(for: qso),
            "<call:4>K6NA <gridsquare:4>DM12 <mode:2>CW <rst_sent:3>599 <rst_rcvd:3>579 "
                + "<qso_date:8>20261004 <time_on:6>141637 <qso_date_off:8>20261004 <time_off:6>142107 "
                + "<band:3>40m <freq:8>7.028500 <station_callsign:6>N0CALL <my_gridsquare:6>FN31pr "
                + "<tx_pwr:3>100 <EOR>"
        )
        XCTAssertTrue(ADIFRecord.file(for: qso).hasPrefix("<adif_ver:5>3.1.4\n<programid:10>FTX1Remote\n<EOH>\n<call:4>"))
    }

    func testADIFFrequencyAndBand() {
        XCTAssertEqual(ADIFRecord.frequency(146_520_000), "146.520000")
        XCTAssertEqual(ADIFRecord.frequency(1_838_001), "1.838001")
        var outOfBand = qso
        outOfBand.frequencyHz = 9_500_000
        XCTAssertFalse(ADIFRecord.record(for: outOfBand).contains("<band:"))
    }

    func testADIFModeFromRigMode() {
        XCTAssertEqual(ADIFMode(.cw), ADIFMode(mode: "CW"))
        XCTAssertEqual(ADIFMode(.usb), ADIFMode(mode: "SSB", submode: "USB"))
        XCTAssertEqual(ADIFMode(.lsb), ADIFMode(mode: "SSB", submode: "LSB"))
        XCTAssertEqual(ADIFMode(.c4fm), ADIFMode(mode: "DIGITALVOICE", submode: "C4FM"))
        XCTAssertNil(ADIFMode(.dataUSB))
        XCTAssertNil(ADIFMode(.unknown))
    }

    private struct Reader {
        struct Truncated: Error {}
        let bytes: [UInt8]
        var offset = 0
        init(_ data: Data) { bytes = Array(data) }

        var atEnd: Bool { offset == bytes.count }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard offset + count <= bytes.count else { throw Truncated() }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        mutating func unsigned(_ width: Int) throws -> UInt64 {
            try take(width).reduce(0) { $0 << 8 | UInt64($1) }
        }

        mutating func uint32() throws -> UInt32 { UInt32(try unsigned(4)) }
        mutating func uint64() throws -> UInt64 { try unsigned(8) }

        mutating func utf8() throws -> String {
            let count = Int(try uint32())
            return String(decoding: try take(count), as: UTF8.self)
        }

        mutating func dateTime() throws -> (julianDay: Int64, msOfDay: UInt32, timespec: UInt8) {
            (Int64(bitPattern: try uint64()), try uint32(), try take(1).first!)
        }
    }
}

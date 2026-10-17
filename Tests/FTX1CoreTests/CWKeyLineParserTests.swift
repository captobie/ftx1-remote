import XCTest
@testable import FTX1Core

/// The CW key interface's serial line protocol and its 32-bit clock.
final class CWKeyLineParserTests: XCTestCase {
    private func feed(_ text: String, into assembler: inout CWKeyLineAssembler) -> [CWKeyLine] {
        assembler.feed(Array(text.utf8))
    }

    func testParsesEveryLineKind() {
        XCTAssertEqual(CWKeyLine.parse("I,FTX1CW,1"), .banner(id: "FTX1CW", version: 1))
        XCTAssertEqual(CWKeyLine.parse("D,1234"), .keyDown(deviceMs: 1234))
        XCTAssertEqual(CWKeyLine.parse("U,0"), .keyUp(deviceMs: 0))
        XCTAssertEqual(CWKeyLine.parse("H,4294967295"), .heartbeat(deviceMs: .max))
        XCTAssertEqual(CWKeyLine.parse("S,20,B,0,1,5678"), .status(CWKeyDeviceStatus(
            wpm: 20, iambicModeB: true, paddleReversed: false, sidetoneOn: true, deviceMs: 5678)))
    }

    func testRejectsMalformedLines() {
        for line in ["", "D", "D,", "D,12a", "D,-5", "D, 5", "D,4294967296", "D,1,2", "X,5",
                     "d,5", "I,FTX1CW", "I,,1", "I,FTX1CW,x", "S,20,C,0,1,5", "S,20,B,2,1,5",
                     "S,20,B,0,1", "S,0,B,0,1,5", "H,0x10"] {
            XCTAssertNil(CWKeyLine.parse(Substring(line)), line)
        }
    }

    func testAssemblesLinesSplitAcrossChunks() {
        var assembler = CWKeyLineAssembler()
        XCTAssertEqual(feed("D,1", into: &assembler), [])
        XCTAssertEqual(feed("00\r", into: &assembler), [.keyDown(deviceMs: 100)])
        XCTAssertEqual(feed("\nU,1", into: &assembler), [])
        XCTAssertEqual(feed("60\r\nH,250\r\nH,5", into: &assembler), [.keyUp(deviceMs: 160), .heartbeat(deviceMs: 250)])
        XCTAssertEqual(feed("00\n", into: &assembler), [.heartbeat(deviceMs: 500)])
        XCTAssertEqual(assembler.rejectedLineCount, 0)
    }

    /// What the port gives right after opening: the tail of a line from
    /// before the reset, noise, then the banner.
    func testSkipsGarbageAroundGoodLines() {
        var assembler = CWKeyLineAssembler()
        var bytes: [UInt8] = Array(",1234\r\n".utf8)
        bytes += [0x00, 0xFF, 0x80, 0x0A]
        bytes += Array("I,FTX1CW,1\r\nD,9\r\n".utf8)
        XCTAssertEqual(assembler.feed(bytes), [.banner(id: "FTX1CW", version: 1), .keyDown(deviceMs: 9)])
        XCTAssertEqual(assembler.rejectedLineCount, 2)
    }

    func testDropsOverlongLineUpToTheNextNewline() {
        var assembler = CWKeyLineAssembler()
        let noise = String(repeating: "Z", count: 500)
        XCTAssertEqual(feed(noise, into: &assembler), [])
        XCTAssertEqual(feed("D,1\nU,2\n", into: &assembler), [.keyUp(deviceMs: 2)])
        XCTAssertEqual(assembler.rejectedLineCount, 1)
    }

    func testResetDropsPartialLine() {
        var assembler = CWKeyLineAssembler()
        _ = feed("D,12", into: &assembler)
        assembler.reset()
        XCTAssertEqual(feed("H,3\n", into: &assembler), [.heartbeat(deviceMs: 3)])
    }

    // MARK: - Clock

    func testUnwrapsAcrossTheWrap() {
        var clock = CWDeviceClockUnwrapper()
        XCTAssertEqual(clock.unwrap(UInt32.max - 100).ms, Int64(UInt32.max) - 100)
        let afterWrap = clock.unwrap(150)
        XCTAssertEqual(afterWrap.ms, Int64(UInt32.max) + 1 + 150)
        XCTAssertFalse(afterWrap.restarted)
        XCTAssertEqual(clock.unwrap(400).ms, Int64(UInt32.max) + 1 + 400)
    }

    func testSmallBackwardStepIsNotARestart() {
        var clock = CWDeviceClockUnwrapper()
        _ = clock.unwrap(10_000)
        let back = clock.unwrap(9_990)
        XCTAssertEqual(back.ms, 9_990)
        XCTAssertFalse(back.restarted)
    }

    func testLargeBackwardStepIsARestart() {
        var clock = CWDeviceClockUnwrapper()
        _ = clock.unwrap(5_000_000)
        let restarted = clock.unwrap(20)
        XCTAssertTrue(restarted.restarted)
        XCTAssertEqual(restarted.ms, 20)
        XCTAssertEqual(clock.unwrap(270).ms, 270)
    }

    /// A restart from near the top of the range reads as a small forward
    /// step (a wrap), so that case relies on the banner calling `reset`.
    func testResetAfterBanner() {
        var clock = CWDeviceClockUnwrapper()
        _ = clock.unwrap(UInt32.max - 10)
        clock.reset()
        XCTAssertEqual(clock.unwrap(5).ms, 5)
    }
}

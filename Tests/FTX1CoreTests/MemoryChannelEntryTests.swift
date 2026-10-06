import XCTest
@testable import FTX1Core

final class MemoryChannelEntryTests: XCTestCase {
    /// Real answers from the rig (2026-10-06).
    func testParsesRealReplies() throws {
        let c4fm = try XCTUnwrap(MemoryChannelEntry(mrReply: "MR00001431075000+000000H10000;", tag: "Pi-STAR"))
        XCTAssertEqual(c4fm.channel, 1)
        XCTAssertEqual(c4fm.frequencyHz, 431_075_000)
        XCTAssertEqual(c4fm.modeName, "C4FM-DN")
        XCTAssertEqual(c4fm.toneName, "")
        XCTAssertEqual(c4fm.shiftName, "")
        XCTAssertEqual(c4fm.tag, "Pi-STAR")

        let fm = try XCTUnwrap(MemoryChannelEntry(mrReply: "MR00002147360000+000000411000;"))
        XCTAssertEqual(fm.channel, 2)
        XCTAssertEqual(fm.frequencyHz, 147_360_000)
        XCTAssertEqual(fm.modeName, "FM")
        XCTAssertEqual(fm.toneName, "TSQL")

        let high = try XCTUnwrap(MemoryChannelEntry(mrReply: "MR00278444925000+000000410002;"))
        XCTAssertEqual(high.channel, 278)
        XCTAssertEqual(high.shiftName, "−")
    }

    func testBlankChannelIsNil() {
        XCTAssertNil(MemoryChannelEntry(mrReply: "?;"))
        XCTAssertNil(MemoryChannelEntry(mrReply: "MR00001;"))
        XCTAssertNil(MemoryChannelEntry(mrReply: ""))
    }
}

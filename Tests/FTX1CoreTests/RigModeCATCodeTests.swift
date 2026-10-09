import XCTest
@testable import FTX1Core

final class RigModeCATCodeTests: XCTestCase {
    func testMappedCodes() {
        let expected: [Character: RigMode] = [
            "1": .lsb, "2": .usb, "3": .cw, "4": .fm, "5": .am, "6": .rtty,
            "A": .dataFM, "C": .dataUSB, "H": .c4fm, "I": .c4fm,
        ]
        for (code, mode) in expected {
            XCTAssertEqual(RigMode(catModeCode: code), mode, "code \(code)")
        }
    }

    /// Codes hamlib reports under names `RigMode` has no case for (CWR,
    /// PKTLSB, RTTYR, FMN, AMN, PSK, ...) must stay nil so the poll keeps
    /// the last known mode, as it did with hamlib's read.
    func testUnmappedCodesAreNil() {
        for code: Character in ["0", "7", "8", "9", "B", "D", "E", "F", "G", "J", "x"] {
            XCTAssertNil(RigMode(catModeCode: code), "code \(code)")
        }
    }

    /// Every settable mode's code reads back as the same mode.
    func testCodeRoundTrip() {
        for mode in RigMode.allCases where mode != .unknown {
            let code = try! XCTUnwrap(mode.catModeCode, "\(mode)")
            XCTAssertEqual(RigMode(catModeCode: code), mode)
        }
        XCTAssertNil(RigMode.unknown.catModeCode)
    }
}

import XCTest
@testable import FTX1Core

final class IFNotchTests: XCTestCase {
    func testSnappedClampsAndRoundsToTenHz() {
        XCTAssertEqual(IFNotch.snappedHz(5), 10)
        XCTAssertEqual(IFNotch.snappedHz(0), 10)
        XCTAssertEqual(IFNotch.snappedHz(3205), 3200)
        XCTAssertEqual(IFNotch.snappedHz(9999), 3200)
        XCTAssertEqual(IFNotch.snappedHz(1244), 1240)
        XCTAssertEqual(IFNotch.snappedHz(1246), 1250)
        XCTAssertEqual(IFNotch.snappedHz(1240), 1240)
    }

    /// "BP01" carries the frequency as a 3-digit code of 10 Hz units.
    func testCodeRoundTrip() {
        XCTAssertEqual(IFNotch.code(forHz: 1240), 124)
        XCTAssertEqual(IFNotch.code(forHz: 10), 1)
        XCTAssertEqual(IFNotch.code(forHz: 3200), 320)
        XCTAssertEqual(IFNotch.code(forHz: 1244), 124)
        XCTAssertEqual(IFNotch.hz(forCode: 124), 1240)
        XCTAssertEqual(IFNotch.hz(forCode: 1), 10)
        XCTAssertEqual(IFNotch.hz(forCode: 320), 3200)
        XCTAssertNil(IFNotch.hz(forCode: 0))
        XCTAssertNil(IFNotch.hz(forCode: 321))
        for code in 1...320 {
            XCTAssertEqual(IFNotch.code(forHz: IFNotch.hz(forCode: code)!), code)
        }
    }

    func testLabels() {
        XCTAssertEqual(IFNotch.label(1240), "1240 Hz")
        XCTAssertEqual(IFNotch.label(nil), "—")
    }

    /// Same IF-DSP block as SHIFT, so the same mode set until hardware
    /// says otherwise.
    func testSupportMatchesIFShift() {
        for mode in RigMode.allCases {
            XCTAssertEqual(IFNotch.isSupported(mode: mode), IFShift.isSupported(mode: mode), "\(mode)")
        }
    }
}

import XCTest
@testable import FTX1Core

final class IFShiftTests: XCTestCase {
    func testSnappedClampsToRange() {
        XCTAssertEqual(IFShift.snapped(1300), 1200)
        XCTAssertEqual(IFShift.snapped(-1300), -1200)
        XCTAssertEqual(IFShift.snapped(1200), 1200)
        XCTAssertEqual(IFShift.snapped(-1200), -1200)
    }

    func testSnappedRoundsToNearestStepTiesAwayFromZero() {
        XCTAssertEqual(IFShift.snapped(0), 0)
        XCTAssertEqual(IFShift.snapped(240), 240)
        XCTAssertEqual(IFShift.snapped(244), 240)
        XCTAssertEqual(IFShift.snapped(256), 260)
        XCTAssertEqual(IFShift.snapped(250), 260)
        XCTAssertEqual(IFShift.snapped(-250), -260)
        XCTAssertEqual(IFShift.snapped(10), 20)
        XCTAssertEqual(IFShift.snapped(-10), -20)
        XCTAssertEqual(IFShift.snapped(9), 0)
    }

    func testSupportedOnlyInVariableWidthModes() {
        for mode in [RigMode.usb, .lsb, .cw, .rtty, .dataUSB] {
            XCTAssertTrue(IFShift.isSupported(mode: mode), "\(mode)")
        }
        for mode in [RigMode.am, .fm, .dataFM, .c4fm, .unknown] {
            XCTAssertFalse(IFShift.isSupported(mode: mode), "\(mode)")
        }
    }

    func testLabels() {
        XCTAssertEqual(IFShift.label(240), "+240 Hz")
        XCTAssertEqual(IFShift.label(-240), "−240 Hz")
        XCTAssertEqual(IFShift.label(0), "0 Hz")
        XCTAssertEqual(IFShift.label(nil), "—")
    }
}

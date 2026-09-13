import XCTest
@testable import FTX1Core

final class IFContourTests: XCTestCase {
    func testContourSnapping() {
        XCTAssertEqual(IFContour.snappedContourHz(5), 10)
        XCTAssertEqual(IFContour.snappedContourHz(3205), 3200)
        XCTAssertEqual(IFContour.snappedContourHz(1244), 1240)
        XCTAssertEqual(IFContour.snappedContourHz(1246), 1250)
    }

    func testAPFSnappingTiesAwayFromZero() {
        XCTAssertEqual(IFContour.snappedAPFHz(-255), -250)
        XCTAssertEqual(IFContour.snappedAPFHz(255), 250)
        XCTAssertEqual(IFContour.snappedAPFHz(-245), -250)
        XCTAssertEqual(IFContour.snappedAPFHz(125), 130)
        XCTAssertEqual(IFContour.snappedAPFHz(-125), -130)
        XCTAssertEqual(IFContour.snappedAPFHz(4), 0)
        XCTAssertEqual(IFContour.snappedAPFHz(0), 0)
    }

    /// "CO03" carries the APF offset as 0000-0050 for −250…+250 Hz.
    func testAPFCodeRoundTrip() {
        XCTAssertEqual(IFContour.apfCode(forHz: -250), 0)
        XCTAssertEqual(IFContour.apfCode(forHz: 0), 25)
        XCTAssertEqual(IFContour.apfCode(forHz: 120), 37)
        XCTAssertEqual(IFContour.apfCode(forHz: 250), 50)
        XCTAssertEqual(IFContour.apfHz(forCode: 0), -250)
        XCTAssertEqual(IFContour.apfHz(forCode: 25), 0)
        XCTAssertEqual(IFContour.apfHz(forCode: 37), 120)
        XCTAssertEqual(IFContour.apfHz(forCode: 50), 250)
        XCTAssertNil(IFContour.apfHz(forCode: 51))
        XCTAssertNil(IFContour.apfHz(forCode: -1))
        for code in 0...50 {
            XCTAssertEqual(IFContour.apfCode(forHz: IFContour.apfHz(forCode: code)!), code)
        }
    }

    func testLabels() {
        XCTAssertEqual(IFContour.contourLabel(1240), "1240 Hz")
        XCTAssertEqual(IFContour.contourLabel(nil), "—")
        XCTAssertEqual(IFContour.apfLabel(120), "+120 Hz")
        XCTAssertEqual(IFContour.apfLabel(-120), "−120 Hz")
        XCTAssertEqual(IFContour.apfLabel(0), "0 Hz")
        XCTAssertEqual(IFContour.apfLabel(nil), "—")
    }

    /// Manual: CONTOUR doesn't work in CW, APF only works in CW.
    func testFaceAndSupportPerMode() {
        for mode in RigMode.allCases {
            let face = IFContour.face(for: mode)
            switch mode {
            case .cw:
                XCTAssertEqual(face, .apf)
                XCTAssertTrue(IFContour.apfSupported(mode: mode))
                XCTAssertFalse(IFContour.contourSupported(mode: mode))
            case .c4fm, .unknown:
                XCTAssertNil(face)
                XCTAssertFalse(IFContour.apfSupported(mode: mode))
                XCTAssertFalse(IFContour.contourSupported(mode: mode))
            case .usb, .lsb, .rtty, .dataUSB:
                XCTAssertEqual(face, .contour)
                XCTAssertTrue(IFContour.contourSupported(mode: mode))
                XCTAssertFalse(IFContour.apfSupported(mode: mode))
            case .am, .fm, .dataFM:
                XCTAssertEqual(face, .contour, "\(mode) shows the contour face, disabled")
                XCTAssertFalse(IFContour.contourSupported(mode: mode))
                XCTAssertFalse(IFContour.apfSupported(mode: mode))
            }
        }
    }
}

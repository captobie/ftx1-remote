import XCTest
@testable import FTX1Core

/// Dragging the Local SDR window's passband edges: snapping, the minimum
/// width, each mode's limits, and CW staying centred on the dial.
final class KiwiPassbandTests: XCTestCase {
    private let usb = KiwiPassband(defaultFor: .usb)

    func testDefaultsAreValid() {
        for mode in KiwiSDRMode.allCases {
            XCTAssertTrue(KiwiPassband(defaultFor: mode).isValid(for: mode), "\(mode)")
        }
    }

    func testEdgesSnapToTenHertz() {
        XCTAssertEqual(usb.dragging(.high, toOffsetHz: 2_344.9, mode: .usb), KiwiPassband(low: 300, high: 2_340))
        XCTAssertEqual(usb.dragging(.high, toOffsetHz: 2_345.1, mode: .usb), KiwiPassband(low: 300, high: 2_350))
        XCTAssertEqual(usb.dragging(.low, toOffsetHz: 104, mode: .usb), KiwiPassband(low: 100, high: 2_700))
    }

    func testUSBStaysAboveTheCarrier() {
        XCTAssertEqual(usb.dragging(.low, toOffsetHz: -500, mode: .usb).low, 0)
        XCTAssertEqual(usb.dragging(.high, toOffsetHz: 9_000, mode: .usb).high, KiwiPassband.limitHz)
    }

    func testLSBStaysBelowTheCarrier() {
        let lsb = KiwiPassband(defaultFor: .lsb)
        XCTAssertEqual(lsb.dragging(.high, toOffsetHz: 500, mode: .lsb).high, 0)
        XCTAssertEqual(lsb.dragging(.low, toOffsetHz: -9_000, mode: .lsb).low, -KiwiPassband.limitHz)
    }

    func testMinimumWidthHoldsOnBothEdges() {
        XCTAssertEqual(usb.dragging(.low, toOffsetHz: 5_000, mode: .usb), KiwiPassband(low: 2_640, high: 2_700))
        XCTAssertEqual(usb.dragging(.high, toOffsetHz: 0, mode: .usb), KiwiPassband(low: 300, high: 360))
        let lsb = KiwiPassband(defaultFor: .lsb)
        XCTAssertEqual(lsb.dragging(.high, toOffsetHz: -5_000, mode: .lsb), KiwiPassband(low: -2_700, high: -2_640))
    }

    func testAMAndFMKeepTheCarrierInside() {
        let am = KiwiPassband(defaultFor: .am)
        let low = am.dragging(.low, toOffsetHz: 1_000, mode: .am)
        XCTAssertEqual(low, KiwiPassband(low: -30, high: 4_900))
        let high = am.dragging(.high, toOffsetHz: -1_000, mode: .am)
        XCTAssertEqual(high, KiwiPassband(low: -4_900, high: 30))
        XCTAssertEqual(am.dragging(.high, toOffsetHz: 2_000, mode: .am), KiwiPassband(low: -4_900, high: 2_000))
    }

    func testCWEitherEdgeMovesBothAroundTheDial() {
        let cw = KiwiPassband(defaultFor: .cw)
        let viaHigh = cw.dragging(.high, toOffsetHz: 100, mode: .cw)
        let viaLow = cw.dragging(.low, toOffsetHz: -100, mode: .cw)
        XCTAssertEqual(viaHigh, KiwiPassband(low: 400, high: 600))
        XCTAssertEqual(viaLow, viaHigh)
    }

    func testCWDialStaysOnTheSignalAtAnyWidth() {
        let cw = KiwiPassband(defaultFor: .cw)
        for offset in stride(from: 10.0, through: 4_000, by: 70) {
            let band = cw.dragging(.high, toOffsetHz: offset, mode: .cw)
            let carrier = KiwiSDRMode.cw.carrierHz(forDialHz: 7_030_000, lowCut: band.low, highCut: band.high)
            XCTAssertEqual(carrier + (band.low + band.high) / 2, 7_030_000, "\(offset)")
            XCTAssertTrue(band.isValid(for: .cw), "\(band)")
        }
    }

    func testCWWiderThanTwicePitchRaisesTheCentreInsteadOfCrossingTheCarrier() {
        let band = KiwiPassband(defaultFor: .cw).dragging(.high, toOffsetHz: 1_200, mode: .cw)
        XCTAssertEqual(band, KiwiPassband(low: 0, high: 2_400))
    }

    func testCWMinimumWidth() {
        let band = KiwiPassband(defaultFor: .cw).dragging(.high, toOffsetHz: -200, mode: .cw)
        XCTAssertEqual(band, KiwiPassband(low: 470, high: 530))
    }

    func testIsValidRejectsBadSavedValues() {
        XCTAssertFalse(KiwiPassband(low: -100, high: 2_700).isValid(for: .usb))
        XCTAssertFalse(KiwiPassband(low: 300, high: 310).isValid(for: .usb))
        XCTAssertFalse(KiwiPassband(low: 300, high: 2_700).isValid(for: .lsb))
        XCTAssertFalse(KiwiPassband(low: 100, high: 4_900).isValid(for: .am))
    }

    func testRangeText() {
        XCTAssertEqual(usb.rangeText(mode: .usb), "300–2700 Hz")
        XCTAssertEqual(KiwiPassband(defaultFor: .lsb).rangeText(mode: .lsb), "300–2700 Hz")
        XCTAssertEqual(KiwiPassband(defaultFor: .am).rangeText(mode: .am), "-4900…+4900 Hz")
    }
}

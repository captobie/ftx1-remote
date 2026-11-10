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

/// MAIN's receive filter → a Kiwi passband.
final class KiwiPassbandRigFilterTests: XCTestCase {
    private func state(_ mode: RigMode, width: Int? = nil, shift: Int? = nil,
                       narrow: (Bool, Int?)? = nil, side: FilterSide? = nil) -> RigState {
        var s = RigState(transmitEnabled: true)
        s.mode = mode
        s.filterWidthIndex = width
        s.ifShiftHz = shift
        s.narrowEnabled = narrow?.0
        s.narrowWidthHz = narrow?.1
        s.filterSide = side
        return s
    }

    private func band(_ s: RigState) -> KiwiPassband? { KiwiPassband(rigFilterOf: s) }

    func testUSBUsesTheFilterDisplaysAudioPassband() {
        // Index 17 is 2700 Hz in SSB; the display model's centre is 1650.
        XCTAssertEqual(band(state(.usb, width: 17)), KiwiPassband(low: 300, high: 3000))
        XCTAssertEqual(band(state(.usb, width: 17, shift: 200)), KiwiPassband(low: 500, high: 3200))
    }

    func testLSBMirrorsBelowTheCarrier() {
        XCTAssertEqual(band(state(.lsb, width: 17)), KiwiPassband(low: -3000, high: -300))
        XCTAssertEqual(band(state(.lsb, width: 17, shift: 200)), KiwiPassband(low: -3200, high: -500))
    }

    func testSSBStaysOnItsSideband() {
        XCTAssertEqual(band(state(.usb, width: 17, shift: -500)), KiwiPassband(low: 0, high: 2500))
        XCTAssertEqual(band(state(.lsb, width: 17, shift: -500)), KiwiPassband(low: -2500, high: 0))
    }

    func testDataUIsCentredWhereTheRigsIs() {
        // Index 18 is 3000 Hz in DATA; centre 1500.
        XCTAssertEqual(band(state(.dataUSB, width: 18)), KiwiPassband(low: 0, high: 3000))
    }

    func testNarrowPresetWins() {
        XCTAssertEqual(band(state(.usb, width: 17, narrow: (true, 1800))), KiwiPassband(low: 750, high: 2550))
        // Off, or not read yet: the wide width.
        XCTAssertEqual(band(state(.usb, width: 17, narrow: (false, 1800))), KiwiPassband(low: 300, high: 3000))
        XCTAssertEqual(band(state(.usb, width: 17, narrow: (true, nil))), KiwiPassband(low: 300, high: 3000))
    }

    func testCWIsCentredOnTheDial() {
        // Index 10 is 500 Hz in CW.
        let result = band(state(.cw, width: 10))
        XCTAssertEqual(result, KiwiPassband(low: 250, high: 750))
        XCTAssertEqual(KiwiSDRMode.cw.carrierHz(forDialHz: 7_030_000, lowCut: 250, highCut: 750), 7_029_500)
    }

    func testCWNarrowerThanTheDragMinimumIsKept() {
        XCTAssertEqual(band(state(.cw, width: 1)), KiwiPassband(low: 475, high: 525))
    }

    func testCWShiftMovesThePassbandAndTheDialStaysOnTheSignal() throws {
        let result = try XCTUnwrap(band(state(.cw, width: 10, shift: 100)))
        XCTAssertEqual(result.low, 350)
        XCTAssertEqual(result.high, 850)
        XCTAssertEqual(result.cwShiftHz, 100)
        let carrier = KiwiSDRMode.cw.carrierHz(forDialHz: 7_030_000, lowCut: result.low, highCut: result.high,
                                               cwShiftHz: result.cwShiftHz)
        XCTAssertEqual(carrier, 7_029_500)   // the signal is still 500 Hz above the carrier
        XCTAssertEqual(carrier + result.low, 7_029_850)
    }

    func testWideCWWithShiftStaysAboveTheCarrierAndOnTheDial() throws {
        // Index 17 is 2400 Hz in CW.
        let result = try XCTUnwrap(band(state(.cw, width: 17, shift: -200)))
        XCTAssertEqual(result.low, 0)
        XCTAssertEqual(result.high, 2400)
        let tuning = KiwiTuning(dialHz: 7_030_000, mode: .cw, lowCut: result.low, highCut: result.high,
                                cwShiftHz: result.cwShiftHz)
        XCTAssertEqual(tuning.carrierHz + (result.low + result.high) / 2, 7_030_000 - 200)
    }

    func testAMAndFMAreSymmetricAndIgnoreShift() {
        XCTAssertEqual(band(state(.am, width: 2, shift: 300)), KiwiPassband(low: -4500, high: 4500))
        XCTAssertEqual(band(state(.am, width: 1)), KiwiPassband(low: -3000, high: 3000))
        XCTAssertEqual(band(state(.fm, width: 2)), KiwiPassband(low: -4500, high: 4500))
        // 16 kHz doesn't fit in the Kiwi's ±6 kHz.
        XCTAssertEqual(band(state(.fm, width: 3)), KiwiPassband(low: -6000, high: 6000))
    }

    func testNothingWhenItCantBeKnown() {
        XCTAssertNil(band(state(.usb)))
        XCTAssertNil(band(state(.usb, width: 0)), "the rig's default index has no width")
        XCTAssertNil(band(state(.rtty, width: 10)), "no Kiwi equivalent")
        XCTAssertNil(band(state(.c4fm, width: 1)))
        XCTAssertNil(band(state(.usb, width: 17, side: .sub)), "the fields hold SUB's values")
    }

    func testDraggingClearsTheShift() throws {
        let shifted = try XCTUnwrap(band(state(.cw, width: 10, shift: 100)))
        XCTAssertEqual(shifted.dragging(.high, toOffsetHz: 150, mode: .cw).cwShiftHz, 0)
    }
}

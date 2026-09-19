import XCTest
@testable import FTX1Core

final class FilterPassbandModelTests: XCTestCase {
    private func state(mode: RigMode, width: Int? = nil, shift: Int? = nil, pitch: Int? = nil,
                       notch: (Bool, Int)? = nil, contour: (Bool, Int)? = nil, apf: (Bool, Int)? = nil,
                       narrow: (Bool, Int?)? = nil) -> RigState {
        var s = RigState(transmitEnabled: true)
        s.narrowEnabled = narrow?.0; s.narrowWidthHz = narrow?.1
        s.mode = mode
        s.filterWidthIndex = width
        s.ifShiftHz = shift
        s.cwPitchHz = pitch
        s.notchEnabled = notch?.0; s.notchHz = notch?.1
        s.contourEnabled = contour?.0; s.contourHz = contour?.1
        s.apfEnabled = apf?.0; s.apfHz = apf?.1
        return s
    }

    func testSSBPassbandCenteredOnConventionPlusShift() {
        // Index 17 is 2700 Hz in SSB; center 1650 → 300…3000.
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17)).passband, 300...3000)
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17, shift: 200)).passband, 500...3200)
        // Shifting below 0 clips at the span edge.
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .lsb, width: 17, shift: -400)).passband, 0...2600)
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17)).widthLabel, "2700 Hz")
    }

    func testCWPassbandCentersOnPitchAndAPFSitsAtPitchPlusOffset() {
        // Index 10 is 500 Hz in CW.
        let model = FilterPassbandModel(state: state(mode: .cw, width: 10, pitch: 700, apf: (true, 100)))
        XCTAssertEqual(model.passband, 450...950)
        XCTAssertEqual(model.apfHz, 800)
        // Default pitch when unknown.
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .cw, width: 10)).passband, 450...950)
        // APF is CW-only.
        XCTAssertNil(FilterPassbandModel(state: state(mode: .usb, width: 17, apf: (true, 100))).apfHz)
        XCTAssertNil(FilterPassbandModel(state: state(mode: .cw, width: 10, apf: (false, 100))).apfHz)
    }

    /// AM/FM scale against the mode's widest filter, centered, so NARROW
    /// visibly shrinks the shape.
    func testFixedWidthModesScaleWithNarrow() {
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .am, width: 2)).passband, FilterPassbandModel.spanHz)
        // AM-N 6000 of 9000 → 2/3 of the span, centered on 2000.
        let amNarrow = FilterPassbandModel(state: state(mode: .am, width: 1)).passband
        XCTAssertEqual(amNarrow?.lowerBound ?? -1, 2000 - 4000 / 3, accuracy: 0.01)
        XCTAssertEqual(amNarrow?.upperBound ?? -1, 2000 + 4000 / 3, accuracy: 0.01)
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .fm, width: 3)).passband, FilterPassbandModel.spanHz)
        // FM-N 9000 of 16000.
        let fmNarrow = FilterPassbandModel(state: state(mode: .fm, width: 2)).passband
        XCTAssertEqual(fmNarrow?.lowerBound ?? -1, 2000 - 4000 * 9 / 32, accuracy: 0.01)
        XCTAssertEqual(fmNarrow?.upperBound ?? -1, 2000 + 4000 * 9 / 32, accuracy: 0.01)
        XCTAssertTrue(FilterPassbandModel(state: state(mode: .am, width: 2)).markers.isEmpty)
    }

    func testMarkersPerMode() {
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .cw, width: 10, pitch: 700)).markers,
                       [.init(label: "P", hz: 700)])
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .cw, width: 10, shift: 40, pitch: 700)).markers,
                       [.init(label: "P", hz: 740)])
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .rtty, width: 10)).markers,
                       [.init(label: "M", hz: 2125), .init(label: "S", hz: 2295)])
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .dataUSB, width: 17)).markers,
                       [.init(label: "C", hz: 1500)])
        // SSB: the bandwidth marker, a dot (nil label) at the passband center.
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17, shift: 200)).markers,
                       [.init(label: nil, hz: 1850)])
        XCTAssertTrue(FilterPassbandModel(state: state(mode: .usb)).markers.isEmpty, "no passband, no markers")
    }

    /// In the variable-width modes NARROW uses the NAR WIDTH preset, since
    /// the "SH" index keeps reporting the wide setting.
    func testNarrowUsesThePresetInVariableWidthModes() {
        let narrow = FilterPassbandModel(state: state(mode: .usb, width: 17, narrow: (true, 1800)))
        XCTAssertEqual(narrow.passband, 750...2550)
        XCTAssertEqual(narrow.widthLabel, "1800 Hz N")
        // NARROW off, or the preset not read yet: the wide width as before.
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17, narrow: (false, 1800))).passband, 300...3000)
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17, narrow: (true, nil))).passband, 300...3000)
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17, narrow: (true, nil))).widthLabel, "2700 Hz")
        // AM ignores the preset field: its "SH" index already reflects NARROW.
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .am, width: 2, narrow: (true, 1800))).passband, FilterPassbandModel.spanHz)
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .am, width: 2, narrow: (true, 1800))).widthLabel, "9000 Hz")
    }

    /// With SUB selected the model uses the Sub receiver's mode, and the
    /// caption says which receiver the picture is of.
    func testSubSideUsesTheSubModeAndCaption() {
        var s = state(mode: .usb, width: 17)
        s.secondaryMode = .cw
        s.cwPitchHz = 700
        // MAIN selected (nil): the USB picture, unprefixed.
        XCTAssertEqual(FilterPassbandModel(state: s).modeName, "USB")
        // SUB selected: filter fields are the Sub side's; mode is CW.
        s.filterSide = .sub
        s.filterWidthIndex = 10   // 500 Hz in the CW column
        let model = FilterPassbandModel(state: s)
        XCTAssertEqual(model.modeName, "SUB CW")
        XCTAssertEqual(model.passband, 450...950)
        XCTAssertEqual(model.markers, [.init(label: "P", hz: 700)])
        XCTAssertEqual(model.widthLabel, "500 Hz")
        // Sub mode unknown (not read yet): nothing to draw.
        s.secondaryMode = nil
        XCTAssertNil(FilterPassbandModel(state: s).passband)
    }

    func testNoFilterModes() {
        XCTAssertNil(FilterPassbandModel(state: state(mode: .c4fm, width: 17)).passband)
        XCTAssertNil(FilterPassbandModel(state: state(mode: .usb)).passband, "unknown width draws nothing")
        // A stale cross-mode index (23 exists in SSB, not CW) draws nothing.
        XCTAssertNil(FilterPassbandModel(state: state(mode: .cw, width: 23)).passband)
    }

    func testNotchAndContourMarkersAreGatedByStateAndMode() {
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17, notch: (true, 1500))).notchHz, 1500)
        XCTAssertNil(FilterPassbandModel(state: state(mode: .usb, width: 17, notch: (false, 1500))).notchHz)
        XCTAssertNil(FilterPassbandModel(state: state(mode: .fm, width: 3, notch: (true, 1500))).notchHz, "notch is inert in FM")
        XCTAssertEqual(FilterPassbandModel(state: state(mode: .usb, width: 17, contour: (true, 1200))).contourHz, 1200)
        XCTAssertNil(FilterPassbandModel(state: state(mode: .cw, width: 10, contour: (true, 1200))).contourHz, "contour doesn't work in CW")
    }

    func testXMapping() {
        let model = FilterPassbandModel(state: state(mode: .usb, width: 17))
        XCTAssertEqual(model.x(0, in: 240), 0)
        XCTAssertEqual(model.x(4000, in: 240), 240)
        XCTAssertEqual(model.x(2000, in: 240), 120)
        XCTAssertEqual(model.x(9999, in: 240), 240, "clamped to the span")
        XCTAssertEqual(model.modeName, "USB")
    }
}

import XCTest
@testable import FTX1Core

final class TransmitPrivilegesTests: XCTestCase {
    private func allows(_ preset: PrivilegePreset, _ hz: Int, _ mode: RigMode,
                        file: StaticString = #filePath, line: UInt = #line) -> Bool {
        preset.profile.allows(dialHz: hz, mode: mode)
    }

    // MARK: Sub-band edges

    func testGeneralTwentyMetrePhoneEdge() {
        XCTAssertTrue(allows(.usGeneral, 14_225_000, .usb))
        XCTAssertFalse(allows(.usGeneral, 14_224_000, .usb))
        XCTAssertTrue(allows(.usExtra, 14_150_000, .usb))
        XCTAssertFalse(allows(.usExtra, 14_149_000, .usb))
        XCTAssertTrue(allows(.usAdvanced, 14_175_000, .usb))
        XCTAssertFalse(allows(.usAdvanced, 14_174_000, .usb))
        // Top of the band: USB at 14.3475 reaches 14.3504.
        XCTAssertTrue(allows(.usGeneral, 14_347_000, .usb))
        XCTAssertFalse(allows(.usGeneral, 14_348_000, .usb))
    }

    /// LSB reaches 2.9 kHz below the dial, so General's 7.175 edge needs
    /// the dial at 7.178 or above.
    func testLowerSidebandHasToClearTheEdge() {
        XCTAssertFalse(allows(.usGeneral, 7_175_000, .lsb))
        XCTAssertFalse(allows(.usGeneral, 7_177_000, .lsb))
        XCTAssertTrue(allows(.usGeneral, 7_178_000, .lsb))
        XCTAssertTrue(allows(.usExtra, 7_128_000, .lsb))
        XCTAssertFalse(allows(.usExtra, 7_126_000, .lsb))
        // And the bottom edge of 160 m.
        XCTAssertFalse(allows(.usGeneral, 1_801_000, .lsb))
        XCTAssertTrue(allows(.usGeneral, 1_803_000, .lsb))
    }

    func testCWAndDataSegments() {
        XCTAssertTrue(allows(.usGeneral, 14_025_500, .cw))
        XCTAssertFalse(allows(.usGeneral, 14_020_000, .cw))
        XCTAssertTrue(allows(.usExtra, 14_001_000, .cw))
        // CW is allowed in the phone segment too.
        XCTAssertTrue(allows(.usGeneral, 14_250_000, .cw))
        // ...and across the CW/data → phone boundary.
        XCTAssertTrue(allows(.usExtra, 14_150_000, .cw))
        // FT8 on 20 m: data, in the CW/data segment.
        XCTAssertTrue(allows(.usGeneral, 14_074_000, .dataUSB))
        XCTAssertTrue(allows(.usGeneral, 14_080_000, .rtty))
        // Data isn't allowed in the HF phone segments.
        XCTAssertFalse(allows(.usExtra, 14_200_000, .dataUSB))
        XCTAssertFalse(allows(.usExtra, 14_148_000, .dataUSB)) // runs past 14.150
        // Phone isn't allowed in the CW/data segment.
        XCTAssertFalse(allows(.usExtra, 14_100_000, .usb))
        // 30 m: no phone for anyone.
        XCTAssertTrue(allows(.usGeneral, 10_136_000, .dataUSB))
        XCTAssertFalse(allows(.usExtra, 10_130_000, .usb))
    }

    func testTechnicianHF() {
        XCTAssertTrue(allows(.usTechnician, 7_030_000, .cw))
        XCTAssertFalse(allows(.usTechnician, 7_030_000, .dataUSB))
        XCTAssertFalse(allows(.usTechnician, 7_200_000, .lsb))
        XCTAssertFalse(allows(.usTechnician, 14_050_000, .cw))
        XCTAssertTrue(allows(.usTechnician, 28_074_000, .dataUSB))
        XCTAssertTrue(allows(.usTechnician, 28_400_000, .usb))
        XCTAssertFalse(allows(.usTechnician, 28_400_000, .am))
        XCTAssertFalse(allows(.usTechnician, 28_498_000, .usb)) // reaches 28.5009
        XCTAssertFalse(allows(.usTechnician, 29_600_000, .fm))
        XCTAssertTrue(allows(.usGeneral, 29_600_000, .fm))
    }

    func testVHFAndUHF() {
        for preset in [PrivilegePreset.usTechnician, .usGeneral, .usExtra] {
            XCTAssertTrue(allows(preset, 146_520_000, .fm))
            XCTAssertTrue(allows(preset, 144_390_000, .dataFM))
            XCTAssertTrue(allows(preset, 446_000_000, .c4fm))
            XCTAssertTrue(allows(preset, 144_050_000, .cw))
            XCTAssertFalse(allows(preset, 144_050_000, .usb))
            XCTAssertTrue(allows(preset, 144_200_000, .usb))
            XCTAssertTrue(allows(preset, 50_125_000, .usb))
            XCTAssertFalse(allows(preset, 50_090_000, .usb))
            // FM's ±8 kHz runs past 148 MHz.
            XCTAssertFalse(allows(preset, 147_995_000, .fm))
        }
        XCTAssertFalse(allows(.usNovice, 146_520_000, .fm))
        XCTAssertFalse(allows(.usNovice, 50_125_000, .usb))
    }

    func testSixtyMetreChannels() {
        // USB 1.5 kHz below each centre; CW and data at the centre.
        for centre in [5_332_000, 5_348_000, 5_358_500, 5_373_000, 5_405_000] {
            XCTAssertTrue(allows(.usGeneral, centre - 1_500, .usb), "\(centre)")
            XCTAssertTrue(allows(.usGeneral, centre, .cw), "\(centre)")
            XCTAssertFalse(allows(.usGeneral, centre, .usb), "\(centre)")
            XCTAssertFalse(allows(.usGeneral, centre + 1_500, .lsb), "\(centre)")
            XCTAssertFalse(allows(.usTechnician, centre, .cw), "\(centre)")
        }
        XCTAssertTrue(allows(.usGeneral, 5_357_000, .dataUSB))   // FT8
        XCTAssertFalse(allows(.usGeneral, 5_340_000, .cw))       // between channels
        XCTAssertFalse(allows(.usGeneral, 5_332_000, .rtty))     // FSK isn't a 60 m emission
    }

    func testRegionPresets() {
        XCTAssertTrue(allows(.ituRegion1, 7_150_000, .lsb))
        XCTAssertFalse(allows(.ituRegion1, 7_250_000, .lsb))
        XCTAssertFalse(allows(.ituRegion1, 147_000_000, .fm))
        XCTAssertTrue(allows(.ituRegion1, 145_500_000, .fm))
        XCTAssertTrue(allows(.ituRegion2, 7_250_000, .lsb))
        XCTAssertTrue(allows(.ituRegion3, 3_850_000, .lsb))
        XCTAssertFalse(allows(.ituRegion3, 3_950_000, .lsb))
        XCTAssertTrue(allows(.ituRegion1, 5_355_000, .cw))
    }

    func testUnknownModeNeverPasses() {
        XCTAssertFalse(allows(.ituRegion2, 14_200_000, .unknown))
    }

    // MARK: Custom segments

    func testCustomSegmentsAndOnlyModes() {
        let profile = PrivilegeProfile(name: "Custom", segments: [
            PrivilegeSegment(lowerHz: 14_000_000, upperHz: 14_100_000, emissions: [.cw]),
            PrivilegeSegment(lowerHz: 14_100_000, upperHz: 14_350_000, emissions: [.phone], onlyModes: [.usb]),
        ])
        XCTAssertTrue(profile.allows(dialHz: 14_050_000, mode: .cw))
        XCTAssertFalse(profile.allows(dialHz: 14_200_000, mode: .cw))
        XCTAssertTrue(profile.allows(dialHz: 14_200_000, mode: .usb))
        XCTAssertFalse(profile.allows(dialHz: 14_200_000, mode: .lsb))
        XCTAssertFalse(profile.allows(dialHz: 14_200_000, mode: .am))
    }

    func testProfileRoundTripsThroughJSON() throws {
        let profile = PrivilegePreset.usGeneral.profile
        let decoded = try JSONDecoder().decode(PrivilegeProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testChoiceRawValues() {
        for choice in [PrivilegeChoice.off, .custom] + PrivilegePreset.allCases.map(PrivilegeChoice.preset) {
            XCTAssertEqual(PrivilegeChoice(rawValue: choice.rawValue), choice)
        }
        XCTAssertEqual(PrivilegeChoice(rawValue: "nonsense"), .off)
    }

    // MARK: Gate

    func testGateUsesTheTransmittingSidesModeAndFrequency() {
        let general = PrivilegePreset.usGeneral.profile
        var state = RigState(frequencyHz: 14_250_000, mode: .usb)
        XCTAssertNil(TransmitGate.blockReason(transmitEnabled: true, state: state, privileges: general))

        state.frequencyHz = 14_200_000
        let reason = TransmitGate.blockReason(transmitEnabled: true, state: state, privileges: general)
        XCTAssertEqual(reason, "Transmit disabled: USB on 14.200.000 MHz is outside US General privileges")
        // Without privileges only the band counts.
        XCTAssertNil(TransmitGate.blockReason(transmitEnabled: true, state: state))

        // TX on SUB: SUB's frequency and mode.
        state.txSide = .sub
        state.secondaryFrequencyHz = 14_030_000
        state.secondaryMode = .cw
        XCTAssertNil(TransmitGate.blockReason(transmitEnabled: true, state: state, privileges: general))
        state.secondaryMode = nil
        XCTAssertNotNil(TransmitGate.blockReason(transmitEnabled: true, state: state, privileges: general))
    }

    func testGateKeepsTheBandCheckAsTheOuterLimit() {
        let wide = PrivilegeProfile(name: "Wide", segments: [
            PrivilegeSegment(lowerHz: 5_000_000, upperHz: 10_000_000, emissions: Set(TransmitEmission.allCases)),
        ])
        let state = RigState(frequencyHz: 9_650_000, mode: .am)
        XCTAssertEqual(TransmitGate.blockReason(transmitEnabled: true, state: state, privileges: wide),
                       "Transmit disabled: outside an amateur band")
    }
}

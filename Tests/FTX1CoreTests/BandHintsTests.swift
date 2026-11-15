import XCTest
@testable import FTX1Core

final class BandHintsTests: XCTestCase {
    private typealias Seg = AmateurBandPlanSegment

    private func plan(_ name: String) -> [Seg] {
        AmateurBandPlan.segments(for: BandPlan.band(named: name)!)
    }

    func testFortyMetres() {
        XCTAssertEqual(plan("40m"), [
            Seg(lowerHz: 7_000_000, upperHz: 7_025_000, usage: .cwData, lowestClass: .extra),
            Seg(lowerHz: 7_025_000, upperHz: 7_125_000, usage: .cwData, lowestClass: .technician),
            Seg(lowerHz: 7_125_000, upperHz: 7_175_000, usage: .phone, lowestClass: .advanced),
            Seg(lowerHz: 7_175_000, upperHz: 7_300_000, usage: .phone, lowestClass: .general),
        ])
    }

    func testTechnicianFoldsIntoGeneral() {
        let forty = AmateurBandPlan.segments(for: BandPlan.band(named: "40m")!, showsTechnician: false)
        XCTAssertEqual(forty[1], Seg(lowerHz: 7_025_000, upperHz: 7_125_000, usage: .cwData, lowestClass: .general))
        XCTAssertFalse(forty.contains { $0.lowestClass == .technician })
        // 10 m: Tech CW/data and phone become General; the two phone parts merge.
        let ten = AmateurBandPlan.segments(for: BandPlan.band(named: "10m")!, showsTechnician: false)
        XCTAssertEqual(ten, [
            Seg(lowerHz: 28_000_000, upperHz: 28_300_000, usage: .cwData, lowestClass: .general),
            Seg(lowerHz: 28_300_000, upperHz: 29_700_000, usage: .phone, lowestClass: .general),
        ])
        // 60 m channels stay apart.
        XCTAssertEqual(AmateurBandPlan.segments(for: BandPlan.band(named: "60m")!, showsTechnician: false).count, 5)
    }

    func testTwentyMetres() {
        XCTAssertEqual(plan("20m"), [
            Seg(lowerHz: 14_000_000, upperHz: 14_025_000, usage: .cwData, lowestClass: .extra),
            Seg(lowerHz: 14_025_000, upperHz: 14_150_000, usage: .cwData, lowestClass: .general),
            Seg(lowerHz: 14_150_000, upperHz: 14_175_000, usage: .phone, lowestClass: .extra),
            Seg(lowerHz: 14_175_000, upperHz: 14_225_000, usage: .phone, lowestClass: .advanced),
            Seg(lowerHz: 14_225_000, upperHz: 14_350_000, usage: .phone, lowestClass: .general),
        ])
    }

    func testTenMetresTechnicianPhone() {
        let ten = plan("10m")
        XCTAssertEqual(ten.first, Seg(lowerHz: 28_000_000, upperHz: 28_300_000, usage: .cwData, lowestClass: .technician))
        XCTAssertTrue(ten.contains(Seg(lowerHz: 28_300_000, upperHz: 28_500_000, usage: .phone, lowestClass: .technician)))
        XCTAssertEqual(ten.last, Seg(lowerHz: 28_500_000, upperHz: 29_700_000, usage: .phone, lowestClass: .general))
    }

    func testSixtyMetresIsFiveChannels() {
        let sixty = plan("60m")
        XCTAssertEqual(sixty.count, 5)
        XCTAssertTrue(sixty.allSatisfy { $0.usage == .channel && $0.lowestClass == .general })
        XCTAssertEqual(sixty.first?.lowerHz, 5_330_600)
    }

    func testOtherBands() {
        XCTAssertEqual(plan("160m"), [Seg(lowerHz: 1_800_000, upperHz: 2_000_000, usage: .allModes, lowestClass: .general)])
        XCTAssertEqual(plan("30m"), [Seg(lowerHz: 10_100_000, upperHz: 10_150_000, usage: .cwData, lowestClass: .general)])
        XCTAssertEqual(plan("6m").first, Seg(lowerHz: 50_000_000, upperHz: 50_100_000, usage: .cwOnly, lowestClass: .technician))
    }

    func testBroadcastBandsGiveWayToAmateurBands() {
        let fortyOne = BandHints.all.filter { $0.label == "41m" }
        XCTAssertEqual(fortyOne.map { [$0.lowerHz, $0.upperHz] }, [[7_300_000, 7_450_000]])
        XCTAssertFalse(BandHints.all.contains { $0.label == "75m" })
        let mw = BandHints.all.first { $0.label == "MW" }
        XCTAssertEqual(mw?.kind, .broadcast)
        XCTAssertEqual(BandHints.hints(lowHz: 7_100_000, highHz: 7_400_000).map(\.label), ["40m", "41m"])
    }

    func testPlanShowsOnceTheBandFillsAThirdOfTheView() {
        let twenty = BandHints.all.first { $0.label == "20m" }!
        // 30 MHz span: name only.
        XCTAssertFalse(BandHints.showsPlan(for: twenty, lowHz: 0, highHz: 30_000_000))
        // ~0.94 MHz span around the band: 350/937 ≥ 1/3.
        XCTAssertTrue(BandHints.showsPlan(for: twenty, lowHz: 13_700_000, highHz: 14_637_500))
        // Zoomed inside the band.
        XCTAssertTrue(BandHints.showsPlan(for: twenty, lowHz: 14_050_000, highHz: 14_080_000))
        // Not in view.
        XCTAssertFalse(BandHints.showsPlan(for: twenty, lowHz: 14_400_000, highHz: 14_500_000))
        let mw = BandHints.all.first { $0.label == "MW" }!
        XCTAssertFalse(BandHints.showsPlan(for: mw, lowHz: 500_000, highHz: 1_000_000))
    }

    func testARRLMarkersForTwentyMetres() {
        let marks = ARRLBandPlan.markers(for: BandPlan.band(named: "20m")!)
        XCTAssertEqual(marks.first, BandPlanMarker(lowerHz: 14_070_000, upperHz: 14_095_000, kind: .data))
        XCTAssertTrue(marks.contains(BandPlanMarker(lowerHz: 14_230_000, upperHz: 14_230_000, kind: .sstv)))
        // Ranges before spots.
        let firstSpot = marks.firstIndex(where: \.isSpot)!
        XCTAssertTrue(marks[firstSpot...].allSatisfy(\.isSpot))
        XCTAssertTrue(marks[..<firstSpot].allSatisfy { !$0.isSpot })
    }

    func testEveryARRLMarkerSitsInsideItsBand() {
        let covered = BandPlan.all.flatMap { ARRLBandPlan.markers(for: $0) }
        XCTAssertEqual(covered.count, ARRLBandPlan.all.count)
        XCTAssertEqual(ARRLBandPlan.markers(for: BandPlan.band(named: "60m")!).map(\.kind), [.ft8])
    }

    func testDigitalModeSpotsLabelFT8First() {
        let marks = ARRLBandPlan.markers(for: BandPlan.band(named: "20m")!)
        let spots = marks.filter(\.isSpot)
        XCTAssertEqual(spots.first, BandPlanMarker(lowerHz: 14_074_000, upperHz: 14_074_000, kind: .ft8))
        XCTAssertTrue(spots.contains(BandPlanMarker(lowerHz: 14_095_600, upperHz: 14_095_600, kind: .wspr)))
        XCTAssertEqual(spots.map(\.kind.labelPriority), spots.map(\.kind.labelPriority).sorted())
    }

    func testAeronauticalAndMaritimeBands() {
        let aero = BandHints.all.filter { $0.kind == .aeronautical }
        XCTAssertTrue(aero.contains(BandHint(label: "8.8 MHz", kind: .aeronautical, lowerHz: 8_815_000, upperHz: 9_040_000)))
        XCTAssertTrue(aero.contains(BandHint(label: "VHF", kind: .aeronautical, lowerHz: 108_000_000, upperHz: 137_000_000)))
        // 3.9 MHz aeronautical lies inside 80 m: dropped.
        XCTAssertFalse(aero.contains { $0.lowerHz == 3_900_000 })
        let maritime = BandHints.all.filter { $0.kind == .maritime }
        XCTAssertTrue(maritime.contains(BandHint(label: "12 MHz", kind: .maritime, lowerHz: 12_230_000, upperHz: 13_200_000)))
        XCTAssertEqual(BandHints.hints(lowHz: 2_100_000, highHz: 2_200_000).map(\.kind), [.maritime])
        // Nothing but amateur bands get a plan.
        XCTAssertFalse(BandHints.showsPlan(for: aero[0], lowHz: 8_800_000, highHz: 9_000_000))
    }

    func testGMDSSFrequenciesInMaritimeBands() {
        let mf = BandHints.all.first { $0.kind == .maritime && $0.lowerHz == 2_045_000 }!
        let marks = GMDSSFrequencies.markers(in: mf)
        XCTAssertEqual(Set(marks.map(\.lowerHz)), [2_174_500, 2_182_000, 2_187_500])
        XCTAssertEqual(marks.first?.kind.labelPriority, 0)
        // Every HF/MF GMDSS frequency sits inside one of the maritime hints.
        let maritime = BandHints.all.filter { $0.kind == .maritime }
        for mark in GMDSSFrequencies.all {
            XCTAssertTrue(maritime.contains { $0.lowerHz <= mark.lowerHz && mark.lowerHz <= $0.upperHz },
                          "\(mark.lowerHz) Hz is outside every maritime band")
        }
        // NAVTEX 490/518 kHz: in the part of the MF band above 630 m.
        let navtexBand = maritime.first { $0.lowerHz == 479_000 }!
        XCTAssertEqual(GMDSSFrequencies.markers(in: navtexBand).map(\.lowerHz), [490_000, 518_000])
        XCTAssertTrue(BandHints.showsPlan(for: mf, lowHz: 2_000_000, highHz: 2_234_000))
    }
}

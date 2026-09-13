import XCTest
@testable import FTX1Core

final class GeneralCoverageSegmentsTests: XCTestCase {
    func testLooksUpBroadcastSegmentByFrequency() {
        let segment = GeneralCoverageSegments.segment(containing: 9_650_000)
        XCTAssertEqual(segment?.name, "SW 31m")
        XCTAssertEqual(segment?.defaultMode, .am)
        XCTAssertEqual(segment?.category, .broadcast)
    }

    func testLooksUpUtilitySegmentByFrequency() {
        let segment = GeneralCoverageSegments.segment(containing: 121_500_000)
        XCTAssertEqual(segment?.name, "Aircraft")
        XCTAssertEqual(segment?.defaultMode, .am)
        XCTAssertEqual(segment?.category, .utility)
    }

    func testFrequencyOutsideAnySegmentReturnsNil() {
        // Between the 30-50MHz general-coverage/ham gap, matching no table.
        XCTAssertNil(GeneralCoverageSegments.segment(containing: 35_000_000))
    }

    func testLooksUpSegmentByName() {
        XCTAssertEqual(GeneralCoverageSegments.segment(named: "FM BCB")?.range, 88_000_000...108_000_000)
        XCTAssertNil(GeneralCoverageSegments.segment(named: "Not A Real Segment"))
    }

    /// Both tables populate the same Band picker and key `BandMemory`'s
    /// per-name last-frequency dictionary, so their names must be unique
    /// across both — this guards against a future addition accidentally
    /// reusing a `BandPlan` ham band name (e.g. plain "60m" or "15m").
    func testNoNameCollidesWithAnAmateurBand() {
        let hamNames = Set(BandPlan.all.map(\.name))
        let segmentNames = Set(GeneralCoverageSegments.all.map(\.name))
        XCTAssertTrue(hamNames.isDisjoint(with: segmentNames))
    }

    func testAllSegmentNamesAreUnique() {
        let names = GeneralCoverageSegments.all.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    /// SW 41m (7200-7450 kHz) geometrically overlaps ham 40m
    /// (7000-7300 kHz). This test documents the precedence a frequency in
    /// that overlap must resolve to for callers that check `BandPlan`
    /// first — the actual precedence logic lives in `HubService`, not in
    /// this shared package, but it depends on `BandPlan.band(containing:)`
    /// reporting a match here so it can be checked ahead of
    /// `GeneralCoverageSegments`.
    func testOverlapWithHamBandIsResolvableByCheckingBandPlanFirst() {
        let overlapping = 7_250_000
        XCTAssertNotNil(GeneralCoverageSegments.segment(containing: overlapping))
        XCTAssertEqual(BandPlan.band(containing: overlapping)?.name, "40m")
    }
}

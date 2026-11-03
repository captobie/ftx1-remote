import XCTest
@testable import FTX1Core

final class RigStateBandTests: XCTestCase {
    /// The Mac's Band picker bug: a tune that writes only `frequencyHz` left
    /// the picker on the old band.
    func testWritingTheFrequencyMovesTheBand() {
        var state = RigState(frequencyHz: 7_074_000, band: "40m")
        state.frequencyHz = 14_200_000
        XCTAssertEqual(state.band, "20m")
    }

    func testGeneralCoverageSegmentAndOutsideEverything() {
        var state = RigState(frequencyHz: 14_200_000, band: "20m")
        state.frequencyHz = 100_000_000
        XCTAssertEqual(state.band, "FM BCB")
        state.frequencyHz = 0
        XCTAssertNil(state.band)
    }

    /// A push from the hub is shown as sent, and `init` keeps what it's given.
    func testDecodingAndInitKeepTheBandAsGiven() throws {
        let state = RigState(frequencyHz: 14_200_000, band: "custom")
        XCTAssertEqual(state.band, "custom")
        let decoded = try JSONDecoder().decode(RigState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.band, "custom")
    }
}

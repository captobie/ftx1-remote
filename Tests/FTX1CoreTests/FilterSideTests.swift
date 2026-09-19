import XCTest
@testable import FTX1Core

final class FilterSideTests: XCTestCase {
    func testP1AndNames() {
        XCTAssertEqual(FilterSide.main.p1, "0")
        XCTAssertEqual(FilterSide.sub.p1, "1")
        XCTAssertEqual(FilterSide.main.displayName, "MAIN")
        XCTAssertEqual(FilterSide.sub.displayName, "SUB")
        XCTAssertEqual(FilterSide.allCases, [.main, .sub])
    }

    func testSetFilterSideWireRoundTrip() throws {
        for (side, raw) in [(FilterSide.main, 0), (.sub, 1)] {
            let command = RigCommand.setFilterSide(side)
            let data = try JSONEncoder().encode(command)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(json?["cmd"] as? String, "set_filter_side")
            XCTAssertEqual(json?["value"] as? Int, raw)
            XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: data), command)
        }
    }

    func testFilterModeFollowsTheSelectedSide() {
        var state = RigState(transmitEnabled: true)
        state.mode = .usb
        state.secondaryMode = .cw
        // nil = MAIN.
        XCTAssertEqual(state.activeFilterSide, .main)
        XCTAssertEqual(state.filterMode, .usb)
        state.filterSide = .sub
        XCTAssertEqual(state.activeFilterSide, .sub)
        XCTAssertEqual(state.filterMode, .cw)
        // Sub mode not read yet.
        state.secondaryMode = nil
        XCTAssertEqual(state.filterMode, .unknown)
        state.filterSide = .main
        XCTAssertEqual(state.filterMode, .usb)
    }

    /// A state push from a peer that predates `filterSide` (key absent) must
    /// still decode, as MAIN — RigState's Codable is synthesized, so this
    /// only works because the field is optional.
    func testStateWithoutFilterSideKeyStillDecodes() throws {
        var state = RigState(transmitEnabled: true)
        state.filterSide = .sub
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertEqual(json["filterSide"] as? Int, 1)
        json.removeValue(forKey: "filterSide")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(RigState.self, from: stripped)
        XCTAssertNil(decoded.filterSide)
        XCTAssertEqual(decoded.activeFilterSide, .main)
    }
}

import XCTest
@testable import FTX1Core

/// "SS"'s COLOR sub-function (P2=3): P3 "0"-"9" then "A" = COLOR-1…11.
final class SpectrumScopeColorTests: XCTestCase {
    func testCodesAreZeroBasedHexDigits() {
        XCTAssertEqual(SpectrumScopeColor.code(for: 0), "0")
        XCTAssertEqual(SpectrumScopeColor.code(for: 9), "9")
        XCTAssertEqual(SpectrumScopeColor.code(for: 10), "A")
        XCTAssertNil(SpectrumScopeColor.code(for: 11))
        XCTAssertNil(SpectrumScopeColor.code(for: -1))
    }

    func testSetCommand() {
        XCTAssertEqual(SpectrumScopeColor.setCommand(0), "SS0300000")
        XCTAssertEqual(SpectrumScopeColor.setCommand(4), "SS0340000")
        XCTAssertEqual(SpectrumScopeColor.setCommand(10), "SS03A0000")
        XCTAssertNil(SpectrumScopeColor.setCommand(11))
    }

    func testParsesAnswers() {
        // Read from the rig over the Pi, 2026-11-27.
        XCTAssertEqual(SpectrumScopeColor.index(fromAnswer: "SS0300000;"), 0)
        XCTAssertEqual(SpectrumScopeColor.index(fromAnswer: "SS0390000;"), 9)
        XCTAssertEqual(SpectrumScopeColor.index(fromAnswer: "SS03A0000;"), 10)
        XCTAssertEqual(SpectrumScopeColor.index(fromAnswer: "SS03a0000;"), 10)
        XCTAssertNil(SpectrumScopeColor.index(fromAnswer: "SS03B0000;"))
        XCTAssertNil(SpectrumScopeColor.index(fromAnswer: "?;"))
        XCTAssertNil(SpectrumScopeColor.index(fromAnswer: "SS0100000;"))
        XCTAssertNil(SpectrumScopeColor.index(fromAnswer: "SS03"))
    }

    func testLabels() {
        XCTAssertEqual(SpectrumScopeColor.label(0), "COLOR-1")
        XCTAssertEqual(SpectrumScopeColor.label(10), "COLOR-11")
        XCTAssertEqual(SpectrumScopeColor.label(nil), "—")
        XCTAssertEqual(SpectrumScopeColor.label(11), "—")
    }

    func testCommandRoundTrip() throws {
        let data = try JSONEncoder().encode(RigCommand.setDisplayColor(10))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "set_display_color")
        XCTAssertEqual(json?["value"] as? Int, 10)
        XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: data), .setDisplayColor(10))
    }

    func testStateFieldIsOptionalOnTheWire() throws {
        var state = RigState()
        state.displayColor = 3
        let decoded = try JSONDecoder().decode(RigState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.displayColor, 3)
        // An older hub's push has no "displayColor".
        let older = try JSONDecoder().decode(RigState.self, from: JSONEncoder().encode(RigState()))
        XCTAssertNil(older.displayColor)
    }
}

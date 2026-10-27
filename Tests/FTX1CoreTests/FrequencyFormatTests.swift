import XCTest
@testable import FTX1Core

final class FrequencyFormatTests: XCTestCase {
    func testDottedGroupsLikeTheRig() {
        XCTAssertEqual(FrequencyFormat.dotted(147_380_000), "147.380.000")
        XCTAssertEqual(FrequencyFormat.dotted(14_074_000), "14.074.000")
        XCTAssertEqual(FrequencyFormat.dotted(475_000), "475.000")
        XCTAssertEqual(FrequencyFormat.dotted(1_005), "1.005")
        XCTAssertEqual(FrequencyFormat.dotted(0), "0")
    }

    func testMHzUsesADecimalPoint() {
        XCTAssertEqual(FrequencyFormat.mhz(14_074_000, fractionDigits: 4), "14.0740")
        XCTAssertEqual(FrequencyFormat.mhz(144_390_000.0, fractionDigits: 3), "144.390")
    }

    /// Spanish and German write "14,074" — the field style must not.
    func testFieldStyleIgnoresTheLocale() throws {
        let style = FrequencyFormat.mhzField(fractionLength: 3...6)
        XCTAssertEqual(144.39.formatted(style), "144.390")
        XCTAssertEqual(1296.5.formatted(style), "1296.500")
        XCTAssertEqual(try style.parseStrategy.parse("14.0745"), 14.0745, accuracy: 1e-9)
        let german = style.locale(Locale(identifier: "de_DE"))
        XCTAssertNotEqual(144.39.formatted(german), "144.390", "sanity: a German style would differ")
    }
}

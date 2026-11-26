import XCTest
@testable import FTX1Core

final class KiwiSDRDirectoryTests: XCTestCase {
    func testLeftoverEscapesAreDecoded() {
        // As the mirror serves them: escaped twice, so one layer is left
        // after JSON decoding.
        XCTAssertEqual(KiwiSDRDirectory.unescapingLeftovers(#"\u26f0\ufe0f 0\u201330 MHz SDR \u00b7 Napier \ud83c\uddf3\ud83c\uddff"#),
                       "\u{26F0}\u{FE0F} 0\u{2013}30 MHz SDR \u{00B7} Napier 🇳🇿")
        XCTAssertEqual(KiwiSDRDirectory.unescapingLeftovers(#"ZL2J 400m Doublet \"NEW A\" 50\/50 C:\\"#),
                       #"ZL2J 400m Doublet "NEW A" 50/50 C:\"#)
    }

    func testPlainTextAndOddBackslashesAreKept() {
        XCTAssertEqual(KiwiSDRDirectory.unescapingLeftovers("Government Camp, OR"), "Government Camp, OR")
        XCTAssertEqual(KiwiSDRDirectory.unescapingLeftovers(#"a\b \uZZZZ \u12"#), #"a\b \uZZZZ \u12"#)
    }

    func testParseDecodesNames() throws {
        let file = #"var kiwisdr_com = [ {"id":"1","name":"\\u26f0 Peak","url":"http://kiwi.example:8073"}, ];"#
        let stations = try XCTUnwrap(KiwiSDRDirectory.parse(Data(file.utf8)))
        XCTAssertEqual(stations.first?.name, "\u{26F0} Peak")
    }
}

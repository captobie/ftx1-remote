import XCTest
@testable import FTX1Core

/// Settings → Appearance → Theme: the theme model, presets and the
/// 7-segment digit strings (`ThemeDefinition.swift`). Ported from the
/// Windows app's ThemeTests, same cases.
final class ThemeTests: XCTestCase {
    func testParsesColors() {
        XCTAssertEqual(ThemeColor(hex: "#FF8000"), ThemeColor(a: 255, r: 255, g: 128, b: 0))
        XCTAssertEqual(ThemeColor(hex: "#80FFFFFF"), ThemeColor(a: 128, r: 255, g: 255, b: 255))
        XCTAssertEqual(ThemeColor(hex: "1AE4F2FF"), ThemeColor(a: 0x1A, r: 0xE4, g: 0xF2, b: 0xFF))
    }

    func testRejectsBadColors() {
        for hex in ["", "#FFF", "#GG0000", "#+12345", nil] {
            XCTAssertNil(ThemeColor(hex: hex), String(describing: hex))
        }
        XCTAssertThrowsError(try ThemeColor.parse("nope"))
    }

    func testColorRoundTrips() {
        XCTAssertEqual(ThemeColor(hex: "#2D6BD0")?.description, "#FF2D6BD0")
    }

    func testFillSpreadsOffsetsEvenly() throws {
        let stops = try ThemeFill(colors: ["#000000", "#808080", "#FFFFFF"]).stops()
        XCTAssertEqual(stops.map(\.offset), [0, 0.5, 1])
    }

    func testFillWithMismatchedOffsetsIsRejected() {
        XCTAssertThrowsError(try ThemeFill(colors: ["#000000", "#FFFFFF"], offsets: [0]).stops())
        XCTAssertThrowsError(try ThemeFill(colors: []).stops())
    }

    func testPresetsAreValidAndUniquelyNamed() throws {
        for theme in ThemePresets.all {
            try theme.validate()
        }
        XCTAssertEqual(Set(ThemePresets.names).count, ThemePresets.names.count)
        XCTAssertEqual(ThemePresets.names.first, ThemePresets.auto)
    }

    /// The defaults must be the app as it looked before themes.
    func testDefaultThemesOverrideNothing() {
        for theme in [ThemePresets.defaultLight, ThemePresets.defaultDark] {
            XCTAssertNil(theme.windowBackground)
            XCTAssertNil(theme.buttonBackground)
            XCTAssertNil(theme.buttonCheckedBackground)
            XCTAssertNil(theme.accent)
            XCTAssertNil(theme.menuValueColor)
            XCTAssertFalse(theme.stylesButtons)
            XCTAssertEqual(theme.vfo, VFOTheme())
        }
        XCTAssertEqual(ThemePresets.defaultLight.base, .light)
        XCTAssertEqual(ThemePresets.defaultDark.base, .dark)
    }

    func testGlossyBlackIsGlossy() throws {
        let glossy = ThemePresets.glossyBlack
        XCTAssertEqual(glossy.base, .dark)
        XCTAssertTrue(glossy.stylesButtons)
        XCTAssertEqual(glossy.buttonBackground?.isGradient, true)
        XCTAssertEqual(glossy.windowBackground?.isGradient, true)
        // Lighter than dark mode's black.
        let bottom = try XCTUnwrap(glossy.windowBackground?.colors.last)
        XCTAssertGreaterThan(try ThemeColor.parse(bottom).r, 0x10)
        XCTAssertEqual(glossy.vfo.digitFont, .sevenSegment)
    }

    /// Same values as the Windows app's presets.
    func testPresetsMatchWindows() {
        XCTAssertEqual(ThemePresets.dustyRose.accent, "#FF7A453D")
        XCTAssertEqual(ThemePresets.dustyRose.windowBackground?.colors, ["#FFF3E8E6", "#FFEEDFDC"])
        XCTAssertEqual(ThemePresets.icyMint.accent, "#FF1FA08B")
        XCTAssertEqual(ThemePresets.icyMint.vfo.digits, "#FFE6FFF9")
        XCTAssertEqual(ThemePresets.glossyBlack.vfo.unlitSegments, "#1AE4F2FF")
    }

    func testResolvesNames() {
        XCTAssertEqual(ThemePresets.resolve("Glossy Black", systemIsDark: false).name, "Glossy Black")
        XCTAssertEqual(ThemePresets.resolve("Auto", systemIsDark: true).name, "Default Dark")
        XCTAssertEqual(ThemePresets.resolve("Auto", systemIsDark: false).name, "Default Light")
        XCTAssertEqual(ThemePresets.resolve("Gone Theme", systemIsDark: true).name, "Default Dark")
        XCTAssertEqual(ThemePresets.resolve(nil, systemIsDark: false).name, "Default Light")
        XCTAssertNil(ThemePresets.named("Auto"))
    }

    func testMigratesLegacyTheme() {
        XCTAssertEqual(ThemePresets.fromLegacy(.system), "Auto")
        XCTAssertEqual(ThemePresets.fromLegacy(.light), "Default Light")
        XCTAssertEqual(ThemePresets.fromLegacy(.dark), "Default Dark")
    }

    /// Custom themes (phase 2) will be JSON.
    func testThemeJSONRoundTrips() throws {
        let data = try JSONEncoder().encode(ThemePresets.glossyBlack)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"sevenSegment\""))
        XCTAssertTrue(json.contains("\"dark\""))
        XCTAssertEqual(try JSONDecoder().decode(ThemeDefinition.self, from: data), ThemePresets.glossyBlack)
    }

    /// The Mac groups Hz by thousands, so the first group is MHz for any
    /// frequency the FTX-1 tunes (≤ 470 MHz).
    func testSevenSegmentStrings() {
        let cases: [(String, String, String)] = [
            ("7.074.000", "!!7.074.000", "888.888.888"),
            ("14.074.000", "!14.074.000", "888.888.888"),
            ("144.390.000", "144.390.000", "888.888.888"),
            ("430.000.000", "430.000.000", "888.888.888"),
            ("—", "---.---.---", "888.888.888"),
            ("", "---.---.---", "888.888.888"),
        ]
        for (text, lit, unlit) in cases {
            XCTAssertEqual(SevenSegmentText.lit(text), lit, text)
            XCTAssertEqual(SevenSegmentText.unlit(SevenSegmentText.lit(text)), unlit, text)
        }
    }

    func testSevenSegmentFontIsBundled() {
        XCTAssertTrue(VFODigitFonts.hasSevenSegment)
    }
}

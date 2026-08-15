import XCTest
@testable import FTX1Core

/// Structural sanity checks for `DeepSettingsCatalog` — with ~100+ items
/// per category hand-transcribed from the CAT manual, these catch
/// transcription slips (a duplicated P1/P2/P3 address, a reused
/// enumeration index, digits too narrow for the declared range) that
/// wouldn't otherwise surface until clicking through every row by hand.
/// Doesn't check labels/values against the manual itself — that's still a
/// per-category read-through — just that the catalog is internally
/// consistent.
final class DeepSettingsCatalogTests: XCTestCase {
    func testNoDuplicateItemAddresses() {
        let ids = DeepSettingsCatalog.items.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate p1.p2.p3 address in the catalog")
    }

    func testNoDuplicateEnumerationIndices() {
        for item in DeepSettingsCatalog.items {
            guard case .enumeration(let cases, _) = item.valueType else { continue }
            let indices = cases.map(\.index)
            XCTAssertEqual(indices.count, Set(indices).count, "\(item.id) (\(item.label)) has a duplicate enumeration index")
        }
    }

    /// Every enumeration/intRange/signedRange value must actually fit in
    /// its declared `digits` width — a range that needs 3 digits but is
    /// declared with `digits: 2` would silently truncate on encode.
    func testDigitsAreWideEnoughForDeclaredRange() {
        for item in DeepSettingsCatalog.items {
            switch item.valueType {
            case .enumeration(let cases, let digits):
                for c in cases {
                    XCTAssertLessThanOrEqual(
                        String(c.index).count, digits,
                        "\(item.id) (\(item.label)) index \(c.index) doesn't fit in \(digits) digits"
                    )
                }
            case .intRange(let range, let digits, _, _):
                XCTAssertLessThanOrEqual(
                    String(range.upperBound).count, digits,
                    "\(item.id) (\(item.label)) upper bound \(range.upperBound) doesn't fit in \(digits) digits"
                )
            case .signedRange(let range, let digits, _, _):
                let maxMagnitude = max(abs(range.lowerBound), abs(range.upperBound))
                XCTAssertLessThanOrEqual(
                    String(maxMagnitude).count, digits,
                    "\(item.id) (\(item.label)) magnitude \(maxMagnitude) doesn't fit in \(digits) digits"
                )
            default:
                break
            }
        }
    }

    /// Regression guard for the RADIO SETTING transcription itself — this
    /// only checks the item counts documented per tab in Table 3 (pages
    /// 10-11), so an accidental dropped/duplicated row trips it even
    /// though the label/value content isn't re-checked here.
    func testRadioSettingTabCounts() {
        let radioItems = DeepSettingsCatalog.items(forP1: 1)
        let countsByTab = Dictionary(grouping: radioItems, by: \.p2).mapValues(\.count)
        XCTAssertEqual(countsByTab[1], 17, "MODE SSB")
        XCTAssertEqual(countsByTab[2], 15, "MODE AM")
        XCTAssertEqual(countsByTab[3], 37, "MODE FM")
        XCTAssertEqual(countsByTab[4], 18, "MODE DATA")
        XCTAssertEqual(countsByTab[5], 16, "MODE RTTY")
        XCTAssertEqual(countsByTab[6], 5, "DIGITAL")
        XCTAssertEqual(radioItems.count, 108)
    }

    func testCWSettingTabCounts() {
        let cwItems = DeepSettingsCatalog.items(forP1: 2)
        let countsByTab = Dictionary(grouping: cwItems, by: \.p2).mapValues(\.count)
        XCTAssertEqual(countsByTab[1], 18, "MODE CW")
        XCTAssertEqual(countsByTab[2], 11, "KEYER")
        XCTAssertEqual(cwItems.count, 29)
    }

    func testDisplaySettingTabCounts() {
        let displayItems = DeepSettingsCatalog.items(forP1: 4)
        let countsByTab = Dictionary(grouping: displayItems, by: \.p2).mapValues(\.count)
        XCTAssertEqual(countsByTab[1], 7, "DISPLAY (LED DIMMER deliberately excluded)")
        XCTAssertEqual(countsByTab[2], 7, "UNIT")
        XCTAssertEqual(countsByTab[3], 5, "SCOPE")
        XCTAssertEqual(countsByTab[4], 3, "VFO IND COLOR")
    }
}

import Foundation

/// How one Deep Settings item's CAT value (P4 of the "EX" command — see
/// `RigctldClient.getMenuItem`) is shaped, per the CAT manual's "Table 3
/// (MENU Chart)". `digits` is always the *magnitude* width the manual's
/// own "Digits" column documents (e.g. 2 for a "00-20" field) — for
/// `.signedRange`, the wire value additionally carries a leading sign
/// character not counted in `digits`.
public enum DeepSettingValueType: Sendable {
    /// A single named option of a `.enumeration` field. A nominal type
    /// rather than a plain `(Int, String)` tuple so it can be `Identifiable`
    /// for `ForEach` (tuples can't conform to protocols).
    public struct EnumerationCase: Identifiable, Sendable, Equatable {
        public let index: Int
        public let label: String
        public var id: Int { index }
        public init(_ index: Int, _ label: String) {
            self.index = index
            self.label = label
        }
    }

    case toggle(offLabel: String, onLabel: String)
    case enumeration(cases: [EnumerationCase], digits: Int)
    case intRange(ClosedRange<Int>, digits: Int, unit: String?)
    case signedRange(ClosedRange<Int>, digits: Int, unit: String?)
    case text(maxLength: Int)
    /// P4 is documented as "—" (a list, ID, or other non-editable readout).
    case readOnly
    /// Momentary or irreversible (CALIBRATION, ALL RESET, FIRMWARE UPDATE,
    /// MENU/MEM LOAD & SAVE, FORMAT, ...) — deliberately not wired to fire
    /// from this screen; rendered disabled.
    case action
}

extension DeepSettingValueType: Equatable {
    public static func == (lhs: DeepSettingValueType, rhs: DeepSettingValueType) -> Bool {
        switch (lhs, rhs) {
        case (.toggle(let a1, let a2), .toggle(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.enumeration(let a1, let a2), .enumeration(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.intRange(let a1, let a2, let a3), .intRange(let b1, let b2, let b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case (.signedRange(let a1, let a2, let a3), .signedRange(let b1, let b2, let b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case (.text(let a), .text(let b)):
            return a == b
        case (.readOnly, .readOnly), (.action, .action):
            return true
        default:
            return false
        }
    }
}

/// A typed, decoded Deep Settings value — the counterpart to the raw P4
/// string `RigctldClient.getMenuItem`/`setMenuItem` moves over the wire.
public enum DeepSettingValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case text(String)
}

/// One row of the CAT manual's "Table 3 (MENU Chart)" — the FTX-1's deep
/// SET-mode settings (Radio/CW/Operation/Display/Extension/APRS Setting on
/// the real rig), addressed by `p1`/`p2`/`p3` (category/tab/item) rather
/// than each having its own CAT mnemonic. This is the one place per-item
/// cost lives for this feature: unlike the numbered MENU grid (where a new
/// button needs a new `RigCommand` case, `RigState` field, `CommandQueue`
/// arm, poll line, and view branch), a new Deep Settings item is just one
/// more entry in `DeepSettingsCatalog.items` — encoding/decoding is generic
/// over `valueType`, and reads/writes go through the single
/// `RigCommand.setMenuItem`/`RigctldClient.getMenuItem` passthrough.
public struct DeepSettingItem: Identifiable, Sendable, Equatable {
    public let p1: Int
    public let p2: Int
    public let p3: Int
    public let category: String
    public let tab: String
    public let label: String
    public let valueType: DeepSettingValueType

    public var id: String { "\(p1).\(p2).\(p3)" }

    public init(p1: Int, p2: Int, p3: Int, category: String, tab: String, label: String, valueType: DeepSettingValueType) {
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
        self.category = category
        self.tab = tab
        self.label = label
        self.valueType = valueType
    }

    /// Decodes a raw P4 string (as returned by `RigctldClient.getMenuItem`)
    /// into a typed value, per `valueType`. Returns nil for `.readOnly`/
    /// `.action` items (nothing meaningful to decode) or malformed input.
    public func decode(_ raw: String) -> DeepSettingValue? {
        switch valueType {
        case .toggle:
            if raw == "1" { return .bool(true) }
            if raw == "0" { return .bool(false) }
            return nil
        case .enumeration(_, let digits):
            guard let index = Int(raw.prefix(digits)) else { return nil }
            return .int(index)
        case .intRange(_, let digits, _):
            guard let value = Int(raw.prefix(digits)) else { return nil }
            return .int(value)
        case .signedRange:
            guard let value = Int(raw) else { return nil }
            return .int(value)
        case .text:
            return .text(raw)
        case .readOnly, .action:
            return nil
        }
    }

    /// Encodes a typed value into the raw P4 string `RigctldClient.
    /// setMenuItem` sends. The inverse of `decode(_:)`.
    public func encode(_ value: DeepSettingValue) -> String? {
        switch (valueType, value) {
        case (.toggle, .bool(let on)):
            return on ? "1" : "0"
        case (.enumeration(_, let digits), .int(let index)):
            return String(format: "%0\(digits)d", index)
        case (.intRange(_, let digits, _), .int(let v)):
            return String(format: "%0\(digits)d", v)
        case (.signedRange(_, let digits, _), .int(let v)):
            let sign = v < 0 ? "-" : "+"
            return sign + String(format: "%0\(digits)d", abs(v))
        case (.text(let maxLength), .text(let s)):
            return String(s.prefix(maxLength))
        default:
            return nil
        }
    }
}

/// The FTX-1's deep SET-mode settings, per "Table 3 (MENU Chart)" in the
/// CAT Operation Reference Manual (pages 9-14). `p1` groups match the
/// manual's own category numbering; the real rig's page-3 "APRS SETTING"
/// button spans `p1` 6-8 (APRS Setting/Beacon/Filter are three separate
/// Table 3 categories that share one physical entry point).
public enum DeepSettingsCatalog {
    public static let categories: [(p1: Int, name: String)] = [
        (1, "RADIO SETTING"),
        (2, "CW SETTING"),
        (3, "OPERATION SETTING"),
        (4, "DISPLAY SETTING"),
        (5, "EXTENSION SETTING"),
        (6, "APRS SETTING"),
        (7, "APRS BEACON"),
        (8, "APRS FILTER"),
    ]

    /// Populated incrementally, one `p1` category at a time, each
    /// spot-checked against real hardware before being trusted — same
    /// practice as every other raw CAT command wired in this app so far.
    public static let items: [DeepSettingItem] = displaySettingItems

    /// P1=04 (DISPLAY SETTING), transcribed from the CAT manual's Table 3,
    /// page 13. Not yet hardware-verified — encodings/labels here are as
    /// documented, still subject to the same "manual isn't always right"
    /// caveat as every other raw CAT command in this app (confirmed once
    /// already for "AC"/tuner).
    ///
    /// `04.01.08` (LED DIMMER, 00-20) is deliberately **not** included:
    /// it's the same physical rig setting as the already-wired "DA"
    /// command's P4 field (the SSB MENU page's DIMMER button) — adding it
    /// here too would give the same value two separate UI paths.
    /// AUTO POWER OFF's real range, confirmed against the user's actual
    /// rig display (the manual's own cell for this item — "0: OFF  1:
    /// 0.5-24 (12: hour)" — is too condensed to parse on its own, and its
    /// printed "Digits" column of 1 turned out to be wrong; a 0-24 index
    /// needs 2). Index 0 is OFF, indices 1-24 step linearly by 0.5h up to
    /// 12h — generated rather than hand-listed to avoid 24 chances to
    /// mistype a half-hour label.
    private static let autoPowerOffCases: [DeepSettingValueType.EnumerationCase] = {
        var cases: [DeepSettingValueType.EnumerationCase] = [.init(0, "OFF")]
        for index in 1...24 {
            let hours = Double(index) / 2
            let label = hours.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(hours)) h" : "\(hours) h"
            cases.append(.init(index, label))
        }
        return cases
    }()

    private static let displaySettingItems: [DeepSettingItem] = [
        // 04.01 (DISPLAY)
        DeepSettingItem(p1: 4, p2: 1, p3: 1, category: "DISPLAY SETTING", tab: "DISPLAY", label: "MY CALL", valueType: .text(maxLength: 10)),
        DeepSettingItem(p1: 4, p2: 1, p3: 2, category: "DISPLAY SETTING", tab: "DISPLAY", label: "MY CALL TIME", valueType: .enumeration(cases: [
            .init(0, "OFF"), .init(1, "1 sec"), .init(2, "2 sec"), .init(3, "3 sec"), .init(4, "4 sec"), .init(5, "5 sec"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 1, p3: 3, category: "DISPLAY SETTING", tab: "DISPLAY", label: "POP-UP TIME", valueType: .enumeration(cases: [
            .init(0, "FAST"), .init(1, "MID"), .init(2, "SLOW"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 1, p3: 4, category: "DISPLAY SETTING", tab: "DISPLAY", label: "SCREEN SAVER", valueType: .enumeration(cases: [
            .init(0, "OFF"), .init(1, "1 min"), .init(2, "2 min"), .init(3, "5 min"), .init(4, "15 min"), .init(5, "30 min"), .init(6, "60 min"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 1, p3: 5, category: "DISPLAY SETTING", tab: "DISPLAY", label: "SCREEN SAVER (BAT)", valueType: .enumeration(cases: [
            .init(0, "OFF"), .init(1, "1 min"), .init(2, "2 min"), .init(3, "5 min"), .init(4, "15 min"), .init(5, "30 min"), .init(6, "60 min"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 1, p3: 6, category: "DISPLAY SETTING", tab: "DISPLAY", label: "SAVER TYPE", valueType: .enumeration(cases: [
            .init(0, "Logo"), .init(1, "DIMMER"), .init(2, "DISP OFF"),
        ], digits: 1)),
        // See autoPowerOffCases above — confirmed OFF + 0.5h steps to 12h,
        // 2 digits, not the manual's condensed/mistranscribed 1-digit cell.
        DeepSettingItem(p1: 4, p2: 1, p3: 7, category: "DISPLAY SETTING", tab: "DISPLAY", label: "AUTO POWER OFF", valueType: .enumeration(cases: autoPowerOffCases, digits: 2)),

        // 04.02 (UNIT)
        DeepSettingItem(p1: 4, p2: 2, p3: 1, category: "DISPLAY SETTING", tab: "UNIT", label: "POSITION UNIT", valueType: .enumeration(cases: [
            .init(0, "dd°MM.mm'"), .init(1, "dd°mm'ss\""),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 2, p3: 2, category: "DISPLAY SETTING", tab: "UNIT", label: "DISTANCE UNIT", valueType: .enumeration(cases: [
            .init(0, "km"), .init(1, "mile"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 2, p3: 3, category: "DISPLAY SETTING", tab: "UNIT", label: "SPEED UNIT", valueType: .enumeration(cases: [
            .init(0, "km/h"), .init(1, "knot"), .init(2, "mph"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 2, p3: 4, category: "DISPLAY SETTING", tab: "UNIT", label: "ALTITUDE UNIT", valueType: .enumeration(cases: [
            .init(0, "m"), .init(1, "ft"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 2, p3: 5, category: "DISPLAY SETTING", tab: "UNIT", label: "TEMP UNIT", valueType: .enumeration(cases: [
            .init(0, "°C"), .init(1, "°F"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 2, p3: 6, category: "DISPLAY SETTING", tab: "UNIT", label: "RAIN UNIT", valueType: .enumeration(cases: [
            .init(0, "mm"), .init(1, "INCH"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 2, p3: 7, category: "DISPLAY SETTING", tab: "UNIT", label: "WIND UNIT", valueType: .enumeration(cases: [
            .init(0, "m/s"), .init(1, "mph"),
        ], digits: 1)),

        // 04.03 (SCOPE)
        DeepSettingItem(p1: 4, p2: 3, p3: 1, category: "DISPLAY SETTING", tab: "SCOPE", label: "RBW", valueType: .enumeration(cases: [
            .init(0, "HIGH"), .init(1, "MID"), .init(2, "LOW"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 3, p3: 2, category: "DISPLAY SETTING", tab: "SCOPE", label: "SCOPE CTR", valueType: .enumeration(cases: [
            .init(0, "FILTER"), .init(1, "CARRIER"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 3, p3: 3, category: "DISPLAY SETTING", tab: "SCOPE", label: "2D DISP SENSITIVITY", valueType: .enumeration(cases: [
            .init(0, "NORMAL"), .init(1, "HI"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 3, p3: 4, category: "DISPLAY SETTING", tab: "SCOPE", label: "3DSS DISP SENSITIVITY", valueType: .enumeration(cases: [
            .init(0, "NORMAL"), .init(1, "HI"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 3, p3: 5, category: "DISPLAY SETTING", tab: "SCOPE", label: "AVERAGE", valueType: .enumeration(cases: [
            .init(0, "OFF"), .init(1, "2"), .init(2, "4"), .init(3, "8"),
        ], digits: 1)),

        // 04.04 (VFO IND COLOR)
        DeepSettingItem(p1: 4, p2: 4, p3: 1, category: "DISPLAY SETTING", tab: "VFO IND COLOR", label: "VMI COLOR VFO", valueType: .enumeration(cases: [
            .init(0, "BLUE"), .init(1, "GREEN"), .init(2, "WHITE"), .init(3, "NONE"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 4, p3: 2, category: "DISPLAY SETTING", tab: "VFO IND COLOR", label: "VMI COLOR MEMORY", valueType: .enumeration(cases: [
            .init(0, "BLUE"), .init(1, "GREEN"), .init(2, "WHITE"), .init(3, "NONE"),
        ], digits: 1)),
        DeepSettingItem(p1: 4, p2: 4, p3: 3, category: "DISPLAY SETTING", tab: "VFO IND COLOR", label: "VMI COLOR CLAR", valueType: .enumeration(cases: [
            .init(0, "RED"), .init(1, "NONE"),
        ], digits: 1)),
    ]

    public static func items(forP1 p1: Int) -> [DeepSettingItem] {
        items.filter { $0.p1 == p1 }
    }

    public static func tabs(forP1s p1s: [Int]) -> [(p1: Int, p2: Int, name: String)] {
        var seen: Set<String> = []
        var result: [(p1: Int, p2: Int, name: String)] = []
        for item in items where p1s.contains(item.p1) {
            let key = "\(item.p1).\(item.p2)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append((item.p1, item.p2, item.tab))
        }
        return result
    }
}

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
    /// `step` is the Stepper's UI increment (e.g. 20 for a "20msec/step"
    /// field) — decode/encode round-trip the raw value regardless of step.
    case intRange(ClosedRange<Int>, digits: Int, unit: String?, step: Int)
    case signedRange(ClosedRange<Int>, digits: Int, unit: String?, step: Int)
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
        case (.intRange(let a1, let a2, let a3, let a4), .intRange(let b1, let b2, let b3, let b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case (.signedRange(let a1, let a2, let a3, let a4), .signedRange(let b1, let b2, let b3, let b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
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
        case .intRange(_, let digits, _, _):
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
        case (.intRange(_, let digits, _, _), .int(let v)):
            return String(format: "%0\(digits)d", v)
        case (.signedRange(_, let digits, _, _), .int(let v)):
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
    public static let items: [DeepSettingItem] = radioSettingItems + cwSettingItems + operationSettingItems + displaySettingItems

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
    /// P1=01 (RADIO SETTING) value types shared across the MODE SSB/AM/FM/
    /// DATA/RTTY tabs — Table 3 repeats the same field definitions (AF
    /// TREBLE/MIDDLE/BASS GAIN, AGC delays, LCUT/HCUT FREQ+SLOPE, USB OUT
    /// LEVEL/MOD GAIN, TX BPF SEL, MOD SOURCE, RPTT SELECT) once per mode.
    /// Declared once from MODE SSB's cells (the most legibly printed) and
    /// reused, rather than re-derived per tab: a couple of other tabs'
    /// printed "Digits" column for these exact same fields didn't scan
    /// legibly (e.g. RTTY/FM's USB OUT LEVEL cell read as 1 digit, which
    /// can't hold a 0-100 range at all — almost certainly a column-
    /// alignment artifact in that particular cell, not a real per-mode
    /// difference in an otherwise identical field).
    private enum RadioSettingShared {
        static let signedGain = DeepSettingValueType.signedRange(-20...10, digits: 2, unit: "dB", step: 1)
        static let agcDelay = DeepSettingValueType.intRange(20...4000, digits: 4, unit: "msec", step: 20)
        static let cutSlope = DeepSettingValueType.enumeration(cases: [
            .init(0, "6 dB/oct"), .init(1, "18 dB/oct"),
        ], digits: 1)
        static let outLevel = DeepSettingValueType.intRange(0...100, digits: 3, unit: nil, step: 1)
        static let txBPFSel = DeepSettingValueType.enumeration(cases: [
            .init(0, "50-3050 Hz"), .init(1, "100-2900 Hz"), .init(2, "200-2800 Hz"), .init(3, "300-2700 Hz"), .init(4, "400-2600 Hz"),
        ], digits: 1)
        static let modSource = DeepSettingValueType.enumeration(cases: [
            .init(0, "MIC"), .init(1, "USB"), .init(2, "Bluetooth"), .init(3, "AUTO"),
        ], digits: 1)
        static let rpttSelect = DeepSettingValueType.enumeration(cases: [
            .init(0, "OFF"), .init(1, "RTS"), .init(2, "DTR"),
        ], digits: 1)

        /// 00: OFF, 01-19: 100 Hz-1000 Hz in 50 Hz steps.
        static let lcutFreqCases: [DeepSettingValueType.EnumerationCase] = {
            var cases: [DeepSettingValueType.EnumerationCase] = [.init(0, "OFF")]
            for index in 1...19 { cases.append(.init(index, "\(100 + (index - 1) * 50) Hz")) }
            return cases
        }()

        /// 00: OFF, 01-67: 700 Hz-4000 Hz in 50 Hz steps.
        static let hcutFreqCases: [DeepSettingValueType.EnumerationCase] = {
            var cases: [DeepSettingValueType.EnumerationCase] = [.init(0, "OFF")]
            for index in 1...67 { cases.append(.init(index, "\(700 + (index - 1) * 50) Hz")) }
            return cases
        }()

        /// MODE SSB's NAR WIDTH list — non-linear, hand-listed from the
        /// manual (distinct from MODE DATA/RTTY's list below).
        static let ssbNarWidthCases: [DeepSettingValueType.EnumerationCase] = [
            .init(0, "300 Hz"), .init(1, "400 Hz"), .init(2, "600 Hz"), .init(3, "850 Hz"), .init(4, "1100 Hz"),
            .init(5, "1200 Hz"), .init(6, "1500 Hz"), .init(7, "1650 Hz"), .init(8, "1800 Hz"), .init(9, "1950 Hz"),
            .init(10, "2100 Hz"), .init(11, "2250 Hz"), .init(12, "2400 Hz"), .init(13, "2450 Hz"), .init(14, "2500 Hz"),
            .init(15, "2600 Hz"), .init(16, "2700 Hz"), .init(17, "2800 Hz"), .init(18, "2900 Hz"), .init(19, "3000 Hz"),
            .init(20, "3200 Hz"), .init(21, "3500 Hz"), .init(22, "4000 Hz"),
        ]

        /// MODE DATA/RTTY's shared NAR WIDTH list — non-linear, distinct
        /// from MODE SSB's above.
        static let dataNarWidthCases: [DeepSettingValueType.EnumerationCase] = [
            .init(0, "50 Hz"), .init(1, "100 Hz"), .init(2, "150 Hz"), .init(3, "200 Hz"), .init(4, "250 Hz"),
            .init(5, "300 Hz"), .init(6, "350 Hz"), .init(7, "400 Hz"), .init(8, "450 Hz"), .init(9, "500 Hz"),
            .init(10, "600 Hz"), .init(11, "800 Hz"), .init(12, "1200 Hz"), .init(13, "1400 Hz"), .init(14, "1700 Hz"),
            .init(15, "2000 Hz"), .init(16, "2400 Hz"), .init(17, "3200 Hz"), .init(18, "3500 Hz"), .init(19, "4000 Hz"),
        ]

        static let cwAutoMode = DeepSettingValueType.enumeration(cases: [
            .init(0, "OFF"), .init(1, "50 MHz"), .init(2, "ON"),
        ], digits: 1)

        // MODE FM-only shared bits below.

        static let rptShift = DeepSettingValueType.enumeration(cases: [
            .init(0, "-"), .init(1, "SIMPLEX"), .init(2, "+"), .init(3, "ARS"),
        ], digits: 1)
        static let sqlType = DeepSettingValueType.enumeration(cases: [
            .init(0, "OFF"), .init(1, "ENC"), .init(2, "TSQ"), .init(3, "DCS"), .init(4, "PR FREQ"), .init(5, "REV TONE"),
        ], digits: 1)
        static let dcsRevers = DeepSettingValueType.enumeration(cases: [
            .init(0, "NORMAL"), .init(1, "REVERS"),
        ], digits: 1)
        static let dtmfDelay = DeepSettingValueType.enumeration(cases: [
            .init(0, "50 ms"), .init(1, "250 ms"), .init(2, "450 ms"), .init(3, "750 ms"), .init(4, "1000 ms"),
        ], digits: 1)
        static let dtmfSpeed = DeepSettingValueType.enumeration(cases: [
            .init(0, "50 ms"), .init(1, "100 ms"),
        ], digits: 1)

        /// The standard 50-tone CTCSS table (index 0 = 67.0 Hz, index 49 =
        /// 254.1 Hz, matching Table 3's "00: 67.0 - 49: 254.1Hz"). Well-
        /// known/industry-standard, not specific to this rig — still worth
        /// spot-checking a couple of index values against the real MENU
        /// display before trusting it fully.
        static let toneFreqCases: [DeepSettingValueType.EnumerationCase] = {
            let tones = [
                67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
                94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
                131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
                171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
                203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1,
            ]
            return tones.enumerated().map { .init($0.offset, "\($0.element) Hz") }
        }()

        /// The standard 104-code DCS table (index 0 = code 023, index 103 =
        /// code 754, matching Table 3's "00: 023 - 103: 754"). Same
        /// well-known-standard caveat as `toneFreqCases` above.
        static let dcsCodeCases: [DeepSettingValueType.EnumerationCase] = {
            let codes = [
                "023", "025", "026", "031", "032", "036", "043", "047", "051", "053",
                "054", "065", "071", "072", "073", "074", "114", "115", "116", "122",
                "125", "131", "132", "134", "143", "145", "152", "155", "156", "162",
                "165", "172", "174", "205", "212", "223", "225", "226", "243", "244",
                "245", "246", "251", "252", "255", "261", "263", "265", "266", "271",
                "274", "306", "311", "315", "325", "331", "332", "343", "346", "351",
                "356", "364", "365", "371", "411", "412", "413", "423", "431", "432",
                "445", "446", "452", "454", "455", "462", "464", "465", "466", "503",
                "506", "516", "523", "526", "532", "546", "565", "606", "612", "624",
                "627", "631", "632", "654", "662", "664", "703", "712", "723", "731",
                "732", "734", "743", "754",
            ]
            return codes.enumerated().map { .init($0.offset, $0.element) }
        }()
    }

    /// P1=01 (RADIO SETTING), transcribed from the CAT manual's Table 3,
    /// pages 10-11. Not yet hardware-verified. Two items whose CAT shape
    /// couldn't be pinned down precisely from the manual's own printed
    /// cell (see inline comments): RPT SHIFT(144MHz)/(430MHz)'s odd
    /// "0-100MHz" range text, likely meaning a 0-100 step count rather
    /// than literally 100MHz.
    private static let radioSettingItems: [DeepSettingItem] = [
        // 01.01 (MODE SSB)
        DeepSettingItem(p1: 1, p2: 1, p3: 1, category: "RADIO SETTING", tab: "MODE SSB", label: "AF TREBLE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 1, p3: 2, category: "RADIO SETTING", tab: "MODE SSB", label: "AF MIDDLE TONE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 1, p3: 3, category: "RADIO SETTING", tab: "MODE SSB", label: "AF BASS GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 1, p3: 4, category: "RADIO SETTING", tab: "MODE SSB", label: "AGC FAST DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 1, p3: 5, category: "RADIO SETTING", tab: "MODE SSB", label: "AGC MID DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 1, p3: 6, category: "RADIO SETTING", tab: "MODE SSB", label: "AGC SLOW DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 1, p3: 7, category: "RADIO SETTING", tab: "MODE SSB", label: "LCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.lcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 1, p3: 8, category: "RADIO SETTING", tab: "MODE SSB", label: "LCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 1, p3: 9, category: "RADIO SETTING", tab: "MODE SSB", label: "HCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.hcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 1, p3: 10, category: "RADIO SETTING", tab: "MODE SSB", label: "HCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 1, p3: 11, category: "RADIO SETTING", tab: "MODE SSB", label: "USB OUT LEVEL", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 1, p3: 12, category: "RADIO SETTING", tab: "MODE SSB", label: "TX BPF SEL", valueType: RadioSettingShared.txBPFSel),
        DeepSettingItem(p1: 1, p2: 1, p3: 13, category: "RADIO SETTING", tab: "MODE SSB", label: "MOD SOURCE", valueType: RadioSettingShared.modSource),
        DeepSettingItem(p1: 1, p2: 1, p3: 14, category: "RADIO SETTING", tab: "MODE SSB", label: "USB MOD GAIN", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 1, p3: 15, category: "RADIO SETTING", tab: "MODE SSB", label: "RPTT SELECT", valueType: RadioSettingShared.rpttSelect),
        DeepSettingItem(p1: 1, p2: 1, p3: 16, category: "RADIO SETTING", tab: "MODE SSB", label: "NAR WIDTH", valueType: .enumeration(cases: RadioSettingShared.ssbNarWidthCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 1, p3: 17, category: "RADIO SETTING", tab: "MODE SSB", label: "CW AUTO MODE", valueType: RadioSettingShared.cwAutoMode),

        // 01.02 (MODE AM) — same fields as MODE SSB minus NAR WIDTH/CW AUTO MODE
        DeepSettingItem(p1: 1, p2: 2, p3: 1, category: "RADIO SETTING", tab: "MODE AM", label: "AF TREBLE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 2, p3: 2, category: "RADIO SETTING", tab: "MODE AM", label: "AF MIDDLE TONE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 2, p3: 3, category: "RADIO SETTING", tab: "MODE AM", label: "AF BASS GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 2, p3: 4, category: "RADIO SETTING", tab: "MODE AM", label: "AGC FAST DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 2, p3: 5, category: "RADIO SETTING", tab: "MODE AM", label: "AGC MID DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 2, p3: 6, category: "RADIO SETTING", tab: "MODE AM", label: "AGC SLOW DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 2, p3: 7, category: "RADIO SETTING", tab: "MODE AM", label: "LCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.lcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 2, p3: 8, category: "RADIO SETTING", tab: "MODE AM", label: "LCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 2, p3: 9, category: "RADIO SETTING", tab: "MODE AM", label: "HCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.hcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 2, p3: 10, category: "RADIO SETTING", tab: "MODE AM", label: "HCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 2, p3: 11, category: "RADIO SETTING", tab: "MODE AM", label: "USB OUT LEVEL", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 2, p3: 12, category: "RADIO SETTING", tab: "MODE AM", label: "TX BPF SEL", valueType: RadioSettingShared.txBPFSel),
        DeepSettingItem(p1: 1, p2: 2, p3: 13, category: "RADIO SETTING", tab: "MODE AM", label: "MOD SOURCE", valueType: RadioSettingShared.modSource),
        DeepSettingItem(p1: 1, p2: 2, p3: 14, category: "RADIO SETTING", tab: "MODE AM", label: "USB MOD GAIN", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 2, p3: 15, category: "RADIO SETTING", tab: "MODE AM", label: "RPTT SELECT", valueType: RadioSettingShared.rpttSelect),

        // 01.03 (MODE FM) — no TX BPF SEL; adds repeater/DTMF/APRS-tone fields
        DeepSettingItem(p1: 1, p2: 3, p3: 1, category: "RADIO SETTING", tab: "MODE FM", label: "AF TREBLE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 3, p3: 2, category: "RADIO SETTING", tab: "MODE FM", label: "AF MIDDLE TONE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 3, p3: 3, category: "RADIO SETTING", tab: "MODE FM", label: "AF BASS GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 3, p3: 4, category: "RADIO SETTING", tab: "MODE FM", label: "AGC FAST DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 3, p3: 5, category: "RADIO SETTING", tab: "MODE FM", label: "AGC MID DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 3, p3: 6, category: "RADIO SETTING", tab: "MODE FM", label: "AGC SLOW DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 3, p3: 7, category: "RADIO SETTING", tab: "MODE FM", label: "LCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.lcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 3, p3: 8, category: "RADIO SETTING", tab: "MODE FM", label: "LCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 3, p3: 9, category: "RADIO SETTING", tab: "MODE FM", label: "HCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.hcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 3, p3: 10, category: "RADIO SETTING", tab: "MODE FM", label: "HCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 3, p3: 11, category: "RADIO SETTING", tab: "MODE FM", label: "USB OUT LEVEL", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 3, p3: 12, category: "RADIO SETTING", tab: "MODE FM", label: "MOD SOURCE", valueType: RadioSettingShared.modSource),
        DeepSettingItem(p1: 1, p2: 3, p3: 13, category: "RADIO SETTING", tab: "MODE FM", label: "USB MOD GAIN", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 3, p3: 14, category: "RADIO SETTING", tab: "MODE FM", label: "RPTT SELECT", valueType: RadioSettingShared.rpttSelect),
        DeepSettingItem(p1: 1, p2: 3, p3: 15, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT", valueType: RadioSettingShared.rptShift),
        DeepSettingItem(p1: 1, p2: 3, p3: 16, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT (28MHz)", valueType: .intRange(0...1000, digits: 4, unit: "kHz", step: 10)),
        DeepSettingItem(p1: 1, p2: 3, p3: 17, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT (50MHz)", valueType: .intRange(0...4000, digits: 4, unit: "kHz", step: 10)),
        // The manual's own cell reads "0-100MHz (P4=0000-0100, 50kHz/step)"
        // for both of these — 100MHz literally would be an absurd repeater
        // shift, so this is almost certainly a 0-100 step count (0-5MHz in
        // 50kHz steps), not a literal MHz range. Left as a raw step count
        // pending hardware confirmation of the real shift range.
        DeepSettingItem(p1: 1, p2: 3, p3: 18, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT (144MHz)", valueType: .intRange(0...100, digits: 4, unit: "× 50 kHz steps", step: 1)),
        DeepSettingItem(p1: 1, p2: 3, p3: 19, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT (430MHz)", valueType: .intRange(0...100, digits: 4, unit: "× 50 kHz steps", step: 1)),
        DeepSettingItem(p1: 1, p2: 3, p3: 20, category: "RADIO SETTING", tab: "MODE FM", label: "SQL TYPE", valueType: RadioSettingShared.sqlType),
        DeepSettingItem(p1: 1, p2: 3, p3: 21, category: "RADIO SETTING", tab: "MODE FM", label: "TONE FREQ", valueType: .enumeration(cases: RadioSettingShared.toneFreqCases, digits: 2)),
        // Manual prints Digits=2 here, but 104 entries (index 000-103) need
        // 3 — same category of manual digit-count error as DISPLAY
        // SETTING's AUTO POWER OFF, caught by testDigitsAreWideEnoughForDeclaredRange.
        DeepSettingItem(p1: 1, p2: 3, p3: 22, category: "RADIO SETTING", tab: "MODE FM", label: "DCS CODE", valueType: .enumeration(cases: RadioSettingShared.dcsCodeCases, digits: 3)),
        DeepSettingItem(p1: 1, p2: 3, p3: 23, category: "RADIO SETTING", tab: "MODE FM", label: "DCS RX REVERS", valueType: RadioSettingShared.dcsRevers),
        DeepSettingItem(p1: 1, p2: 3, p3: 24, category: "RADIO SETTING", tab: "MODE FM", label: "DCS TX REVERS", valueType: RadioSettingShared.dcsRevers),
        DeepSettingItem(p1: 1, p2: 3, p3: 25, category: "RADIO SETTING", tab: "MODE FM", label: "PR FREQ", valueType: .intRange(300...3000, digits: 4, unit: "Hz", step: 100)),
        DeepSettingItem(p1: 1, p2: 3, p3: 26, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF DELAY", valueType: RadioSettingShared.dtmfDelay),
        DeepSettingItem(p1: 1, p2: 3, p3: 27, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF SPEED", valueType: RadioSettingShared.dtmfSpeed),
        DeepSettingItem(p1: 1, p2: 3, p3: 28, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 1", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 29, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 2", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 30, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 3", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 31, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 4", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 32, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 5", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 33, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 6", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 34, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 7", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 35, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 8", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 36, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 9", valueType: .text(maxLength: 16)),
        DeepSettingItem(p1: 1, p2: 3, p3: 37, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 10", valueType: .text(maxLength: 16)),

        // 01.04 (MODE DATA) — has TX BPF SEL (like SSB/AM); adds PSK TONE/DATA SHIFT
        DeepSettingItem(p1: 1, p2: 4, p3: 1, category: "RADIO SETTING", tab: "MODE DATA", label: "AF TREBLE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 4, p3: 2, category: "RADIO SETTING", tab: "MODE DATA", label: "AF MIDDLE TONE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 4, p3: 3, category: "RADIO SETTING", tab: "MODE DATA", label: "AF BASS GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 4, p3: 4, category: "RADIO SETTING", tab: "MODE DATA", label: "AGC FAST DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 4, p3: 5, category: "RADIO SETTING", tab: "MODE DATA", label: "AGC MID DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 4, p3: 6, category: "RADIO SETTING", tab: "MODE DATA", label: "AGC SLOW DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 4, p3: 7, category: "RADIO SETTING", tab: "MODE DATA", label: "LCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.lcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 4, p3: 8, category: "RADIO SETTING", tab: "MODE DATA", label: "LCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 4, p3: 9, category: "RADIO SETTING", tab: "MODE DATA", label: "HCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.hcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 4, p3: 10, category: "RADIO SETTING", tab: "MODE DATA", label: "HCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 4, p3: 11, category: "RADIO SETTING", tab: "MODE DATA", label: "USB OUT LEVEL", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 4, p3: 12, category: "RADIO SETTING", tab: "MODE DATA", label: "TX BPF SEL", valueType: RadioSettingShared.txBPFSel),
        DeepSettingItem(p1: 1, p2: 4, p3: 13, category: "RADIO SETTING", tab: "MODE DATA", label: "MOD SOURCE", valueType: RadioSettingShared.modSource),
        DeepSettingItem(p1: 1, p2: 4, p3: 14, category: "RADIO SETTING", tab: "MODE DATA", label: "USB MOD GAIN", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 4, p3: 15, category: "RADIO SETTING", tab: "MODE DATA", label: "RPTT SELECT", valueType: RadioSettingShared.rpttSelect),
        DeepSettingItem(p1: 1, p2: 4, p3: 16, category: "RADIO SETTING", tab: "MODE DATA", label: "NAR WIDTH", valueType: .enumeration(cases: RadioSettingShared.dataNarWidthCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 4, p3: 17, category: "RADIO SETTING", tab: "MODE DATA", label: "PSK TONE", valueType: .enumeration(cases: [
            .init(0, "1000 Hz"), .init(1, "1500 Hz"),
        ], digits: 1)),
        DeepSettingItem(p1: 1, p2: 4, p3: 18, category: "RADIO SETTING", tab: "MODE DATA", label: "DATA SHIFT (SSB)", valueType: .intRange(0...3000, digits: 4, unit: "Hz", step: 10)),

        // 01.05 (MODE RTTY) — no TX BPF SEL/MOD SOURCE/USB MOD GAIN
        DeepSettingItem(p1: 1, p2: 5, p3: 1, category: "RADIO SETTING", tab: "MODE RTTY", label: "AF TREBLE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 5, p3: 2, category: "RADIO SETTING", tab: "MODE RTTY", label: "AF MIDDLE TONE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 5, p3: 3, category: "RADIO SETTING", tab: "MODE RTTY", label: "AF BASS GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 1, p2: 5, p3: 4, category: "RADIO SETTING", tab: "MODE RTTY", label: "AGC FAST DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 5, p3: 5, category: "RADIO SETTING", tab: "MODE RTTY", label: "AGC MID DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 5, p3: 6, category: "RADIO SETTING", tab: "MODE RTTY", label: "AGC SLOW DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 1, p2: 5, p3: 7, category: "RADIO SETTING", tab: "MODE RTTY", label: "LCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.lcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 5, p3: 8, category: "RADIO SETTING", tab: "MODE RTTY", label: "LCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 5, p3: 9, category: "RADIO SETTING", tab: "MODE RTTY", label: "HCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.hcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 5, p3: 10, category: "RADIO SETTING", tab: "MODE RTTY", label: "HCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 1, p2: 5, p3: 11, category: "RADIO SETTING", tab: "MODE RTTY", label: "USB OUT LEVEL", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 1, p2: 5, p3: 12, category: "RADIO SETTING", tab: "MODE RTTY", label: "RPTT SELECT", valueType: RadioSettingShared.rpttSelect),
        DeepSettingItem(p1: 1, p2: 5, p3: 13, category: "RADIO SETTING", tab: "MODE RTTY", label: "NAR WIDTH", valueType: .enumeration(cases: RadioSettingShared.dataNarWidthCases, digits: 2)),
        DeepSettingItem(p1: 1, p2: 5, p3: 14, category: "RADIO SETTING", tab: "MODE RTTY", label: "MARK FREQUENCY", valueType: .enumeration(cases: [
            .init(0, "1275 Hz"), .init(1, "2125 Hz"),
        ], digits: 1)),
        DeepSettingItem(p1: 1, p2: 5, p3: 15, category: "RADIO SETTING", tab: "MODE RTTY", label: "SHIFT FREQUENCY", valueType: .enumeration(cases: [
            .init(0, "170 Hz"), .init(1, "200 Hz"), .init(2, "425 Hz"), .init(3, "850 Hz"),
        ], digits: 1)),
        DeepSettingItem(p1: 1, p2: 5, p3: 16, category: "RADIO SETTING", tab: "MODE RTTY", label: "POLARITY-TX", valueType: .enumeration(cases: [
            .init(0, "NOR"), .init(1, "REV"),
        ], digits: 1)),

        // 01.06 (DIGITAL)
        DeepSettingItem(p1: 1, p2: 6, p3: 1, category: "RADIO SETTING", tab: "DIGITAL", label: "DIGITAL POPUP", valueType: .enumeration(cases: {
            var cases: [DeepSettingValueType.EnumerationCase] = [.init(0, "OFF")]
            for index in 1...59 { cases.append(.init(index, "\(index + 1) sec")) }
            cases.append(.init(60, "CONTINUE"))
            return cases
        }(), digits: 2)),
        DeepSettingItem(p1: 1, p2: 6, p3: 2, category: "RADIO SETTING", tab: "DIGITAL", label: "LOCATION SERVICE", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 1, p2: 6, p3: 3, category: "RADIO SETTING", tab: "DIGITAL", label: "STANDBY BEEP", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 1, p2: 6, p3: 4, category: "RADIO SETTING", tab: "DIGITAL", label: "DP-ID LIST", valueType: .readOnly),
        DeepSettingItem(p1: 1, p2: 6, p3: 5, category: "RADIO SETTING", tab: "DIGITAL", label: "RADIO ID", valueType: .readOnly),
    ]

    /// CW SETTING-only reused value type — the five CW MEMORY items on the
    /// KEYER tab all share this shape.
    private enum CWSettingShared {
        static let memoryType = DeepSettingValueType.enumeration(cases: [
            .init(0, "TEXT"), .init(1, "MESSAGE"),
        ], digits: 1)
    }

    /// P1=02 (CW SETTING), transcribed from the CAT manual's Table 3, page
    /// 11. Not yet hardware-verified. Reuses several `RadioSettingShared`
    /// value types where MODE CW's fields are identical to RADIO SETTING's
    /// mode tabs (AF gains, AGC delays, cut filters, USB OUT LEVEL, RPTT
    /// SELECT, and MODE CW's NAR WIDTH list, which matches MODE DATA/RTTY's
    /// rather than MODE SSB's).
    private static let cwSettingItems: [DeepSettingItem] = [
        // 02.01 (MODE CW)
        DeepSettingItem(p1: 2, p2: 1, p3: 1, category: "CW SETTING", tab: "MODE CW", label: "AF TREBLE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 2, p2: 1, p3: 2, category: "CW SETTING", tab: "MODE CW", label: "AF MIDDLE TONE GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 2, p2: 1, p3: 3, category: "CW SETTING", tab: "MODE CW", label: "AF BASS GAIN", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 2, p2: 1, p3: 4, category: "CW SETTING", tab: "MODE CW", label: "AGC FAST DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 2, p2: 1, p3: 5, category: "CW SETTING", tab: "MODE CW", label: "AGC MID DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 2, p2: 1, p3: 6, category: "CW SETTING", tab: "MODE CW", label: "AGC SLOW DELAY", valueType: RadioSettingShared.agcDelay),
        DeepSettingItem(p1: 2, p2: 1, p3: 7, category: "CW SETTING", tab: "MODE CW", label: "LCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.lcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 2, p2: 1, p3: 8, category: "CW SETTING", tab: "MODE CW", label: "LCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 2, p2: 1, p3: 9, category: "CW SETTING", tab: "MODE CW", label: "HCUT FREQ", valueType: .enumeration(cases: RadioSettingShared.hcutFreqCases, digits: 2)),
        DeepSettingItem(p1: 2, p2: 1, p3: 10, category: "CW SETTING", tab: "MODE CW", label: "HCUT SLOPE", valueType: RadioSettingShared.cutSlope),
        DeepSettingItem(p1: 2, p2: 1, p3: 11, category: "CW SETTING", tab: "MODE CW", label: "USB OUT LEVEL", valueType: RadioSettingShared.outLevel),
        DeepSettingItem(p1: 2, p2: 1, p3: 12, category: "CW SETTING", tab: "MODE CW", label: "RPTT SELECT", valueType: RadioSettingShared.rpttSelect),
        DeepSettingItem(p1: 2, p2: 1, p3: 13, category: "CW SETTING", tab: "MODE CW", label: "NAR WIDTH", valueType: .enumeration(cases: RadioSettingShared.dataNarWidthCases, digits: 2)),
        DeepSettingItem(p1: 2, p2: 1, p3: 14, category: "CW SETTING", tab: "MODE CW", label: "PC KEYING", valueType: RadioSettingShared.rpttSelect),
        DeepSettingItem(p1: 2, p2: 1, p3: 15, category: "CW SETTING", tab: "MODE CW", label: "CW BK-IN TYPE", valueType: .enumeration(cases: [
            .init(0, "SEMI"), .init(1, "FULL"),
        ], digits: 1)),
        DeepSettingItem(p1: 2, p2: 1, p3: 16, category: "CW SETTING", tab: "MODE CW", label: "CW FREQ DISPLAY", valueType: .enumeration(cases: [
            .init(0, "DIRECT FREQ"), .init(1, "PITCH OFFSET"),
        ], digits: 1)),
        DeepSettingItem(p1: 2, p2: 1, p3: 17, category: "CW SETTING", tab: "MODE CW", label: "QSK DELAY TIME", valueType: .enumeration(cases: [
            .init(0, "15 msec"), .init(1, "20 msec"), .init(2, "25 msec"), .init(3, "30 msec"),
        ], digits: 1)),
        DeepSettingItem(p1: 2, p2: 1, p3: 18, category: "CW SETTING", tab: "MODE CW", label: "CW INDICATOR", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),

        // 02.02 (KEYER)
        DeepSettingItem(p1: 2, p2: 2, p3: 1, category: "CW SETTING", tab: "KEYER", label: "KEYER TYPE", valueType: .enumeration(cases: [
            .init(0, "OFF"), .init(1, "BUG"), .init(2, "ELEKEY-A"), .init(3, "ELEKEY-B"), .init(4, "ELEKEY-Y"), .init(5, "ACS"),
        ], digits: 1)),
        DeepSettingItem(p1: 2, p2: 2, p3: 2, category: "CW SETTING", tab: "KEYER", label: "KEYER DOT/DASH", valueType: .enumeration(cases: [
            .init(0, "NOR"), .init(1, "REV"),
        ], digits: 1)),
        // The manual's cell claims raw P4 is the weight ×10 (25-45 for
        // 2.5-4.5) — confirmed wrong against real hardware: a live "EX
        // 02.02.03" probe returned raw "05" while the rig's own physical
        // MENU display read 3.0, which only fits a 0-based offset (00 =
        // 2.5, 20 = 4.5, 0.1/step), not the manual's literal ×10 encoding.
        // Same class of manual/hardware mismatch as AUTO POWER OFF/DCS
        // CODE's digit-count errors, but this one's the *value mapping*
        // itself, not just the digit width.
        DeepSettingItem(p1: 2, p2: 2, p3: 3, category: "CW SETTING", tab: "KEYER", label: "CW WEIGHT", valueType: .enumeration(cases: (0...20).map {
            .init($0, String(format: "%.1f", 2.5 + Double($0) / 10))
        }, digits: 2)),
        DeepSettingItem(p1: 2, p2: 2, p3: 4, category: "CW SETTING", tab: "KEYER", label: "NUMBER STYLE", valueType: .enumeration(cases: [
            .init(0, "1290"), .init(1, "AUNO"), .init(2, "AUNT"), .init(3, "A2NO"), .init(4, "A2NT"), .init(5, "12NO"), .init(6, "12NT"),
        ], digits: 1)),
        DeepSettingItem(p1: 2, p2: 2, p3: 5, category: "CW SETTING", tab: "KEYER", label: "CONTEST NUMBER", valueType: .intRange(1...9999, digits: 4, unit: nil, step: 1)),
        DeepSettingItem(p1: 2, p2: 2, p3: 6, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 1", valueType: CWSettingShared.memoryType),
        DeepSettingItem(p1: 2, p2: 2, p3: 7, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 2", valueType: CWSettingShared.memoryType),
        DeepSettingItem(p1: 2, p2: 2, p3: 8, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 3", valueType: CWSettingShared.memoryType),
        DeepSettingItem(p1: 2, p2: 2, p3: 9, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 4", valueType: CWSettingShared.memoryType),
        DeepSettingItem(p1: 2, p2: 2, p3: 10, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 5", valueType: CWSettingShared.memoryType),
        DeepSettingItem(p1: 2, p2: 2, p3: 11, category: "CW SETTING", tab: "KEYER", label: "REPEAT INTERVAL", valueType: .intRange(1...60, digits: 2, unit: "sec", step: 1)),
    ]

    /// P1=03 (OPERATION SETTING)-only reused value types.
    private enum OperationSettingShared {
        static let catRate = DeepSettingValueType.enumeration(cases: [
            .init(0, "4800 bps"), .init(1, "9600 bps"), .init(2, "19200 bps"), .init(3, "38400 bps"), .init(4, "115200 bps"),
        ], digits: 1)
        static let catTimeout = DeepSettingValueType.enumeration(cases: [
            .init(0, "10 msec"), .init(1, "100 msec"), .init(2, "1000 msec"), .init(3, "3000 msec"),
        ], digits: 1)
        static let prmtrcBwth = DeepSettingValueType.intRange(0...10, digits: 2, unit: nil, step: 1)

        /// 00: OFF, 01-07: 100 Hz-700 Hz in 100 Hz steps.
        static let prmtrcFreq1Cases: [DeepSettingValueType.EnumerationCase] = {
            var cases: [DeepSettingValueType.EnumerationCase] = [.init(0, "OFF")]
            for index in 1...7 { cases.append(.init(index, "\(index * 100) Hz")) }
            return cases
        }()
        /// 00: OFF, 01-09: 700 Hz-1500 Hz in 100 Hz steps.
        static let prmtrcFreq2Cases: [DeepSettingValueType.EnumerationCase] = {
            var cases: [DeepSettingValueType.EnumerationCase] = [.init(0, "OFF")]
            for index in 1...9 { cases.append(.init(index, "\(700 + (index - 1) * 100) Hz")) }
            return cases
        }()
        /// 00: OFF, 01-18: 1500 Hz-3200 Hz in 100 Hz steps.
        static let prmtrcFreq3Cases: [DeepSettingValueType.EnumerationCase] = {
            var cases: [DeepSettingValueType.EnumerationCase] = [.init(0, "OFF")]
            for index in 1...18 { cases.append(.init(index, "\(1500 + (index - 1) * 100) Hz")) }
            return cases
        }()

        /// MIC P1-P4's shared 21-option programmable-button assignment list.
        static let micAssignCases = DeepSettingValueType.enumeration(cases: [
            .init(0, "LOCK"), .init(1, "QMB"), .init(2, ">/<"), .init(3, "V/M"), .init(4, "TUNER"),
            .init(5, "VOX/MOX"), .init(6, "MODE"), .init(7, "ZIN/SPOT"), .init(8, "SPLIT"), .init(9, "FINE"),
            .init(10, "NAR"), .init(11, "NB"), .init(12, "DNR"), .init(13, "FREQ UP"), .init(14, "FREQ DOWN"),
            .init(15, "BAND UP"), .init(16, "BAND DOWN"), .init(17, "ATT"), .init(18, "IPO"), .init(19, "DNF"),
            .init(20, "AGC"),
        ], digits: 2)

        static let dialStep5_10_20 = DeepSettingValueType.enumeration(cases: [
            .init(0, "5 Hz"), .init(1, "10 Hz"), .init(2, "20 Hz"),
        ], digits: 1)
    }

    /// P1=03 (OPERATION SETTING), transcribed from the CAT manual's Table
    /// 3, pages 12-13. Not yet hardware-verified except where noted below.
    ///
    /// TX GENERAL's HF MAX POWER was printed as "005-010" — read instead
    /// as "005-100" (matching every other MAX POWER field here and
    /// OPTION's own HF MAX POWER) since 10W looked like a misprint;
    /// **user confirmed 100W is correct** against real hardware.
    ///
    /// KEY/DIAL's MIC UP/MIC DOWN are left as `.readOnly` placeholders —
    /// their P4 column was blank in the printed table, unlike MIC P1-P4's
    /// shared 21-option list right above them, so their real shape (if
    /// any) is unknown. **Deliberately deferred, not urgent** — revisit
    /// later rather than guess.
    private static let operationSettingItems: [DeepSettingItem] = [
        // 03.01 (GENERAL)
        DeepSettingItem(p1: 3, p2: 1, p3: 1, category: "OPERATION SETTING", tab: "GENERAL", label: "BEEP LEVEL", valueType: .intRange(0...100, digits: 3, unit: nil, step: 1)),
        DeepSettingItem(p1: 3, p2: 1, p3: 2, category: "OPERATION SETTING", tab: "GENERAL", label: "RF/SQL VR", valueType: .enumeration(cases: [
            .init(0, "RF"), .init(1, "SQL"), .init(2, "SQL (FM mode only)"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 1, p3: 3, category: "OPERATION SETTING", tab: "GENERAL", label: "TUN/LIN PORT SELECT", valueType: .enumeration(cases: [
            .init(0, "EXT-TUNER"), .init(1, "LINEAR"), .init(2, "CAT-3"), .init(3, "GPO"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 1, p3: 4, category: "OPERATION SETTING", tab: "GENERAL", label: "TUNER SELECT", valueType: .enumeration(cases: [
            .init(0, "INT"), .init(1, "INT (FAST)"), .init(2, "EXT"), .init(3, "ATAS"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 1, p3: 5, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-1 RATE", valueType: OperationSettingShared.catRate),
        DeepSettingItem(p1: 3, p2: 1, p3: 6, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-1 TIME OUT TIMER", valueType: OperationSettingShared.catTimeout),
        DeepSettingItem(p1: 3, p2: 1, p3: 7, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-1/CAT-3 STOP BIT", valueType: .enumeration(cases: [
            .init(0, "1 bit"), .init(1, "2 bit"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 1, p3: 8, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-2 RATE", valueType: OperationSettingShared.catRate),
        DeepSettingItem(p1: 3, p2: 1, p3: 9, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-2 TIME OUT TIMER", valueType: OperationSettingShared.catTimeout),
        DeepSettingItem(p1: 3, p2: 1, p3: 10, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-3 RATE", valueType: OperationSettingShared.catRate),
        DeepSettingItem(p1: 3, p2: 1, p3: 11, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-3 TIME OUT TIMER", valueType: OperationSettingShared.catTimeout),
        DeepSettingItem(p1: 3, p2: 1, p3: 12, category: "OPERATION SETTING", tab: "GENERAL", label: "TX TIME OUT TIMER", valueType: .enumeration(cases: {
            var cases: [DeepSettingValueType.EnumerationCase] = [.init(0, "OFF")]
            for index in 1...30 { cases.append(.init(index, "\(index) min")) }
            return cases
        }(), digits: 2)),
        DeepSettingItem(p1: 3, p2: 1, p3: 13, category: "OPERATION SETTING", tab: "GENERAL", label: "REF FREQ ADJ", valueType: .signedRange(-25...25, digits: 2, unit: nil, step: 1)),
        DeepSettingItem(p1: 3, p2: 1, p3: 14, category: "OPERATION SETTING", tab: "GENERAL", label: "CHARGE CONTROL", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 3, p2: 1, p3: 15, category: "OPERATION SETTING", tab: "GENERAL", label: "SUB BAND MUTE", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 3, p2: 1, p3: 16, category: "OPERATION SETTING", tab: "GENERAL", label: "SPEAKER SELECT", valueType: .enumeration(cases: [
            .init(0, "Auto"), .init(1, "INT"), .init(2, "BOTH"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 1, p3: 17, category: "OPERATION SETTING", tab: "GENERAL", label: "DITHER", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),

        // 03.02 (BAND-SCAN)
        DeepSettingItem(p1: 3, p2: 2, p3: 1, category: "OPERATION SETTING", tab: "BAND-SCAN", label: "QMB CH", valueType: .enumeration(cases: [
            .init(0, "5ch"), .init(1, "10ch"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 2, p3: 2, category: "OPERATION SETTING", tab: "BAND-SCAN", label: "BAND STACK", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 3, p2: 2, p3: 3, category: "OPERATION SETTING", tab: "BAND-SCAN", label: "BAND EDGE", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 3, p2: 2, p3: 4, category: "OPERATION SETTING", tab: "BAND-SCAN", label: "SCAN RESUME", valueType: .enumeration(cases: [
            .init(0, "BUSY"), .init(1, "HOLD"), .init(2, "1 sec"), .init(3, "3 sec"), .init(4, "5 sec"),
        ], digits: 1)),

        // 03.03 (RX-DSP)
        DeepSettingItem(p1: 3, p2: 3, p3: 1, category: "OPERATION SETTING", tab: "RX-DSP", label: "IF NOTCH WIDTH", valueType: .enumeration(cases: [
            .init(0, "NARROW"), .init(1, "WIDE"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 3, p3: 2, category: "OPERATION SETTING", tab: "RX-DSP", label: "NB REJECTION", valueType: .enumeration(cases: [
            .init(0, "LOW"), .init(1, "MID"), .init(2, "HIGH"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 3, p3: 3, category: "OPERATION SETTING", tab: "RX-DSP", label: "NB WIDTH", valueType: .enumeration(cases: [
            .init(0, "NARROW"), .init(1, "MEDIUM"), .init(2, "WIDE"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 3, p3: 4, category: "OPERATION SETTING", tab: "RX-DSP", label: "APF WIDTH", valueType: .enumeration(cases: [
            .init(0, "NARROW"), .init(1, "MEDIUM"), .init(2, "WIDE"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 3, p3: 5, category: "OPERATION SETTING", tab: "RX-DSP", label: "CONTOUR LEVEL", valueType: .signedRange(-40...20, digits: 2, unit: nil, step: 1)),
        DeepSettingItem(p1: 3, p2: 3, p3: 6, category: "OPERATION SETTING", tab: "RX-DSP", label: "CONTOUR WIDTH", valueType: .intRange(1...11, digits: 2, unit: nil, step: 1)),

        // 03.04 (TX AUDIO)
        DeepSettingItem(p1: 3, p2: 4, p3: 1, category: "OPERATION SETTING", tab: "TX AUDIO", label: "AMC RELEASE TIME", valueType: .enumeration(cases: [
            .init(0, "FAST"), .init(1, "MID"), .init(2, "SLOW"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 4, p3: 2, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ1 FREQ", valueType: .enumeration(cases: OperationSettingShared.prmtrcFreq1Cases, digits: 2)),
        DeepSettingItem(p1: 3, p2: 4, p3: 3, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ1 LEVEL", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 3, p2: 4, p3: 4, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ1 BWTH", valueType: OperationSettingShared.prmtrcBwth),
        DeepSettingItem(p1: 3, p2: 4, p3: 5, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ2 FREQ", valueType: .enumeration(cases: OperationSettingShared.prmtrcFreq2Cases, digits: 2)),
        DeepSettingItem(p1: 3, p2: 4, p3: 6, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ2 LEVEL", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 3, p2: 4, p3: 7, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ2 BWTH", valueType: OperationSettingShared.prmtrcBwth),
        DeepSettingItem(p1: 3, p2: 4, p3: 8, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ3 FREQ", valueType: .enumeration(cases: OperationSettingShared.prmtrcFreq3Cases, digits: 2)),
        DeepSettingItem(p1: 3, p2: 4, p3: 9, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ3 LEVEL", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 3, p2: 4, p3: 10, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ3 BWTH", valueType: OperationSettingShared.prmtrcBwth),
        DeepSettingItem(p1: 3, p2: 4, p3: 11, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ1 FREQ", valueType: .enumeration(cases: OperationSettingShared.prmtrcFreq1Cases, digits: 2)),
        DeepSettingItem(p1: 3, p2: 4, p3: 12, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ1 LEVEL", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 3, p2: 4, p3: 13, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ1 BWTH", valueType: OperationSettingShared.prmtrcBwth),
        DeepSettingItem(p1: 3, p2: 4, p3: 14, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ2 FREQ", valueType: .enumeration(cases: OperationSettingShared.prmtrcFreq2Cases, digits: 2)),
        DeepSettingItem(p1: 3, p2: 4, p3: 15, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ2 LEVEL", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 3, p2: 4, p3: 16, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ2 BWTH", valueType: OperationSettingShared.prmtrcBwth),
        DeepSettingItem(p1: 3, p2: 4, p3: 17, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ3 FREQ", valueType: .enumeration(cases: OperationSettingShared.prmtrcFreq3Cases, digits: 2)),
        DeepSettingItem(p1: 3, p2: 4, p3: 18, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ3 LEVEL", valueType: RadioSettingShared.signedGain),
        DeepSettingItem(p1: 3, p2: 4, p3: 19, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ3 BWTH", valueType: OperationSettingShared.prmtrcBwth),

        // 03.05 (TX GENERAL)
        DeepSettingItem(p1: 3, p2: 5, p3: 1, category: "OPERATION SETTING", tab: "TX GENERAL", label: "MAX POWER (BAT)", valueType: .intRange(5...60, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 2, category: "OPERATION SETTING", tab: "TX GENERAL", label: "QRP MODE", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        // Printed as "005-010" — almost certainly a misread/misprint of
        // "005-100" (every other MAX POWER field here, and OPTION's own
        // HF MAX POWER below, go to 100/50, not 10). Using 100 pending a
        // hardware check specifically on this field's real upper bound.
        DeepSettingItem(p1: 3, p2: 5, p3: 3, category: "OPERATION SETTING", tab: "TX GENERAL", label: "HF MAX POWER", valueType: .intRange(5...100, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 4, category: "OPERATION SETTING", tab: "TX GENERAL", label: "50M MAX POWER", valueType: .intRange(5...60, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 5, category: "OPERATION SETTING", tab: "TX GENERAL", label: "70M MAX POWER", valueType: .intRange(5...60, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 6, category: "OPERATION SETTING", tab: "TX GENERAL", label: "144M MAX POWER", valueType: .intRange(5...100, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 7, category: "OPERATION SETTING", tab: "TX GENERAL", label: "430M MAX POWER", valueType: .intRange(5...100, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 8, category: "OPERATION SETTING", tab: "TX GENERAL", label: "AM HF/50 MAX POWER", valueType: .intRange(5...25, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 9, category: "OPERATION SETTING", tab: "TX GENERAL", label: "AM V/U MAX POWER", valueType: .intRange(5...25, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 10, category: "OPERATION SETTING", tab: "TX GENERAL", label: "VOX SELECT", valueType: .enumeration(cases: [
            .init(0, "MIC"), .init(1, "USB"), .init(2, "Bluetooth"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 5, p3: 11, category: "OPERATION SETTING", tab: "TX GENERAL", label: "EMERGENCY FREQ TX", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 3, p2: 5, p3: 12, category: "OPERATION SETTING", tab: "TX GENERAL", label: "TX INHIBIT", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 3, p2: 5, p3: 13, category: "OPERATION SETTING", tab: "TX GENERAL", label: "METER DETECTOR", valueType: .enumeration(cases: [
            .init(0, "AVERAGE"), .init(1, "PEAK"),
        ], digits: 1)),

        // 03.06 (KEY/DIAL)
        DeepSettingItem(p1: 3, p2: 6, p3: 1, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "SSB/CW DIAL STEP", valueType: OperationSettingShared.dialStep5_10_20),
        DeepSettingItem(p1: 3, p2: 6, p3: 2, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "RTTY/PSK DIAL STEP", valueType: OperationSettingShared.dialStep5_10_20),
        DeepSettingItem(p1: 3, p2: 6, p3: 3, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "FM DIAL STEP", valueType: .enumeration(cases: [
            .init(0, "5 kHz"), .init(1, "6.25 kHz"), .init(2, "10 kHz"), .init(3, "12.5 kHz"), .init(4, "20 kHz"), .init(5, "25 kHz"), .init(6, "Auto"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 6, p3: 4, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "CH STEP", valueType: .enumeration(cases: [
            .init(0, "1 kHz"), .init(1, "1.25 kHz"), .init(2, "2.5 kHz"), .init(3, "10 kHz"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 6, p3: 5, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "AM CH STEP", valueType: .enumeration(cases: [
            .init(0, "2.5 kHz"), .init(1, "5 kHz"), .init(2, "9 kHz"), .init(3, "10 kHz"), .init(4, "12.5 kHz"), .init(5, "25 kHz"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 6, p3: 6, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "FM CH STEP", valueType: .enumeration(cases: [
            .init(0, "5 kHz"), .init(1, "6.25 kHz"), .init(2, "10 kHz"), .init(3, "12.5 kHz"), .init(4, "20 kHz"), .init(5, "25 kHz"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 6, p3: 7, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MAIN STEPS PER REV.", valueType: .enumeration(cases: [
            .init(0, "50"), .init(1, "100"), .init(2, "200"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 6, p3: 8, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC P1", valueType: OperationSettingShared.micAssignCases),
        DeepSettingItem(p1: 3, p2: 6, p3: 9, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC P2", valueType: OperationSettingShared.micAssignCases),
        DeepSettingItem(p1: 3, p2: 6, p3: 10, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC P3", valueType: OperationSettingShared.micAssignCases),
        DeepSettingItem(p1: 3, p2: 6, p3: 11, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC P4", valueType: OperationSettingShared.micAssignCases),
        DeepSettingItem(p1: 3, p2: 6, p3: 12, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC UP", valueType: .readOnly),
        DeepSettingItem(p1: 3, p2: 6, p3: 13, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC DOWN", valueType: .readOnly),
        DeepSettingItem(p1: 3, p2: 6, p3: 14, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC SCAN", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),

        // 03.07 (OPTION)
        DeepSettingItem(p1: 3, p2: 7, p3: 1, category: "OPERATION SETTING", tab: "OPTION", label: "TUNER TYPE SEL ANT1", valueType: .enumeration(cases: [
            .init(0, "INT"), .init(1, "INT (FAST)"), .init(2, "EXT"), .init(3, "ATAS"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 2, category: "OPERATION SETTING", tab: "OPTION", label: "TUNER TYPE SEL ANT2", valueType: .enumeration(cases: [
            .init(0, "INT"), .init(1, "INT (FAST)"), .init(2, "EXT"), .init(3, "ATAS"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 3, category: "OPERATION SETTING", tab: "OPTION", label: "ANT2 OPERATION", valueType: .enumeration(cases: [
            .init(0, "TRX"), .init(1, "TX-ANT1, RX-ANT2"), .init(2, "TRX-ANT1, RX-ANT2"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 4, category: "OPERATION SETTING", tab: "OPTION", label: "HF ANT SELECT", valueType: .enumeration(cases: [
            .init(0, "ANT1"), .init(1, "ANT2"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 5, category: "OPERATION SETTING", tab: "OPTION", label: "HF MAX POWER", valueType: .intRange(5...100, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 6, category: "OPERATION SETTING", tab: "OPTION", label: "50M MAX POWER", valueType: .intRange(5...100, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 7, category: "OPERATION SETTING", tab: "OPTION", label: "70M MAX POWER", valueType: .intRange(5...50, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 8, category: "OPERATION SETTING", tab: "OPTION", label: "144M MAX POWER", valueType: .intRange(5...50, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 9, category: "OPERATION SETTING", tab: "OPTION", label: "430M MAX POWER", valueType: .intRange(5...50, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 10, category: "OPERATION SETTING", tab: "OPTION", label: "AM MAX POWER", valueType: .intRange(5...25, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 11, category: "OPERATION SETTING", tab: "OPTION", label: "AM V/U MAX POWER", valueType: .intRange(5...13, digits: 3, unit: "W", step: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 12, category: "OPERATION SETTING", tab: "OPTION", label: "GPS", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 3, p2: 7, p3: 13, category: "OPERATION SETTING", tab: "OPTION", label: "GPS PINNING", valueType: .toggle(offLabel: "OFF", onLabel: "ON")),
        DeepSettingItem(p1: 3, p2: 7, p3: 14, category: "OPERATION SETTING", tab: "OPTION", label: "GPS BAUDRATE", valueType: .enumeration(cases: [
            .init(0, "4800 bps"), .init(1, "9600 bps"), .init(2, "19200 bps"), .init(3, "38400 bps"), .init(4, "115200 bps"),
        ], digits: 1)),
        DeepSettingItem(p1: 3, p2: 7, p3: 15, category: "OPERATION SETTING", tab: "OPTION", label: "BLUETOOTH", valueType: .readOnly),
    ]

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

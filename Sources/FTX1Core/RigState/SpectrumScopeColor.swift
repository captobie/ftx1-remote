import Foundation

/// The FTX-1's scope color scheme (MENU D-COLOR), "SS"'s COLOR sub-function
/// (P2=3). The app keeps it as a 0-based index, 0-10 = COLOR-1…COLOR-11;
/// on the wire P3 is a single character, "0"-"9" then "A" (CAT manual
/// 2508-C, "SS"). It only changes the rig's own display — the app's
/// waterfall is audio-derived.
public enum SpectrumScopeColor {
    /// Number of schemes, COLOR-1…COLOR-11.
    public static let count = 11

    /// The P3 character for an index, nil outside 0-10.
    public static func code(for index: Int) -> Character? {
        guard (0..<count).contains(index) else { return nil }
        return Character(String(index, radix: 16, uppercase: true))
    }

    /// The index for a P3 character ("0"-"9", "A"; lowercase accepted).
    public static func index(fromCode code: Character) -> Int? {
        guard let value = code.hexDigitValue, value < count else { return nil }
        return value
    }

    /// Parses a "SS03" answer such as "SS0300000;" or "SS03A0000;".
    public static func index(fromAnswer reply: String) -> Int? {
        guard reply.hasPrefix("SS03"), let code = reply.dropFirst(4).first else { return nil }
        return index(fromCode: code)
    }

    /// The set command (without ";"), e.g. 10 -> "SS03A0000".
    public static func setCommand(_ index: Int) -> String? {
        guard let code = code(for: index) else { return nil }
        return "SS03\(code)0000"
    }

    /// "COLOR-1"…"COLOR-11" (the rig's own label, not localized), "—" when unknown.
    public static func label(_ index: Int?) -> String {
        guard let index, (0..<count).contains(index) else { return "—" }
        return "COLOR-\(index + 1)"
    }
}

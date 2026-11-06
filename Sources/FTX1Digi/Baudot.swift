/// ITA2 / US-TTY Baudot: the 5-bit code amateur RTTY uses. Letters and
/// figures share the 32 codes; LTRS (31) and FIGS (27) switch between them.
/// The figures case is the US TTY one (S = bell, J = apostrophe), which is
/// what most amateur software sends.
public enum Baudot {
    static let ltrs: UInt8 = 31
    static let figs: UInt8 = 27
    static let space: UInt8 = 4
    static let lineFeed: UInt8 = 2
    static let carriageReturn: UInt8 = 8

    /// nil = no printable character (NUL, the shifts, CR, bell).
    static let letters: [Character?] = [
        nil, "E", "\n", "A", " ", "S", "I", "U",
        nil, "D", "R", "J", "N", "F", "C", "K",
        "T", "Z", "L", "W", "H", "Y", "P", "Q",
        "O", "B", "G", nil, "M", "X", "V", nil,
    ]

    static let figures: [Character?] = [
        nil, "3", "\n", "-", " ", nil, "8", "7",
        nil, "$", "4", "'", ",", "!", ":", "(",
        "5", "\"", ")", "2", "#", "6", "0", "1",
        "9", "?", "&", nil, ".", "/", ";", nil,
    ]

    /// Turns 5-bit codes into text, keeping the LTRS/FIGS state.
    public struct Decoder: Sendable {
        /// Unshift on space: a space in figures case drops back to letters,
        /// as most senders expect (a lost LTRS then costs one word, not the
        /// rest of the line).
        public var unshiftOnSpace: Bool
        private(set) var inFigures = false

        public init(unshiftOnSpace: Bool = true) {
            self.unshiftOnSpace = unshiftOnSpace
        }

        public mutating func decode(_ code: UInt8) -> Character? {
            let code = code & 0x1F
            switch code {
            case ltrs:
                inFigures = false
                return nil
            case figs:
                inFigures = true
                return nil
            default:
                let character = (inFigures ? figures : letters)[Int(code)]
                if code == space, unshiftOnSpace { inFigures = false }
                return character
            }
        }

        public mutating func reset() { inFigures = false }
    }

    /// Text → codes, shifting as needed (for tests and test signals).
    /// Unknown characters are skipped; lowercase is sent as uppercase.
    static func encode(_ text: String) -> [UInt8] {
        var codes: [UInt8] = [ltrs]
        var inFigures = false
        for character in text.uppercased() {
            if character == "\n" {
                codes += [carriageReturn, lineFeed]
                continue
            }
            if let index = letters.firstIndex(where: { $0 == character }), index != Int(lineFeed) {
                if inFigures, index != Int(space) {
                    codes.append(ltrs)
                    inFigures = false
                }
                codes.append(UInt8(index))
                // Mirror unshift-on-space on the receiving side.
                if index == Int(space) { inFigures = false }
            } else if let index = figures.firstIndex(where: { $0 == character }) {
                if !inFigures {
                    codes.append(figs)
                    inFigures = true
                }
                codes.append(UInt8(index))
            }
        }
        return codes
    }
}

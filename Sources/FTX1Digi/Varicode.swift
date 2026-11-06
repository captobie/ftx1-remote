/// PSK31 Varicode (G3PLX): one code per ASCII character 0–127, each
/// starting and ending with 1 and never containing "00", so two zeros in a
/// row end a character. Common letters get the short codes ("e" = 11).
public enum Varicode {
    /// Indexed by ASCII value.
    static let codes: [String] = [
        "1010101011", "1011011011", "1011101101", "1101110111", "1011101011", "1101011111", "1011101111", "1011111101",
        "1011111111", "11101111", "11101", "1101101111", "1011011101", "11111", "1101110101", "1110101011",
        "1011110111", "1011110101", "1110101101", "1110101111", "1101011011", "1101101011", "1101101101", "1101010111",
        "1101111011", "1101111101", "1110110111", "1101010101", "1101011101", "1110111011", "1011111011", "1101111111",
        "1", "111111111", "101011111", "111110101", "111011011", "1011010101", "1010111011", "101111111",
        "11111011", "11110111", "101101111", "111011111", "1110101", "110101", "1010111", "110101111",
        "10110111", "10111101", "11101101", "11111111", "101110111", "101011011", "101101011", "110101101",
        "110101011", "110110111", "11110101", "110111101", "111101101", "1010101", "111010111", "1010101111",
        "1010111101", "1111101", "11101011", "10101101", "10110101", "1110111", "11011011", "11111101",
        "101010101", "1111111", "111111101", "101111101", "11010111", "10111011", "11011101", "10101011",
        "11010101", "111011101", "10101111", "1101111", "1101101", "101010111", "110110101", "101011101",
        "101110101", "101111011", "1010101101", "111110111", "111101111", "111111011", "1010111111", "101101101",
        "1011011111", "1011", "1011111", "101111", "101101", "11", "111101", "1011011",
        "101011", "1101", "111101011", "10111111", "11011", "111011", "1111", "111",
        "111111", "110111111", "10101", "10111", "101", "110111", "1111011", "1101011",
        "11011111", "1011101", "111010101", "1010110111", "110111011", "1010110101", "1011010111", "1110110101",
    ]

    private static let lookup: [UInt32: UInt8] = {
        var table: [UInt32: UInt8] = [:]
        for (ascii, code) in codes.enumerated() {
            table[UInt32(code, radix: 2)!] = UInt8(ascii)
        }
        return table
    }()

    /// Turns the demodulated bit stream into characters.
    public struct Decoder: Sendable {
        private var register: UInt32 = 0
        private var length = 0

        public init() {}

        /// Feeds one bit; returns the ASCII value when a character ends.
        public mutating func push(bit: Bool) -> UInt8? {
            register = (register << 1) | (bit ? 1 : 0)
            length += 1
            if register & 0b11 == 0 {
                // Two zeros: the bits before them are a character.
                let code = register >> 2
                register = 0
                length = 0
                guard code != 0 else { return nil }
                return Varicode.lookup[code]
            }
            // No code is longer than 10 bits (plus the two zeros); anything
            // longer is noise.
            if length > 12 {
                register = 0
                length = 0
            }
            return nil
        }

        public mutating func reset() {
            register = 0
            length = 0
        }
    }

    /// Text → bits, each character followed by "00" (for tests and test
    /// signals). Non-ASCII characters are skipped.
    static func encode(_ text: String) -> [Bool] {
        var bits: [Bool] = []
        for scalar in text.unicodeScalars where scalar.value < 128 {
            bits += codes[Int(scalar.value)].map { $0 == "1" }
            bits += [false, false]
        }
        return bits
    }
}

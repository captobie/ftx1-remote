import Foundation

/// Turns text into transmit audio at 8 kHz, one chunk at a time, pulling
/// characters as it reaches each character boundary — so text typed while
/// transmitting goes out as soon as the character before it is done.
protocol DigiModulator: AnyObject {
    /// Called as each character starts going out (the transmit echo).
    var onCharacterStarted: ((Character) -> Void)? { get set }
    /// The closing tail has been sent.
    var isFinished: Bool { get }
    /// `count` samples, peak `level`. `next` supplies the next character,
    /// or nil to idle (RTTY: LTRS, PSK: reversals).
    func render(_ count: Int, next: () -> Character?) -> [Float]
    /// No more text: send what's in progress, then the tail, then silence.
    func beginTail()
}

/// AFSK RTTY: phase-continuous tones; start bit, five bits LSB first,
/// 1.5 stop bits per character.
final class RTTYModulator: DigiModulator {
    static let sampleRate: Double = 8000

    var onCharacterStarted: ((Character) -> Void)?
    private(set) var isFinished = false

    private let markHz: Double
    private let spaceHz: Double
    private let samplesPerBit: Double
    private let level: Float
    private var phase = 0.0

    /// Bits still to send: mark or space and length in bits.
    private var pending: [(mark: Bool, bits: Double)] = []
    private var current: (mark: Bool, samplesLeft: Double)?
    private var inFigures = false
    private var tailing = false
    private var tailQueued = false

    init(markHz: Double, spaceHz: Double, baud: Double, level: Float) {
        self.markHz = markHz
        self.spaceHz = spaceHz
        self.level = level
        samplesPerBit = Self.sampleRate / baud
        // Half a second of steady mark, then LTRS to set the shift.
        pending = [(true, 0.5 * baud)]
        append(code: Baudot.ltrs)
    }

    func beginTail() { tailing = true }

    func render(_ count: Int, next: () -> Character?) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        for n in 0..<count {
            if current == nil || current!.samplesLeft <= 0 {
                guard advance(next: next) else { return output } // finished: rest silent
            }
            let tone = current!.mark ? markHz : spaceHz
            output[n] = level * Float(sin(phase))
            phase += 2 * .pi * tone / Self.sampleRate
            if phase > 2 * .pi { phase -= 2 * .pi }
            current!.samplesLeft -= 1
        }
        return output
    }

    /// Moves to the next bit, filling the queue first if it's empty.
    private func advance(next: () -> Character?) -> Bool {
        let carry = current.map { $0.samplesLeft } ?? 0 // ≤ 0: keeps bit timing exact
        if pending.isEmpty {
            if tailQueued {
                isFinished = true
                current = nil
                return false
            }
            if tailing {
                // Finish on LTRS and a moment of mark.
                append(code: Baudot.ltrs)
                pending.append((true, 0.2 * Self.sampleRate / samplesPerBit))
                tailQueued = true
            } else if let character = next() {
                enqueue(character)
                if pending.isEmpty { append(code: Baudot.ltrs) } // unsendable: idle
            } else {
                append(code: Baudot.ltrs)
            }
        }
        let bit = pending.removeFirst()
        current = (bit.mark, bit.bits * samplesPerBit + carry)
        return true
    }

    private func enqueue(_ character: Character) {
        let codes = Self.codes(for: character, inFigures: &inFigures)
        guard !codes.isEmpty else { return }
        onCharacterStarted?(character)
        for code in codes { append(code: code) }
    }

    private func append(code: UInt8) {
        pending.append((false, 1))
        for k in 0..<5 { pending.append(((code >> UInt8(k)) & 1 == 1, 1)) }
        pending.append((true, 1.5))
    }

    /// The codes for one character, shifting as needed. A space drops back
    /// to letters on both ends (unshift on space), so figures after a space
    /// get a fresh FIGS.
    static func codes(for character: Character, inFigures: inout Bool) -> [UInt8] {
        let upper = Character(character.uppercased())
        if upper == "\n" || upper == "\r" {
            return [Baudot.carriageReturn, Baudot.lineFeed]
        }
        if upper == " " {
            inFigures = false
            return [Baudot.space]
        }
        if let index = Baudot.letters.firstIndex(where: { $0 == upper }) {
            defer { inFigures = false }
            return inFigures ? [Baudot.ltrs, UInt8(index)] : [UInt8(index)]
        }
        if let index = Baudot.figures.firstIndex(where: { $0 == upper }) {
            defer { inFigures = true }
            return inFigures ? [UInt8(index)] : [Baudot.figs, UInt8(index)]
        }
        return []
    }
}

/// BPSK31/63: a reversal (0) swings the amplitude through zero with a
/// cosine over the symbol, a 1 holds it. Preamble and idle are reversals;
/// the tail is steady carrier.
final class PSKModulator: DigiModulator {
    static let sampleRate: Double = 8000
    static let preambleSymbols = 32
    static let tailSymbols = 32

    var onCharacterStarted: ((Character) -> Void)?
    private(set) var isFinished = false

    private let carrierHz: Double
    private let samplesPerSymbol: Int
    private let level: Float
    private var phase = 0.0
    private var sign: Float = 1

    private var pending: [Bool]
    private var bit = false
    private var sampleInSymbol = 0
    private var started = false
    private var tailing = false
    private var tailQueued = false

    init(carrierHz: Double, baud: Double, level: Float) {
        self.carrierHz = carrierHz
        self.level = level
        samplesPerSymbol = Int((Self.sampleRate / baud).rounded())
        pending = [Bool](repeating: false, count: Self.preambleSymbols)
    }

    func beginTail() { tailing = true }

    func render(_ count: Int, next: () -> Character?) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        for n in 0..<count {
            if !started || sampleInSymbol == samplesPerSymbol {
                if started, !bit { sign = -sign }
                guard advance(next: next) else { return output }
                started = true
                sampleInSymbol = 0
            }
            let envelope: Float = bit
                ? sign
                : sign * Float(cos(Double.pi * Double(sampleInSymbol) / Double(samplesPerSymbol)))
            output[n] = level * envelope * Float(cos(phase))
            phase += 2 * .pi * carrierHz / Self.sampleRate
            if phase > 2 * .pi { phase -= 2 * .pi }
            sampleInSymbol += 1
        }
        return output
    }

    private func advance(next: () -> Character?) -> Bool {
        if pending.isEmpty {
            if tailQueued {
                isFinished = true
                return false
            }
            if tailing {
                // Two zeros end the last character, then steady carrier.
                pending = [false, false] + [Bool](repeating: true, count: Self.tailSymbols)
                tailQueued = true
            } else if let character = next(), let bits = Self.bits(for: character) {
                onCharacterStarted?(character)
                pending = bits
            } else {
                pending = [false] // idle
            }
        }
        bit = pending.removeFirst()
        return true
    }

    /// Varicode bits plus the "00" separator; nil for non-ASCII.
    static func bits(for character: Character) -> [Bool]? {
        let scalars = character == "\n" ? ["\r", "\n"] : [character]
        var bits: [Bool] = []
        for c in scalars {
            guard let ascii = c.asciiValue, ascii < 128 else { return nil }
            bits += Varicode.codes[Int(ascii)].map { $0 == "1" } + [false, false]
        }
        return bits
    }
}

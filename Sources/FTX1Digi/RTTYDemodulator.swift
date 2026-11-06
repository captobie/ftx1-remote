import Foundation

/// RTTY settings. The centre is the audio frequency halfway between the
/// two tones; with Reverse off the mark is the lower audio tone (what LSB
/// or the rig's RTTY-L mode produces from a normal RTTY signal).
public struct RTTYSettings: Equatable, Sendable {
    public static let shifts: [Double] = [170, 200, 425, 850]
    public static let bauds: [Double] = [45.45, 50, 75]

    public var shiftHz: Double = 170
    public var baud: Double = 45.45
    public var reverse = false
    public var unshiftOnSpace = true

    public init(shiftHz: Double = 170, baud: Double = 45.45, reverse: Bool = false, unshiftOnSpace: Bool = true) {
        self.shiftHz = shiftHz
        self.baud = baud
        self.reverse = reverse
        self.unshiftOnSpace = unshiftOnSpace
    }
}

/// Two-tone FSK demodulator for 5-bit Baudot RTTY at 8 kHz.
///
/// The input is mixed down to the centre and decimated to 2 kHz, then
/// each tone is mixed to 0 Hz and low-passed to about the baud rate
/// (decimated to 1 kHz). Their envelopes feed a decision with automatic
/// threshold correction: each tone's level is tracked on its own and the
/// slicing threshold sits halfway between, so selective fading of one tone
/// doesn't turn it into a run of wrong bits. Characters are framed from the
/// mark→space edge of the start bit, each bit integrated over its middle
/// half, and dropped unless the start bit is space and the stop bit mark.
final class RTTYDemodulator {
    static let inputRate: Double = 8000
    private static let stage1Decimation = 4
    private static let stage2Decimation = 2
    private static let midRate = inputRate / Double(stage1Decimation)
    static let decisionRate = midRate / Double(stage2Decimation)

    let settings: RTTYSettings
    private(set) var centerHz: Double
    /// Where the operator put it; AFC stays within ± half the shift of it.
    private var anchorHz: Double
    var afcEnabled = true

    private var centerNCO: NCO
    private var stage1: DecimatingComplexFIR
    private var markNCO: NCO
    private var spaceNCO: NCO
    private var markFilter: DecimatingComplexFIR
    private var spaceFilter: DecimatingComplexFIR

    private var markEnvelope: Float = 0
    private var spaceEnvelope: Float = 0
    private let attack: Float
    private let decay: Float

    private var previousDecision: Float = 0
    private var previousMark = Complex.zero
    private var previousSpace = Complex.zero
    private var afcErrorHz = 0.0
    private var afcSamples = 0

    private let samplesPerBit: Double
    private var framing = false
    private var samplesSinceEdge = 0
    private var bitSums = [Float](repeating: 0, count: 7)

    private var baudot: Baudot.Decoder
    private var lastWasCarriageReturn = false

    /// 0…1, from the tone contrast below.
    private(set) var quality: Float = 0
    /// Average |m − s| / (m + s): near 1 when one tone or the other is
    /// clearly there, 0.2–0.4 for noise alone (measured on synthesized
    /// noise; a 0 dB RTTY signal still averages over 0.55).
    private var contrast: Float = 0

    init(settings: RTTYSettings, centerHz: Double) {
        self.settings = settings
        self.centerHz = centerHz
        anchorHz = centerHz
        let inRate = Self.inputRate
        let midRate = Self.midRate
        centerNCO = NCO(frequencyHz: centerHz, sampleRate: inRate)
        let stage1Cutoff = settings.shiftHz / 2 + settings.baud * 1.5
        stage1 = DecimatingComplexFIR(
            taps: FIRDesign.lowPass(cutoffHz: stage1Cutoff, sampleRate: inRate, count: 97),
            decimation: Self.stage1Decimation
        )
        // Mark is the lower tone unless reversed.
        let markOffset = settings.reverse ? settings.shiftHz / 2 : -settings.shiftHz / 2
        markNCO = NCO(frequencyHz: markOffset, sampleRate: midRate)
        spaceNCO = NCO(frequencyHz: -markOffset, sampleRate: midRate)
        // Narrow enough that the other tone (at least 170 Hz away) is well
        // into the stop band, wide enough to pass the keying.
        let toneTaps = FIRDesign.lowPass(cutoffHz: settings.baud * 0.75, sampleRate: midRate, count: 161)
        markFilter = DecimatingComplexFIR(taps: toneTaps, decimation: Self.stage2Decimation)
        spaceFilter = DecimatingComplexFIR(taps: toneTaps, decimation: Self.stage2Decimation)

        samplesPerBit = Self.decisionRate / settings.baud
        attack = Float(min(1, 4 / samplesPerBit))
        decay = Float(1 / (16 * samplesPerBit))
        baudot = Baudot.Decoder(unshiftOnSpace: settings.unshiftOnSpace)
    }

    /// Moves the centre (a click on the tuning strip): AFC re-anchors there.
    func setCenter(_ hz: Double) {
        centerHz = hz
        anchorHz = hz
        centerNCO.frequencyHz = hz
        afcErrorHz = 0
        afcSamples = 0
    }

    func reset() {
        stage1.reset()
        markFilter.reset()
        spaceFilter.reset()
        markEnvelope = 0
        spaceEnvelope = 0
        contrast = 0
        framing = false
        baudot.reset()
        quality = 0
    }

    /// Demodulates 8 kHz samples; returns the characters completed.
    func process(_ samples: [Float]) -> String {
        var output = ""
        for x in samples {
            let lo = centerNCO.next()
            guard let mid = stage1.push(x * lo.cos, x * lo.sin) else { continue }
            let m = markNCO.next()
            let s = spaceNCO.next()
            let markOut = markFilter.push(mid.i * m.cos - mid.q * m.sin, mid.i * m.sin + mid.q * m.cos)
            let spaceOut = spaceFilter.push(mid.i * s.cos - mid.q * s.sin, mid.i * s.sin + mid.q * s.cos)
            guard let markOut, let spaceOut else { continue }
            if let character = decide(mark: Complex(re: markOut.i, im: markOut.q),
                                      space: Complex(re: spaceOut.i, im: spaceOut.q)) {
                output.append(character)
            }
        }
        return output
    }

    // MARK: - Decision and framing (1 kHz)

    private func decide(mark: Complex, space: Complex) -> Character? {
        let m = mark.magnitude
        let s = space.magnitude
        markEnvelope += (m > markEnvelope ? attack : decay) * (m - markEnvelope)
        spaceEnvelope += (s > spaceEnvelope ? attack : decay) * (s - spaceEnvelope)
        let sum = m + s
        if sum > 0 { contrast += 0.01 * (abs(m - s) / sum - contrast) }
        quality = min(1, max(0, (contrast - 0.35) / 0.35))
        trackFrequency(mark: mark, space: space, m: m, s: s)

        // Optimal ATC: clip each tone to its own envelope, then slice
        // halfway between the two envelopes.
        let d = min(m, markEnvelope) - min(s, spaceEnvelope) - 0.5 * (markEnvelope - spaceEnvelope)
        defer { previousDecision = d }
        return frame(decision: d)
    }

    private func frame(decision d: Float) -> Character? {
        if !framing {
            // Waiting for a start bit's mark→space edge.
            if previousDecision > 0, d <= 0 {
                framing = true
                samplesSinceEdge = 0
                for k in bitSums.indices { bitSums[k] = 0 }
            }
            return nil
        }
        let position = Double(samplesSinceEdge) / samplesPerBit
        samplesSinceEdge += 1
        let bit = Int(position)
        let fraction = position - Double(bit)
        if bit < bitSums.count, fraction >= 0.25, fraction <= 0.75 {
            bitSums[bit] += d
        }
        // A start bit that wasn't space after all: a glitch.
        if bit == 0, fraction > 0.75, bitSums[0] >= 0 {
            framing = false
            return nil
        }
        // Start (0), five data bits (1…5), stop (6): decide once the stop
        // bit's middle half is in.
        guard position >= 6.75 else { return nil }
        framing = false
        guard bitSums[6] > 0 else { return nil } // framing error
        var code: UInt8 = 0
        for k in 0..<5 where bitSums[k + 1] > 0 {
            code |= 1 << UInt8(k)
        }
        return character(for: code)
    }

    private func character(for code: UInt8) -> Character? {
        // CR LF, LF CR, CR CR LF… all print one line break.
        if code == Baudot.carriageReturn {
            lastWasCarriageReturn = true
            return "\n"
        }
        let wasCR = lastWasCarriageReturn
        lastWasCarriageReturn = false
        let character = baudot.decode(code)
        if character == "\n", wasCR { return nil }
        return character
    }

    // MARK: - AFC

    private func trackFrequency(mark: Complex, space: Complex, m: Float, s: Float) {
        defer {
            previousMark = mark
            previousSpace = space
        }
        guard afcEnabled, quality > 0.3 else { return }
        // Each tone's own phase rotation says how far it sits from its arm.
        let rate = Self.decisionRate
        var errorHz: Double?
        if m > 2 * s, previousMark.magnitudeSquared > 0 {
            errorHz = Double(mark.timesConjugate(of: previousMark).phase) * rate / (2 * .pi)
        } else if s > 2 * m, previousSpace.magnitudeSquared > 0 {
            errorHz = Double(space.timesConjugate(of: previousSpace).phase) * rate / (2 * .pi)
        }
        guard let errorHz else { return }
        afcErrorHz += 0.01 * (errorHz - afcErrorHz)
        afcSamples += 1
        guard afcSamples >= 100 else { return }
        afcSamples = 0
        let limit = settings.shiftHz / 2
        centerHz = min(anchorHz + limit, max(anchorHz - limit, centerHz + 0.5 * afcErrorHz))
        centerNCO.frequencyHz = centerHz
        afcErrorHz *= 0.5
    }
}

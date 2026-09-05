import Foundation

/// Demodulates Bell 202 AFSK (1200 Hz mark / 2200 Hz space, 1200 baud —
/// the standard VHF packet/APRS modulation) into a stream of NRZI-encoded
/// line bits: flags and bit-stuffed data, exactly what `AX25FrameDecoder`
/// expects as input. Does not know about AX.25 framing at all — this is
/// pure tone detection + bit-clock recovery + NRZI decode, reusable for
/// any Bell 202 payload.
///
/// Stateful and incremental (tone-detector EMA state, bit-clock DPLL
/// phase, last sampled line level all carry across calls), since audio
/// arrives as a stream of arbitrary-sized chunks from `AudioCaptureEngine`'s
/// tap, not one packet at a time.
public struct AFSKDemodulator {
    private let markHz: Double = 1200
    private let spaceHz: Double = 2200
    private let baudRate: Double = 1200
    private let sampleRate: Double

    // Per-sample quadrature correlators against the mark/space tones,
    // smoothed with an exponential moving average — a lightweight
    // non-coherent tone detector: whichever tone currently has more
    // energy is the "raw bit" for this sample (mark = high, space = low).
    // This is smoothed continuously at the full sample rate; symbol
    // timing (which samples actually count as a bit) is recovered
    // separately below.
    private var markPhase: Double = 0
    private var spacePhase: Double = 0
    private var markI: Double = 0
    private var markQ: Double = 0
    private var spaceI: Double = 0
    private var spaceQ: Double = 0
    private let emaAlpha: Double

    // Bit-clock recovery: a digital PLL that tracks transitions in the
    // raw (full-sample-rate) mark/space decision stream. `phase` runs
    // 0..<1 over one bit period; the symbol is latched when phase crosses
    // 0.5 (bit center, safely away from any edge), and every detected
    // transition nudges `phase` back toward 0 (mod 1) — the point where a
    // transition should ideally land if the clock is locked. This is the
    // standard zero-crossing bit synchronizer used by simple software AFSK
    // decoders; it has to track real hardware here (no exact
    // samples-per-bit alignment like a synthesized test signal has), which
    // is why the correction step exists at all.
    private var bitPhase: Double = 0
    private let bitPhaseIncrement: Double
    /// Empirically tuned against a real recorded APRS capture (not just
    /// synthetic test signals) — a stronger correction (tried up to 0.3)
    /// measurably *hurt* real-world decode count. Every raw-bit transition
    /// includes some that are spurious (noise crossing near a genuine tie
    /// between mark/space energy, not a real bit boundary); reacting to
    /// those strongly chases noise instead of tracking the true clock. A
    /// weaker, slower-responding correction tolerates more of that without
    /// losing lock, which won synthetic tests too (no regression there).
    private let dampingFactor: Double = 0.05
    private var lastRawBit: Bool?
    private var lastLineLevel = true

    // Single-pole DC blocker (`y[n] = x[n] - x[n-1] + r*y[n-1]`), applied
    // before tone detection — real radio/interface audio commonly carries
    // some DC bias or slow drift that a clean synthetic test signal never
    // has, and it costs nothing to strip out defensively.
    private var dcBlockerPreviousInput: Double = 0
    private var dcBlockerPreviousOutput: Double = 0
    private let dcBlockerR = 0.995

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.bitPhaseIncrement = baudRate / sampleRate
        // One full bit period, not a fraction of one — this needs to
        // reject the *other* tone, and a window shorter than a full cycle
        // of the 1200 Hz mark tone (a half-bit window at 48kHz/1200baud is
        // under 0.42ms, less than half a 1200 Hz cycle) gives the
        // correlator almost no real frequency selectivity. A full bit
        // period covers about one full mark cycle and 1.8 space cycles —
        // enough to actually discriminate between them under real noise,
        // still short enough to not blur across a bit transition.
        let samplesPerBit = sampleRate / baudRate
        self.emaAlpha = 2.0 / (samplesPerBit + 1)
    }

    /// Feeds raw PCM samples and returns any newly recovered line bits
    /// (NRZI-decoded, not yet destuffed).
    public mutating func process(samples: [Float]) -> [Bool] {
        var lineBits: [Bool] = []
        lineBits.reserveCapacity(samples.count / Int(sampleRate / baudRate) + 1)
        for sample in samples {
            if let bit = processSample(Double(sample)) {
                lineBits.append(bit)
            }
        }
        return lineBits
    }

    private mutating func processSample(_ rawSample: Double) -> Bool? {
        let sample = rawSample - dcBlockerPreviousInput + dcBlockerR * dcBlockerPreviousOutput
        dcBlockerPreviousInput = rawSample
        dcBlockerPreviousOutput = sample

        markPhase += 2 * .pi * markHz / sampleRate
        spacePhase += 2 * .pi * spaceHz / sampleRate
        if markPhase > 2 * .pi { markPhase -= 2 * .pi }
        if spacePhase > 2 * .pi { spacePhase -= 2 * .pi }

        markI += emaAlpha * (sample * cos(markPhase) - markI)
        markQ += emaAlpha * (sample * sin(markPhase) - markQ)
        spaceI += emaAlpha * (sample * cos(spacePhase) - spaceI)
        spaceQ += emaAlpha * (sample * sin(spacePhase) - spaceQ)

        let markEnergy = markI * markI + markQ * markQ
        let spaceEnergy = spaceI * spaceI + spaceQ * spaceQ
        let rawBit = markEnergy > spaceEnergy

        let previousPhase = bitPhase
        bitPhase += bitPhaseIncrement
        let crossedMidBit = previousPhase < 0.5 && bitPhase >= 0.5
        var sampledSymbol: Bool?
        if crossedMidBit {
            sampledSymbol = rawBit
        }
        if bitPhase >= 1.0 {
            bitPhase -= 1.0
        }

        if let last = lastRawBit, last != rawBit {
            let error = bitPhase < 0.5 ? bitPhase : bitPhase - 1.0
            bitPhase -= error * dampingFactor
        }
        lastRawBit = rawBit

        guard let level = sampledSymbol else { return nil }
        let decodedBit = (level == lastLineLevel)
        lastLineLevel = level
        return decodedBit
    }
}

import Foundation
@testable import FTX1Digi

/// Deterministic test signals: RTTY AFSK and BPSK, plus Gaussian noise.
enum SignalSynth {
    struct Noise {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        private mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        private mutating func uniform() -> Double {
            (Double(next() >> 11) + 0.5) / Double(1 << 53)
        }

        mutating func gaussian() -> Double {
            sqrt(-2 * log(uniform())) * cos(2 * .pi * uniform())
        }
    }

    /// Adds white noise for an SNR measured in a 3 kHz bandwidth, the
    /// usual convention for digital modes. `signalPower` is the mean
    /// square of the clean signal.
    static func addNoise(_ signal: [Float], snrDb3k: Double, sampleRate: Double, seed: UInt64 = 1) -> [Float] {
        let power = signal.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(signal.count, 1))
        return addNoise(signal, power: power, snrDb3k: snrDb3k, sampleRate: sampleRate, seed: seed)
    }

    static func addNoise(_ signal: [Float], power: Double, snrDb3k: Double, sampleRate: Double, seed: UInt64 = 1) -> [Float] {
        // Noise in 3 kHz = σ² · 3000 / (fs/2).
        let noiseIn3k = power / pow(10, snrDb3k / 10)
        let sigma = sqrt(noiseIn3k * (sampleRate / 2) / 3000)
        var noise = Noise(seed: seed)
        return signal.map { $0 + Float(sigma * noise.gaussian()) }
    }

    static func noise(seconds: Double, sigma: Double, sampleRate: Double, seed: UInt64 = 7) -> [Float] {
        var noise = Noise(seed: seed)
        return (0..<Int(seconds * sampleRate)).map { _ in Float(sigma * noise.gaussian()) }
    }

    /// Phase-continuous AFSK: idle mark, then each code as start (space),
    /// five data bits LSB first (1 = mark), 1.5 stop bits (mark).
    static func rtty(
        text: String, markHz: Double, spaceHz: Double, baud: Double = 45.45,
        sampleRate: Double = 8000, leadSeconds: Double = 0.5, amplitude: Double = 0.5
    ) -> [Float] {
        var bits: [(mark: Bool, length: Double)] = [(true, leadSeconds * baud)]
        for code in Baudot.encode(text) {
            bits.append((false, 1))
            for k in 0..<5 { bits.append(((code >> UInt8(k)) & 1 == 1, 1)) }
            bits.append((true, 1.5))
        }
        bits.append((true, leadSeconds * baud))

        var output: [Float] = []
        var phase = 0.0
        var time = 0.0 // in bits
        let bitsPerSample = baud / sampleRate
        for bit in bits {
            let end = time + bit.length
            let step = 2 * .pi * (bit.mark ? markHz : spaceHz) / sampleRate
            while time < end {
                output.append(Float(amplitude * sin(phase)))
                phase += step
                time += bitsPerSample
            }
        }
        return output
    }

    /// PSK31-style BPSK: a reversal (bit 0) swings the amplitude through
    /// zero with a cosine over the symbol; a 1 holds it. Preamble and
    /// postamble are idle reversals, as real transmitters send.
    static func bpsk(
        text: String, carrierHz: Double, baud: Double = 31.25,
        sampleRate: Double = 8000, idleSymbols: Int = 64, amplitude: Double = 0.5
    ) -> [Float] {
        let idle = [Bool](repeating: false, count: idleSymbols)
        let bits = idle + Varicode.encode(text) + idle
        let samplesPerSymbol = sampleRate / baud
        var output: [Float] = []
        var sign = 1.0
        var n = 0
        for (index, bit) in bits.enumerated() {
            let end = Int((Double(index + 1) * samplesPerSymbol).rounded())
            let start = n
            while n < end {
                let tau = Double(n - start) / Double(end - start)
                let envelope = bit ? sign : sign * cos(.pi * tau)
                output.append(Float(amplitude * envelope * cos(2 * .pi * carrierHz * Double(n) / sampleRate)))
                n += 1
            }
            if !bit { sign = -sign }
        }
        return output
    }
}

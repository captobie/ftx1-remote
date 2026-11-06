import Foundation

/// BPSK31/BPSK63 demodulator at 8 kHz.
///
/// The input is mixed down to the carrier and decimated to 16 samples a
/// symbol (two low-pass stages). Symbol timing comes from the amplitude:
/// BPSK's envelope dips at every phase reversal, so the average amplitude
/// at each of the 16 sample slots peaks at the symbol centre. Bits are
/// differential (no phase change = 1, a reversal = 0) and go through the
/// Varicode decoder.
///
/// One complex average does double duty: `d²/|d|²`, with `d` the phase
/// step between symbols, points the same way every symbol for a clean
/// signal whatever its frequency offset, and is random for noise. Its
/// length is the quality (squelch), its angle half the residual rotation
/// per symbol (AFC, and the decisions are de-rotated by it).
final class PSKDemodulator {
    static let inputRate: Double = 8000
    static let samplesPerSymbol = 16
    private static let stage1Decimation = 8
    private static let midRate = inputRate / Double(stage1Decimation)

    let baud: Double
    private(set) var centerHz: Double
    private var anchorHz: Double
    /// How far AFC may move from where the operator put the carrier.
    static let afcLimitHz = 15.0
    var afcEnabled = true

    private var nco: NCO
    private var stage1: DecimatingComplexFIR
    private var stage2: DecimatingComplexFIR

    private var syncBins = [Float](repeating: 0, count: samplesPerSymbol)
    private var slot = 0
    private var decisionSlot = 0
    private var previousSymbol = Complex.zero

    private var rotationAverage = Complex.zero
    private var varicode = Varicode.Decoder()

    /// 0…1: how cleanly the phase steps land on 0°/180°.
    private(set) var quality: Float = 0
    /// Characters print only above this quality.
    var squelch: Float = 0.3

    init(baud: Double, centerHz: Double) {
        self.baud = baud
        self.centerHz = centerHz
        anchorHz = centerHz
        nco = NCO(frequencyHz: centerHz, sampleRate: Self.inputRate)
        stage1 = DecimatingComplexFIR(
            taps: FIRDesign.lowPass(cutoffHz: 150, sampleRate: Self.inputRate, count: 97),
            decimation: Self.stage1Decimation
        )
        let symbolRate = baud * Double(Self.samplesPerSymbol)
        let decimation2 = max(1, Int((Self.midRate / symbolRate).rounded()))
        stage2 = DecimatingComplexFIR(
            taps: FIRDesign.lowPass(cutoffHz: baud, sampleRate: Self.midRate, count: 129),
            decimation: decimation2
        )
    }

    func setCenter(_ hz: Double) {
        centerHz = hz
        anchorHz = hz
        nco.frequencyHz = hz
        rotationAverage = .zero
    }

    func reset() {
        stage1.reset()
        stage2.reset()
        for k in syncBins.indices { syncBins[k] = 0 }
        varicode.reset()
        rotationAverage = .zero
        quality = 0
    }

    func process(_ samples: [Float]) -> String {
        var output = ""
        for x in samples {
            let lo = nco.next()
            guard let mid = stage1.push(x * lo.cos, x * lo.sin),
                  let z = stage2.push(mid.i, mid.q)
            else { continue }
            if let character = symbolSample(Complex(re: z.i, im: z.q)) {
                output.unicodeScalars.append(character)
            }
        }
        return output
    }

    // MARK: - 16 samples a symbol

    private func symbolSample(_ z: Complex) -> Unicode.Scalar? {
        syncBins[slot] += 0.05 * (z.magnitude - syncBins[slot])
        defer {
            slot += 1
            if slot == Self.samplesPerSymbol {
                slot = 0
                decisionSlot = Self.peakSlot(of: syncBins)
            }
        }
        guard slot == decisionSlot else { return nil }
        return symbol(z)
    }

    /// The circular centroid of the amplitude above its minimum.
    static func peakSlot(of bins: [Float]) -> Int {
        let floor = bins.min() ?? 0
        var x: Float = 0
        var y: Float = 0
        for (k, value) in bins.enumerated() {
            let angle = 2 * Float.pi * Float(k) / Float(bins.count)
            x += (value - floor) * cos(angle)
            y += (value - floor) * sin(angle)
        }
        guard x != 0 || y != 0 else { return 0 }
        var position = atan2(y, x) / (2 * .pi) * Float(bins.count)
        if position < 0 { position += Float(bins.count) }
        return Int(position.rounded()) % bins.count
    }

    private func symbol(_ z: Complex) -> Unicode.Scalar? {
        defer { previousSymbol = z }
        let d = z.timesConjugate(of: previousSymbol)
        let power = d.magnitudeSquared
        guard power > 0 else { return nil }
        let unitSquare = d.squared()
        rotationAverage.re += 0.05 * (unitSquare.re / power - rotationAverage.re)
        rotationAverage.im += 0.05 * (unitSquare.im / power - rotationAverage.im)
        quality = min(1, rotationAverage.magnitude)

        // Residual rotation per symbol, from the average (so one noisy
        // symbol doesn't swing it).
        let rotation = rotationAverage.phase / 2
        let corrected = d.re * cos(rotation) + d.im * sin(rotation)
        let bit = corrected > 0

        if afcEnabled, quality > 0.2 {
            let errorHz = Double(rotation) / (2 * .pi) * baud
            let limit = Self.afcLimitHz
            centerHz = min(anchorHz + limit, max(anchorHz - limit, centerHz + 0.02 * errorHz))
            nco.frequencyHz = centerHz
        }

        guard let ascii = varicode.push(bit: bit), quality >= squelch else { return nil }
        return Self.printable(ascii)
    }

    private static func printable(_ ascii: UInt8) -> Unicode.Scalar? {
        switch ascii {
        case 10: return "\n"
        case 9: return " "
        case 32..<127: return Unicode.Scalar(ascii)
        default: return nil // CR, other controls
        }
    }
}

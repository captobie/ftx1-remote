import Accelerate
import Foundation

/// Small DSP building blocks shared by the RTTY and PSK demodulators.
/// Everything here runs on the decoder's own queue, never the main actor,
/// and is used by one demodulator at a time (not thread-safe).
enum FIRDesign {
    /// Windowed-sinc (Blackman) low-pass taps, normalized to unity DC gain.
    /// `cutoffHz` is the -6 dB point; `count` should be odd.
    static func lowPass(cutoffHz: Double, sampleRate: Double, count: Int) -> [Float] {
        precondition(count > 2)
        let fc = cutoffHz / sampleRate
        let middle = Double(count - 1) / 2
        var taps = [Float](repeating: 0, count: count)
        var sum = 0.0
        for i in 0..<count {
            let n = Double(i) - middle
            let sinc = n == 0 ? 2 * fc : sin(2 * .pi * fc * n) / (.pi * n)
            let x = Double(i) / Double(count - 1)
            let window = 0.42 - 0.5 * cos(2 * .pi * x) + 0.08 * cos(4 * .pi * x)
            let value = sinc * window
            taps[i] = Float(value)
            sum += value
        }
        let scale = Float(1 / sum)
        return taps.map { $0 * scale }
    }
}

/// A real-tap FIR over complex samples (separate I and Q), computing one
/// output every `decimation` inputs. The history is kept twice over
/// (`buffer[i]` and `buffer[i + n]`) so the newest `n` samples are always
/// contiguous for `vDSP_dotpr`, which keeps this cheap in Debug builds too.
struct DecimatingComplexFIR {
    let taps: [Float]
    let decimation: Int
    private var bufferI: [Float]
    private var bufferQ: [Float]
    private var index = 0
    private var phase = 0

    init(taps: [Float], decimation: Int) {
        self.taps = taps
        self.decimation = max(1, decimation)
        bufferI = [Float](repeating: 0, count: taps.count * 2)
        bufferQ = [Float](repeating: 0, count: taps.count * 2)
    }

    /// Pushes one sample; returns the filtered value on every
    /// `decimation`-th call, nil otherwise.
    mutating func push(_ i: Float, _ q: Float) -> (i: Float, q: Float)? {
        let n = taps.count
        bufferI[index] = i
        bufferI[index + n] = i
        bufferQ[index] = q
        bufferQ[index + n] = q
        index += 1
        if index == n { index = 0 }
        phase += 1
        guard phase >= decimation else { return nil }
        phase = 0
        // The newest n samples are buffer[index ..< index + n], oldest
        // first; the taps are symmetric, so their order doesn't matter.
        var outI: Float = 0
        var outQ: Float = 0
        taps.withUnsafeBufferPointer { t in
            bufferI.withUnsafeBufferPointer { b in
                vDSP_dotpr(b.baseAddress! + index, 1, t.baseAddress!, 1, &outI, vDSP_Length(n))
            }
            bufferQ.withUnsafeBufferPointer { b in
                vDSP_dotpr(b.baseAddress! + index, 1, t.baseAddress!, 1, &outQ, vDSP_Length(n))
            }
        }
        return (outI, outQ)
    }

    mutating func reset() {
        for k in bufferI.indices { bufferI[k] = 0; bufferQ[k] = 0 }
        index = 0
        phase = 0
    }
}

/// A numerically controlled oscillator: `next()` returns e^{-jφ} and
/// advances φ by the current frequency, so `sample * next()` mixes a tone
/// at `frequencyHz` down to 0 Hz.
struct NCO {
    var frequencyHz: Double
    let sampleRate: Double
    private var phase = 0.0

    init(frequencyHz: Double, sampleRate: Double) {
        self.frequencyHz = frequencyHz
        self.sampleRate = sampleRate
    }

    mutating func next() -> (cos: Float, sin: Float) {
        let c = Float(cos(phase))
        let s = Float(-sin(phase))
        phase += 2 * .pi * frequencyHz / sampleRate
        if phase > 2 * .pi { phase -= 2 * .pi } else if phase < 0 { phase += 2 * .pi }
        return (c, s)
    }
}

/// One complex sample, for the demodulators' decimated paths.
struct Complex {
    var re: Float
    var im: Float

    static let zero = Complex(re: 0, im: 0)

    var magnitude: Float { (re * re + im * im).squareRoot() }
    var magnitudeSquared: Float { re * re + im * im }
    var phase: Float { atan2(im, re) }

    /// self × conj(other)
    func timesConjugate(of other: Complex) -> Complex {
        Complex(re: re * other.re + im * other.im, im: im * other.re - re * other.im)
    }

    func squared() -> Complex {
        Complex(re: re * re - im * im, im: 2 * re * im)
    }
}

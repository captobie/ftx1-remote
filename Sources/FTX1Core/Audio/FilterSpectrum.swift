import Accelerate
import Foundation

/// Hann window + real FFT + power→dB for one block of audio — the FFT step
/// behind the Mac's waterfall and both platforms' Filter Function Display
/// spectrum (`FilterDisplayView`). All vDSP: it runs 16–21+ times a second,
/// and the Debug build is `-Onone` (see repo CLAUDE.md on per-sample Swift
/// in hot paths).
///
/// The dB values are scaled to what a 2048-point FFT gives for the same
/// signal, whatever `size` is, so `SpectrumAutoGain`'s absolute floor
/// (tuned on the Mac's 2048-point FFT) means the same level at the iPad's
/// 512 points. Immutable after `init`, so one instance can serve several
/// channels from any thread.
public final class SpectrumFFT: @unchecked Sendable {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    /// `vDSP_vdbcon`'s reference power: (size / 2048)², see the type doc.
    private let referencePower: Float

    /// `size` must be a power of two.
    public init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "SpectrumFFT size must be a power of two")
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.window = window
        let scale = Float(size) / 2048
        referencePower = scale * scale
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Hz per output bin at `sampleRate`.
    public func binHz(sampleRate: Double) -> Double {
        sampleRate / Double(size)
    }

    /// The `size / 2` power bins (dB) up to Nyquist. `samples` shorter than
    /// `size` are zero-padded at the end, longer ones truncated.
    public func powerDb(_ samples: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: size)
        let count = min(samples.count, size)
        if count > 0 {
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(count))
        }

        let halfSize = size / 2
        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { srcPtr in
                    srcPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Power -> dB (vDSP_vdbcon flag 1 = 10*log10, since zvmags already
        // produced squared-magnitude/power values, not amplitude).
        var reference = referencePower
        var db = [Float](repeating: 0, count: halfSize)
        vDSP_vdbcon(magnitudes, 1, &reference, &db, 1, vDSP_Length(halfSize), 1)
        return db
    }
}

/// Peak-hold-and-decay auto-gain for a spectrum: each frame the tracked
/// peak jumps up to the loudest bin at once or relaxes down one step, never
/// below a minimum, and the display window is `dynamicRangeDb` (divided by
/// a zoom factor) under the peak plus headroom. A fixed dB range guessed at
/// compile time only looks right for one input level — anything quieter
/// reads as empty, anything louder clips — while this keeps the full range
/// in use without flickering on ordinary level changes. The constants are
/// the Mac waterfall's, unchanged; the decay is per frame, so it assumes
/// roughly the Mac's ~21 frames a second.
public struct SpectrumAutoGain: Sendable {
    public static let dynamicRangeDb: Float = 45
    public static let headroomDb: Float = 3
    public static let peakDecayPerFrameDb: Float = 0.5
    public static let minimumPeakDb: Float = -70

    public private(set) var peakDb: Float = SpectrumAutoGain.minimumPeakDb

    public init() {}

    /// Folds in one frame's bins and returns the window to map them into.
    public mutating func update(db: [Float], zoom: Float = 1) -> (floorDb: Float, ceilingDb: Float) {
        var frameMaxDb = Self.minimumPeakDb
        if !db.isEmpty {
            vDSP_maxv(db, 1, &frameMaxDb, vDSP_Length(db.count))
        }
        peakDb = max(Self.minimumPeakDb, max(frameMaxDb, peakDb - Self.peakDecayPerFrameDb))
        let ceilingDb = peakDb + Self.headroomDb
        return (ceilingDb - Self.dynamicRangeDb / zoom, ceilingDb)
    }
}

/// The Filter Function Display's spectrum: the dB bins up to its fixed
/// 4 kHz span, clipped to a floor/ceiling window and normalized 0…1 —
/// what `FilterDisplayView` takes.
public enum FilterSpectrum {
    public static let spanHz: Double = 4000

    public static func normalized(db: [Float], floorDb: Float, ceilingDb: Float, binHz: Double) -> [Float] {
        let bins = min(db.count, Int(spanHz / binHz))
        guard bins > 0 else { return [] }
        var spectrum = [Float](repeating: 0, count: bins)
        var floorClip = floorDb
        var ceilingClip = ceilingDb
        vDSP_vclip(db, 1, &floorClip, &ceilingClip, &spectrum, 1, vDSP_Length(bins))
        var negFloor = -floorDb
        vDSP_vsadd(spectrum, 1, &negFloor, &spectrum, 1, vDSP_Length(bins))
        var invRange = 1 / max(ceilingDb - floorDb, 1e-6)
        vDSP_vsmul(spectrum, 1, &invRange, &spectrum, 1, vDSP_Length(bins))
        return spectrum
    }
}

import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics

/// Captures audio from the configured input device (see
/// `AudioInputSettings`), runs a real FFT on it, and turns each frame into
/// a scrolling color-mapped waterfall bitmap — newest row at the top. Owns
/// all the AVFoundation/Accelerate/CoreAudio/CoreGraphics code so nothing
/// DSP-related leaks into `HubService` or `WaterfallView`; it just hands
/// finished `CGImage` frames out via `onNewFrame`.
///
/// Mac-only — mirrors `RigctldProcessController`'s shape (owned by
/// `HubService`, independently started/stopped, reports out via a
/// closure) but for the audio-hardware side rather than the rig link.
final class AudioCaptureEngine {
    /// Always invoked on the main actor — `HubService` assigns straight
    /// into `@Published` state from inside it, same contract as
    /// `RigctldProcessController.onStateChange`.
    var onNewFrame: ((CGImage) -> Void)?

    private let fftSize = 2048
    private let binCount = 256
    private let historyRows = 150
    /// dB range mapped to the 0...1 intensity used for the color lookup.
    private let floorDb: Float = -80
    private let ceilingDb: Float = 0

    private let engine = AVAudioEngine()
    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length
    private var isRunning = false

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// `deviceUID` is `AudioInputSettings.deviceUID` — empty means "system
    /// default input", otherwise it's resolved back to a live
    /// `AudioDeviceID` via `AudioInputDeviceLister`. Safe to call again
    /// while already running (no-ops).
    func start(deviceUID: String) {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        engine.prepare()

        if !deviceUID.isEmpty, let deviceID = AudioInputDeviceLister.deviceID(forUID: deviceUID),
           let audioUnit = inputNode.audioUnit {
            var mutableDeviceID = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // Created fresh per start() and captured directly by the tap
        // closure below (not stored on self) — process(buffer:bitmap:)
        // runs on the tap's real-time audio thread, while start()/stop()
        // run on the main actor, so there's no property shared across
        // both that would need its own synchronization.
        let bitmap = WaterfallBitmap(binCount: binCount, historyRows: historyRows)

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer, bitmap: bitmap)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
        }
    }

    /// Idempotent — safe to call when not running (e.g. `HubService`
    /// calls this defensively on every path out of `.connected`).
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Windows, FFTs, and buckets one capture buffer into a `binCount`-wide
    /// row of 0...1 intensities, then hands it to `bitmap` and publishes
    /// the resulting frame. Runs entirely on the Core Audio real-time
    /// thread except the final `onNewFrame` hop.
    private func process(buffer: AVAudioPCMBuffer, bitmap: WaterfallBitmap) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var samples = [Float](repeating: 0, count: fftSize)
        let copyCount = min(frameCount, fftSize)
        samples.withUnsafeMutableBufferPointer { dest in
            dest.baseAddress!.update(from: channelData, count: copyCount)
        }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let halfSize = fftSize / 2
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
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Power -> dB (vDSP_vdbcon flag 1 = 10*log10, since zvmags already
        // produced squared-magnitude/power values, not amplitude).
        var reference: Float = 1
        var db = [Float](repeating: 0, count: halfSize)
        vDSP_vdbcon(magnitudes, 1, &reference, &db, 1, vDSP_Length(halfSize), 1)

        // Bucket the raw FFT bins down to binCount display columns, taking
        // each bucket's peak so brief narrow-band signals don't disappear
        // into an average.
        var row = [Float](repeating: 0, count: binCount)
        let binsPerBucket = max(1, halfSize / binCount)
        for i in 0..<binCount {
            let start = i * binsPerBucket
            let end = min(start + binsPerBucket, halfSize)
            guard start < end else { continue }
            var bucketMax: Float = -.infinity
            for j in start..<end { bucketMax = max(bucketMax, db[j]) }
            let clamped = max(floorDb, min(ceilingDb, bucketMax))
            row[i] = (clamped - floorDb) / (ceilingDb - floorDb)
        }

        guard let image = bitmap.appendRow(row) else { return }
        Task { @MainActor [weak self] in
            self?.onNewFrame?(image)
        }
    }
}

/// Keeps the last `historyRows` intensity rows and rebuilds a `CGImage`
/// from them on each new row — simpler and safer to get right without a
/// live hardware test than incrementally scrolling a persistent bitmap
/// context, at a cost (rebuilding ~binCount*historyRows pixels per frame)
/// that's trivial at this size and frame rate.
private final class WaterfallBitmap {
    private let binCount: Int
    private let historyRows: Int
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var rows: [[Float]] = []

    init(binCount: Int, historyRows: Int) {
        self.binCount = binCount
        self.historyRows = historyRows
    }

    /// `row` is `binCount` intensity values, 0...1. Prepends as the newest
    /// row (top of the image), dropping the oldest once full.
    func appendRow(_ row: [Float]) -> CGImage? {
        rows.insert(row, at: 0)
        if rows.count > historyRows {
            rows.removeLast(rows.count - historyRows)
        }

        var pixels = [UInt8](repeating: 0, count: binCount * historyRows * 4)
        for (rowIndex, intensities) in rows.enumerated() {
            let rowOffset = rowIndex * binCount * 4
            for col in 0..<binCount {
                let color = WaterfallPalette.color(forIntensity: intensities[col])
                let offset = rowOffset + col * 4
                pixels[offset] = color.r
                pixels[offset + 1] = color.g
                pixels[offset + 2] = color.b
                pixels[offset + 3] = 255
            }
        }

        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: binCount,
            height: historyRows,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: binCount * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// Fixed intensity -> color gradient (black, low signal, through blue/
/// cyan/green/yellow to red, strong signal) — literal RGB stops, matching
/// `SMeterView`'s convention of hardcoded colors rather than asset-catalog
/// or semantic ones.
private enum WaterfallPalette {
    private static let stops: [(threshold: Float, r: UInt8, g: UInt8, b: UInt8)] = [
        (0.00, 0, 0, 0),
        (0.25, 0, 0, 180),
        (0.50, 0, 180, 180),
        (0.75, 0, 220, 0),
        (0.90, 255, 220, 0),
        (1.00, 255, 40, 0),
    ]

    static func color(forIntensity value: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        let clamped = max(0, min(1, value))
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for (a, b) in zip(stops, stops.dropFirst()) where clamped <= b.threshold {
            lower = a
            upper = b
            break
        }
        let span = upper.threshold - lower.threshold
        let t = span > 0 ? (clamped - lower.threshold) / span : 0
        func lerp(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(Float(a) + (Float(b) - Float(a)) * t)
        }
        return (lerp(lower.r, upper.r), lerp(lower.g, upper.g), lerp(lower.b, upper.b))
    }
}

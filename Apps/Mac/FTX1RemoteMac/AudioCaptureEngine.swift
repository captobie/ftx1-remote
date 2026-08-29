import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation

/// One tap callback's worth of rendered display frames — always produced
/// together (both are cheap relative to the FFT itself), so the UI can
/// switch between waterfall/oscilloscope instantly with no capture restart.
struct AudioCaptureFrame {
    let waterfall: CGImage
    let oscilloscope: CGImage
}

/// Captures audio from the configured input device (see
/// `AudioInputSettings`), runs a real FFT on it, and turns each buffer into
/// a scrolling color-mapped waterfall bitmap (newest row at top) plus a
/// time-domain oscilloscope trace from the same raw samples. Owns all the
/// AVFoundation/Accelerate/CoreAudio/CoreGraphics code so nothing
/// DSP-related leaks into `HubService` or `ScopeDisplayView`; it just
/// hands finished `CGImage` frames out via `onNewFrame`.
///
/// Mac-only — mirrors `RigctldProcessController`'s shape (owned by
/// `HubService`, independently started/stopped, reports out via a
/// closure) but for the audio-hardware side rather than the rig link.
final class AudioCaptureEngine {
    /// Always invoked on the main actor — `HubService` assigns straight
    /// into `@Published` state from inside it, same contract as
    /// `RigctldProcessController.onStateChange`.
    var onNewFrame: ((AudioCaptureFrame) -> Void)?

    private let fftSize = 2048
    private let binCount = 256
    private let historyRows = 150

    // Auto-gain: both displays track a slowly-decaying peak of the
    // incoming signal and scale themselves to it each frame, rather than
    // assuming a fixed absolute level. A hardcoded dB/amplitude range
    // guessed at compile time (what this had originally) only looks right
    // for whatever input level happens to match the guess — anything
    // quieter reads as flat/empty, anything louder clips. Peak-hold-and-
    // decay (jump up instantly, relax back down gradually) keeps both
    // displays using their full visual range without flickering frame to
    // frame on ordinary level variation.
    private let waterfallDynamicRangeDb: Float = 45
    private let waterfallHeadroomDb: Float = 3
    private let waterfallPeakDecayPerFrameDb: Float = 0.5
    private let waterfallMinimumPeakDb: Float = -70
    private let oscilloscopeMinimumPeakAmplitude: Float = 0.02
    private let oscilloscopePeakDecayPerFrame: Float = 0.002

    private let engine = AVAudioEngine()
    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length
    private var isRunning = false
    /// The caller's most recent intent, set synchronously in `start()`/
    /// `stop()` — distinct from `isRunning` because granting microphone
    /// access is asynchronous (see `start(deviceUID:)`), so there's a
    /// window where a `stop()` can land before the engine has actually
    /// started. Checked when the permission callback finally fires so a
    /// disconnect during that window doesn't start capture anyway.
    private var shouldBeRunning = false

    // User-adjustable zoom, on top of the auto-gain baseline above — the
    // up/down arrows in ContentView drive these through HubService, which
    // owns the clamped step arithmetic (see `HubService.stepWaterfallZoom`/
    // `stepOscilloscopeZoom`). Lock-protected because it's set from the
    // main actor (button taps) and read every buffer from the audio
    // thread — unlike `WaterfallBitmap`/`AutoGainState`, which are
    // recreated per `start()` and only ever touched by the audio thread,
    // these live for the engine's whole lifetime so zoom survives a
    // disconnect/reconnect.
    private let waterfallZoom = LockedFloat(1.0)
    private let oscilloscopeZoom = LockedFloat(1.0)

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
    ///
    /// Explicitly resolves the microphone permission prompt first, via
    /// `AVCaptureDevice.requestAccess` — the very first connect after
    /// install is also the very first time this app ever touches the mic,
    /// and asking `AVAudioEngine` to start capturing while that system
    /// prompt is still pending just throws, silently, with no retry. That
    /// used to mean the display never activated on a first connect, only
    /// on a second one (by which point the user had already answered the
    /// prompt from the first attempt).
    func start(deviceUID: String) {
        guard !shouldBeRunning else { return }
        shouldBeRunning = true

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self, self.shouldBeRunning, granted else { return }
                self.beginCapture(deviceUID: deviceUID)
            }
        }
    }

    /// True once `engine` — a single instance reused for the app's whole
    /// lifetime, never recreated — has been started successfully at least
    /// once. Its very first `start()` is unreliable about actually
    /// delivering tap buffers (a known AVAudioEngine quirk, independent of
    /// device selection or permissions), which is what made the display
    /// never activate on a genuinely first connect while every connect
    /// after a disconnect — really just the engine's *second* start() —
    /// worked fine. See the warm-up cycle in `beginCapture`.
    private var hasStartedEngineBefore = false

    private func beginCapture(deviceUID: String) {
        guard !isRunning else { return }
        startEngine(deviceUID: deviceUID)
        guard isRunning, !hasStartedEngineBefore else { return }
        hasStartedEngineBefore = true

        // Silently do the "disconnect and reconnect" the user used to have
        // to do by hand: stop this first start immediately and start again
        // right away, so the engine's *second* start — the one that
        // reliably delivers buffers — happens automatically before the
        // user ever sees a dead display.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        startEngine(deviceUID: deviceUID)
    }

    private func startEngine(deviceUID: String) {
        let inputNode = engine.inputNode

        // Set before prepare()/start() — kAudioOutputUnitProperty_CurrentDevice
        // needs to land before the underlying audio unit is initialized;
        // setting it afterward risks being silently ignored, leaving
        // capture on the system default device instead of the one chosen
        // in Settings.
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

        engine.prepare()

        // Created fresh per startEngine() call and captured directly by
        // the tap closure below (not stored on self) —
        // process(buffer:bitmap:gain:) runs on the tap's real-time audio
        // thread, while start()/stop() run on the main actor, so there's
        // no property shared across both that would need its own
        // synchronization.
        let bitmap = WaterfallBitmap(binCount: binCount, historyRows: historyRows)
        let gain = AutoGainState(minimumPeakDb: waterfallMinimumPeakDb, minimumPeakAmplitude: oscilloscopeMinimumPeakAmplitude)

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer, bitmap: bitmap, gain: gain)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
        }
    }

    /// Both take an already-clamped multiplier — `HubService` owns the
    /// clamp range and per-click step size, this just stores the result
    /// for `process()` to pick up on the next buffer.
    func setWaterfallZoom(_ value: Float) {
        waterfallZoom.set(value)
    }

    func setOscilloscopeZoom(_ value: Float) {
        oscilloscopeZoom.set(value)
    }

    /// Idempotent — safe to call when not running (e.g. `HubService`
    /// calls this defensively on every path out of `.connected`), and
    /// safe to call while a permission decision is still pending from
    /// `start()` (clears `shouldBeRunning` so that callback becomes a
    /// no-op instead of starting capture after the fact).
    func stop() {
        shouldBeRunning = false
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Windows, FFTs, and buckets one capture buffer into a `binCount`-wide
    /// row of 0...1 intensities, then hands it to `bitmap` and publishes
    /// the resulting frame. Runs entirely on the Core Audio real-time
    /// thread except the final `onNewFrame` hop.
    private func process(buffer: AVAudioPCMBuffer, bitmap: WaterfallBitmap, gain: AutoGainState) {
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

        // Auto-gain: jump the tracked peak up to this frame's loudest bin
        // immediately, or let it decay down by one step — never below the
        // configured minimum, so near-silence doesn't drag the ceiling down
        // to the noise floor and light up the whole palette.
        let frameMaxDb = db.max() ?? waterfallMinimumPeakDb
        gain.peakDb = max(waterfallMinimumPeakDb, max(frameMaxDb, gain.peakDb - waterfallPeakDecayPerFrameDb))
        let ceilingDb = gain.peakDb + waterfallHeadroomDb
        // Manual zoom narrows (zoom in) or widens (zoom out) the dB span
        // mapped to the color gradient, on top of the auto-gain ceiling.
        let floorDb = ceilingDb - waterfallDynamicRangeDb / waterfallZoom.get()

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

        var maxAbsSample: Float = 0
        for sample in samples { maxAbsSample = max(maxAbsSample, abs(sample)) }
        gain.peakAmplitude = max(oscilloscopeMinimumPeakAmplitude, max(maxAbsSample, gain.peakAmplitude - oscilloscopePeakDecayPerFrame))

        guard let waterfallImage = bitmap.appendRow(row),
              let oscilloscopeImage = OscilloscopeRenderer.makeImage(
                  samples: samples, width: binCount, height: historyRows,
                  peakAmplitude: gain.peakAmplitude, zoom: oscilloscopeZoom.get()
              )
        else { return }
        let frame = AudioCaptureFrame(waterfall: waterfallImage, oscilloscope: oscilloscopeImage)
        Task { @MainActor [weak self] in
            self?.onNewFrame?(frame)
        }
    }
}

/// Peak-hold-and-decay auto-gain state, one instance per `start()` call,
/// captured directly by the tap closure alongside `WaterfallBitmap` — same
/// thread-ownership reasoning (mutated only on the audio thread, never
/// touched by `start()`/`stop()` after creation).
private final class AutoGainState {
    var peakDb: Float
    var peakAmplitude: Float

    init(minimumPeakDb: Float, minimumPeakAmplitude: Float) {
        peakDb = minimumPeakDb
        peakAmplitude = minimumPeakAmplitude
    }
}

/// Thread-safe holder for a value the main actor (`HubService`, on behalf
/// of the zoom arrow buttons) writes while `process()` reads it every
/// buffer on the audio thread — see `AudioCaptureEngine`'s `waterfallZoom`/
/// `oscilloscopeZoom` doc comment for why this needs locking where
/// `WaterfallBitmap`/`AutoGainState` don't. Updates are rare (button
/// taps) and reads are ~21Hz, so an uncontended lock is plenty.
private final class LockedFloat {
    private let lock = NSLock()
    private var value: Float

    init(_ value: Float) {
        self.value = value
    }

    func get() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Float) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
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

/// Renders one time-domain trace directly from a buffer's raw (unwindowed)
/// samples — classic green-on-black scope look, downsampled to `width`
/// columns by nearest-neighbor (no min/max peak detection — fine at this
/// buffer size/frame rate, and simpler). Stateless, unlike `WaterfallBitmap`
/// — an oscilloscope has no history to accumulate, each frame stands alone.
/// `peakAmplitude` (from `AutoGainState`) rescales the trace to use the
/// full vertical range regardless of the input's actual level, rather than
/// assuming it reaches full-scale ±1.0; `zoom` (from the up/down arrows,
/// via `HubService`) is a further user multiplier on top of that.
private enum OscilloscopeRenderer {
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let traceColor = CGColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1)

    static func makeImage(samples: [Float], width: Int, height: Int, peakAmplitude: Float, zoom: Float) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard samples.count > 1, width > 1 else { return context.makeImage() }

        context.setStrokeColor(traceColor)
        context.setLineWidth(1.5)
        context.beginPath()

        let midY = CGFloat(height) / 2
        let scale = CGFloat(zoom) / CGFloat(peakAmplitude)
        let step = Double(samples.count - 1) / Double(width - 1)
        for x in 0..<width {
            let sampleIndex = Int(Double(x) * step)
            let rawSample = CGFloat(samples[min(sampleIndex, samples.count - 1)])
            // Clamped rather than left to run off the box — the peak
            // estimate lags a sudden transient by up to one frame.
            let sample = max(-1, min(1, rawSample * scale))
            let point = CGPoint(x: CGFloat(x), y: midY - sample * midY)
            if x == 0 {
                context.move(to: point)
            } else {
                context.addLine(to: point)
            }
        }
        context.strokePath()
        return context.makeImage()
    }
}

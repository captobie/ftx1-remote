import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import os

/// One tap callback's worth of rendered display frames — always produced
/// together (both are cheap relative to the FFT itself), so the UI can
/// switch between waterfall/oscilloscope instantly with no capture restart.
struct AudioCaptureFrame {
    let waterfall: CGImage
    let oscilloscope: CGImage
    /// The FFT's dB bins covering 0…4000 Hz, normalized 0…1 through the
    /// same auto-gain floor/ceiling window the waterfall row uses, for
    /// the Filter Function Display's spectrum overlay (`FilterDisplayHost`
    /// → `FilterDisplayView`). Same scale as the waterfall by design so the
    /// two agree on what's loud.
    let spectrum: [Float]
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
    /// `nonisolated(unsafe)` on both closures below: this target builds
    /// with default MainActor isolation, but each is set exactly once by
    /// `HubService` at wiring time and never reassigned afterward — the
    /// same "write-once from the main actor, read from an audio-processing
    /// context thereafter" shape `waterfallZoom`/`oscilloscopeZoom` below
    /// use `Locked` for genuinely *mutable* state. A plain
    /// optional closure reference has no shared mutable state of its own
    /// to race on once set, so a lock would be pure overhead here — the
    /// actual dispatch into each closure's body still always hops via
    /// `Task { @MainActor in ... }` at the call site, honoring each one's
    /// documented "always invoked on the main actor" contract.
    ///
    /// Always invoked on the main actor — `HubService` assigns straight
    /// into `@Published` state from inside it, same contract as
    /// `RigctldProcessController.onStateChange`.
    nonisolated(unsafe) var onNewFrame: ((AudioCaptureFrame) -> Void)?

    /// The same raw samples `process(buffer:bitmap:gain:)` FFTs for
    /// display, handed out unmodified for `HubService`'s APRS decode path
    /// (`APRSDecoder` does real DSP work of its own — a bandpass/tone
    /// detector and bit-clock recovery, nothing like an FFT — so it needs
    /// the original samples, not anything derived from the waterfall
    /// pipeline). Always invoked on the main actor, same contract as
    /// `onNewFrame` — `HubService`'s conformance reads `rigState.
    /// frequencyHz` (main-actor-isolated) to decide whether to forward to
    /// `APRSDecoder` at all, so this can't be called directly from the
    /// real-time thread the way the doc comment on `process(buffer:
    /// bitmap:gain:)` describes for everything else in this class. The
    /// actual DSP work still stays off the main actor — `APRSDecoder.
    /// process(samples:sampleRate:)` just enqueues onto its own serial
    /// queue and returns immediately, so this hop only ever does a cheap
    /// frequency comparison, not real work.
    nonisolated(unsafe) var onAudioSamples: ((_ samples: [Float], _ sampleRate: Double) -> Void)?

    /// Sub (right channel) samples — fires in both `.local` (see `process
    /// (buffer:bitmap:gain:)`, when the selected input device delivers 2+
    /// channels) and `.remote` (see `beginRemoteCapture()`). A mono `.local`
    /// input device simply never triggers this — there's no separate
    /// "is Sub actually available" signal, callers just get nothing. Same
    /// "always invoked on the main actor" contract as `onAudioSamples`,
    /// same reasoning for why a plain optional closure needs no lock.
    /// Deliberately a separate closure rather than widening `onAudioSamples`
    /// to carry both channels: every existing `onAudioSamples` consumer
    /// (iPad relay, Mac playback, FT8, APRS) is Main-only by design for now
    /// (see repo CLAUDE.md, "Dual Main/Sub audio channels"), so this keeps
    /// that surface unchanged.
    nonisolated(unsafe) var onSubChannelSamples: ((_ samples: [Float], _ sampleRate: Double) -> Void)?

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
    /// `nonisolated(unsafe)` — read only from `process(buffer:bitmap:gain:)`
    /// / `process(samples:sampleRate:bitmap:gain:)`, which are themselves
    /// `nonisolated` (see their doc comments), never touched anywhere else
    /// after `init`. Safe without a lock: it's immutable once set, and
    /// `process()` never runs concurrently with itself (`.local`/`.remote`
    /// are mutually exclusive per launch — see `start(deviceUID:)`).
    nonisolated(unsafe) private let fftSetup: FFTSetup
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
    private let waterfallZoom = Locked<Float>(1.0)
    private let oscilloscopeZoom = Locked<Float>(1.0)
    /// Whether `process()` renders waterfall/oscilloscope frames at all —
    /// false while `ContentView`'s scope column is set to "Off". Before
    /// this existed, "Off" only made the view draw nothing; the FFT, the
    /// bitmap scroll, the oscilloscope stroke, and the ~21 Hz frame publish
    /// all kept running, so the setting saved no CPU (measured 2026-09-09).
    /// `onAudioSamples` is deliberately NOT gated by this — APRS decoding,
    /// Mac playback, and the iPad relay must keep flowing with the display
    /// off. Same lock/lifetime reasoning as the zooms above.
    private let displayEnabled = Locked<Bool>(true)

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
    /// while already running (no-ops). Only used in `.local` mode — see
    /// below.
    ///
    /// Explicitly resolves the microphone permission prompt first, via
    /// `AVCaptureDevice.requestAccess` — the very first connect after
    /// install is also the very first time this app ever touches the mic,
    /// and asking `AVAudioEngine` to start capturing while that system
    /// prompt is still pending just throws, silently, with no retry. That
    /// used to mean the display never activated on a first connect, only
    /// on a second one (by which point the user had already answered the
    /// prompt from the first attempt).
    ///
    /// In `RigctldSettings.ConnectionMode.remote`, there's no local
    /// hardware to ask permission for — the rig's audio-out is on the Pi's
    /// USB sound card instead (see `Pi/ftx1-audiostream.py`), reached over
    /// the network via `RemoteAudioStreamClient`. Both paths feed the same
    /// `process(samples:sampleRate:bitmap:gain:)`, so everything
    /// downstream (waterfall/oscilloscope, `onAudioSamples`) can't tell
    /// which one is active.
    func start(deviceUID: String) {
        guard !shouldBeRunning else { return }
        shouldBeRunning = true

        switch RigctldSettings.connectionMode {
        case .local:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.shouldBeRunning, granted else { return }
                    self.beginCapture(deviceUID: deviceUID)
                }
            }
        case .remote:
            beginRemoteCapture()
        }
    }

    private var remoteClient: RemoteAudioStreamClient?
    /// `nonisolated(unsafe)` — `Logger` is safe to use concurrently by
    /// design (that's the whole point of os.Logger), and this is read from
    /// both `beginRemoteCapture()`/`process(buffer:bitmap:gain:)` (main
    /// actor / the tap's real-time thread) and the `nonisolated`
    /// `logChannelDiagnostics(source:channelCount:main:sub:)` below.
    nonisolated(unsafe) private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "audio-capture")

    private func beginRemoteCapture() {
        Self.logger.notice("beginRemoteCapture() — host=\(RigctldSettings.remoteHost, privacy: .public)")
        let bitmap = WaterfallBitmap(binCount: binCount, historyRows: historyRows)
        let gain = AutoGainState(minimumPeakDb: waterfallMinimumPeakDb, minimumPeakAmplitude: oscilloscopeMinimumPeakAmplitude)
        // `RemoteAudioStreamClient` delivers genuinely separate Main (left)
        // and Sub (right) channels — see its own doc comment. `main` feeds
        // the same process(samples:sampleRate:bitmap:gain:) entry point the
        // local AVAudioEngine tap uses, so every existing downstream
        // consumer (waterfall, APRS, FT8, Mac-local playback, iPad relay)
        // keeps working unchanged. `sub` goes to `deliverSubChannelSamples`
        // — `HubService.onSubChannelSamples` feeds it to `subAudioPlayback`
        // and the independent `aprsDecoderSub` (see repo CLAUDE.md, "Dual
        // Main/Sub audio channels").
        let client = RemoteAudioStreamClient(host: RigctldSettings.remoteHost) { [weak self] main, sub, sampleRate in
            self?.process(samples: main, sampleRate: sampleRate, bitmap: bitmap, gain: gain)
            self?.deliverSubChannelSamples(sub, sampleRate: sampleRate)
            self?.logChannelDiagnostics(source: "remote", channelCount: 2, main: main, sub: sub)
        }
        remoteClient = client
        Task { await client.start() }
    }

    /// Mirrors the `onAudioSamples` hop inside `process(samples:...)` —
    /// Sub doesn't run through that shared entry point (it never feeds the
    /// waterfall/FFT), so it needs its own equivalent hand-off to the main
    /// actor.
    nonisolated private func deliverSubChannelSamples(_ samples: [Float], sampleRate: Double) {
        guard onSubChannelSamples != nil else { return }
        Task { @MainActor [weak self] in
            self?.onSubChannelSamples?(samples, sampleRate)
        }
    }

    private let channelDiagnosticsCounter = Locked<Int>(0)

    /// Confirms Main/Sub are genuinely independent, without any new UI —
    /// throttled to roughly once per 2s (chunks arrive at ~21.5/s for
    /// fftSize=2048 @ 44100Hz) so it doesn't flood Console. Check via
    /// Console.app, subsystem "com.ftx1remote.mac", category
    /// "audio-capture": during a dual-VFO test with different traffic on
    /// each side, the two RMS values should move independently, and should
    /// track a `swapActiveVFO` swap. Shared by both `.local` (`process
    /// (buffer:bitmap:gain:)`) and `.remote` (`beginRemoteCapture()`) —
    /// `channelCount`/`sub` are logged explicitly so a "no Sub audio"
    /// report can immediately tell "the input device isn't actually
    /// reporting stereo" (`channelCount` stays 1, `sub` is `nil`) apart
    /// from "capture is fine, something downstream of it is silent"
    /// (`channelCount` is 2 and the RMS values look sane).
    nonisolated private func logChannelDiagnostics(source: String, channelCount: Int, main: [Float], sub: [Float]?) {
        let count = channelDiagnosticsCounter.get() + 1
        channelDiagnosticsCounter.set(count)
        guard count % 43 == 0 else { return }
        let mainRMS = Self.rms(main)
        if let sub {
            let subRMS = Self.rms(sub)
            Self.logger.notice("stereo check (\(source, privacy: .public)) — channels=\(channelCount, privacy: .public) main RMS=\(mainRMS, format: .fixed(precision: 4)) sub RMS=\(subRMS, format: .fixed(precision: 4))")
        } else {
            Self.logger.notice("stereo check (\(source, privacy: .public)) — channels=\(channelCount, privacy: .public), no Sub (mono input device)")
        }
    }

    nonisolated private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrt(meanSquare)
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
        //
        // Diagnostic-only logging below (2026-09-18) — added while chasing
        // a real report of Sub always reading mono even with a confirmed-
        // stereo device selected in Settings: this pins down whether the
        // device resolved/the property set succeeded, separately from
        // whatever channel count the tap's buffer ends up reporting (see
        // `logChannelDiagnostics`). Check Console.app, subsystem
        // "com.ftx1remote.mac", category "audio-capture".
        if !deviceUID.isEmpty {
            if let deviceID = AudioInputDeviceLister.deviceID(forUID: deviceUID) {
                if let audioUnit = inputNode.audioUnit {
                    var mutableDeviceID = deviceID
                    let status = AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &mutableDeviceID,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                    Self.logger.notice("startEngine: resolved deviceUID to AudioDeviceID \(deviceID, privacy: .public), AudioUnitSetProperty(CurrentDevice) status=\(status, privacy: .public)")
                } else {
                    Self.logger.error("startEngine: resolved deviceUID to AudioDeviceID \(deviceID, privacy: .public) but inputNode.audioUnit was nil — device switch NOT applied")
                }
            } else {
                Self.logger.error("startEngine: deviceUID \(deviceUID, privacy: .public) did not resolve to any currently-enumerated device — staying on system default")
            }
        }

        engine.prepare()
        // `inputFormat(forBus: 0)` correctly tracks the device just
        // switched to above (2 channels, confirmed via the diagnostic
        // below on real hardware, 2026-09-18) — `outputFormat(forBus: 0)`
        // does not; it stays pinned to whatever channel count the engine's
        // graph was originally built with (the system default input's, 1
        // channel on this Mac), regardless of the CurrentDevice switch. A
        // known `AVAudioEngine` quirk: `installTap`'s `format: nil` binds
        // to the *output* side, so relying on it silently collapsed Sub
        // out of existence even though the raw hardware capture was
        // genuinely stereo the whole time. Passing the input-side format
        // explicitly is the fix — `AVAudioEngine` inserts its own internal
        // converter as needed, same as it would for any other explicit
        // tap format.
        let tapFormat = inputNode.inputFormat(forBus: 0)
        Self.logger.notice("startEngine: after prepare(), inputNode input format channels=\(tapFormat.channelCount, privacy: .public) (output side reports \(inputNode.outputFormat(forBus: 0).channelCount, privacy: .public) — installTap uses the input side explicitly, see above)")

        // Created fresh per startEngine() call and captured directly by
        // the tap closure below (not stored on self) —
        // process(buffer:bitmap:gain:) runs on the tap's real-time audio
        // thread, while start()/stop() run on the main actor, so there's
        // no property shared across both that would need its own
        // synchronization.
        let bitmap = WaterfallBitmap(binCount: binCount, historyRows: historyRows)
        let gain = AutoGainState(minimumPeakDb: waterfallMinimumPeakDb, minimumPeakAmplitude: oscilloscopeMinimumPeakAmplitude)

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: tapFormat) { [weak self] buffer, _ in
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

    /// See `displayEnabled`. Takes effect on the next buffer.
    func setDisplayEnabled(_ enabled: Bool) {
        displayEnabled.set(enabled)
    }

    /// Idempotent — safe to call when not running (e.g. `HubService`
    /// calls this defensively on every path out of `.connected`), and
    /// safe to call while a permission decision is still pending from
    /// `start()` (clears `shouldBeRunning` so that callback becomes a
    /// no-op instead of starting capture after the fact). Tears down
    /// whichever of the local tap / remote client is actually active —
    /// harmless to do both unconditionally since only one is ever set.
    func stop() {
        shouldBeRunning = false
        if let remoteClient {
            self.remoteClient = nil
            Task { await remoteClient.stop() }
        }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Windows, FFTs, and buckets one capture buffer into a `binCount`-wide
    /// row of 0...1 intensities, then hands it to `bitmap` and publishes
    /// the resulting frame. Runs entirely on the Core Audio real-time
    /// thread except the final `onNewFrame` hop.
    ///
    /// Also extracts channel 1 (Sub) when the tap's buffer format has 2+
    /// channels — the input device is whatever `AudioInputSettings.
    /// deviceUID` selects, and `startEngine(deviceUID:)` now installs the
    /// tap with that device's actual input-side format explicitly (not
    /// `format: nil` — see its doc comment for why that silently collapsed
    /// this to mono), so this is only ever true for a genuinely stereo
    /// device (confirmed stereo on the user's own "FTX-1 Audio" USB input,
    /// 2026-09-07 — see repo CLAUDE.md). A mono device just has
    /// `channelCount == 1` and Sub is skipped entirely, same as `.remote`
    /// mode against non-stereo hardware would be.
    nonisolated private func process(buffer: AVAudioPCMBuffer, bitmap: WaterfallBitmap, gain: AutoGainState) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var mainSamples = [Float](repeating: 0, count: frameCount)
        mainSamples.withUnsafeMutableBufferPointer { dest in
            dest.baseAddress!.update(from: channelData[0], count: frameCount)
        }

        var subSamples: [Float]?
        if buffer.format.channelCount >= 2 {
            var samples = [Float](repeating: 0, count: frameCount)
            samples.withUnsafeMutableBufferPointer { dest in
                dest.baseAddress!.update(from: channelData[1], count: frameCount)
            }
            deliverSubChannelSamples(samples, sampleRate: buffer.format.sampleRate)
            subSamples = samples
        }
        logChannelDiagnostics(source: "local", channelCount: Int(buffer.format.channelCount), main: mainSamples, sub: subSamples)

        process(samples: mainSamples, sampleRate: buffer.format.sampleRate, bitmap: bitmap, gain: gain)
    }

    /// The shared core both the local `AVAudioEngine` tap (via `process
    /// (buffer:bitmap:gain:)` above) and `RemoteAudioStreamClient`'s
    /// network-delivered chunks feed into — everything from here down has
    /// no idea whether `rawSamples` came from local hardware or the Pi.
    /// Runs off the main actor in both cases (the local tap's Core Audio
    /// real-time thread, or `RemoteAudioStreamClient`'s own actor), except
    /// the final `onNewFrame`/`onAudioSamples` hops.
    nonisolated private func process(samples rawSamples: [Float], sampleRate: Double, bitmap: WaterfallBitmap, gain: AutoGainState) {
        guard !rawSamples.isEmpty else { return }

        if onAudioSamples != nil {
            Task { @MainActor [weak self] in
                self?.onAudioSamples?(rawSamples, sampleRate)
            }
        }

        // Everything below exists only to produce display frames — skip the
        // lot while the scope is "Off" (see `displayEnabled`).
        guard displayEnabled.get() else { return }

        var samples = [Float](repeating: 0, count: fftSize)
        let copyCount = min(rawSamples.count, fftSize)
        samples.withUnsafeMutableBufferPointer { dest in
            rawSamples.withUnsafeBufferPointer { src in
                dest.baseAddress!.update(from: src.baseAddress!, count: copyCount)
            }
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

        // Filter-display spectrum: the raw bins up to 4 kHz (the display's
        // fixed span — ~186 bins at 44.1 kHz), clipped to the same
        // floor/ceiling window and normalized 0…1, all in vDSP so the
        // Debug build pays nothing per bin (see CLAUDE.md on -Onone).
        let spectrumBins = min(halfSize, Int(4000 / (sampleRate / Double(fftSize))))
        var spectrum = [Float](repeating: 0, count: spectrumBins)
        var floorClip = floorDb
        var ceilingClip = ceilingDb
        vDSP_vclip(db, 1, &floorClip, &ceilingClip, &spectrum, 1, vDSP_Length(spectrumBins))
        var negFloor = -floorDb
        vDSP_vsadd(spectrum, 1, &negFloor, &spectrum, 1, vDSP_Length(spectrumBins))
        var invRange = 1 / max(ceilingDb - floorDb, 1e-6)
        vDSP_vsmul(spectrum, 1, &invRange, &spectrum, 1, vDSP_Length(spectrumBins))

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
        vDSP_maxmgv(samples, 1, &maxAbsSample, vDSP_Length(fftSize))
        gain.peakAmplitude = max(oscilloscopeMinimumPeakAmplitude, max(maxAbsSample, gain.peakAmplitude - oscilloscopePeakDecayPerFrame))

        guard let waterfallImage = bitmap.appendRow(row),
              let oscilloscopeImage = OscilloscopeRenderer.makeImage(
                  samples: samples, width: binCount, height: historyRows,
                  peakAmplitude: gain.peakAmplitude, zoom: oscilloscopeZoom.get()
              )
        else { return }
        let frame = AudioCaptureFrame(waterfall: waterfallImage, oscilloscope: oscilloscopeImage, spectrum: spectrum)
        Task { @MainActor [weak self] in
            self?.onNewFrame?(frame)
        }
    }
}

/// Peak-hold-and-decay auto-gain state, one instance per `start()` call,
/// captured directly by the tap closure alongside `WaterfallBitmap` — same
/// thread-ownership reasoning (mutated only on the audio thread, never
/// touched by `start()`/`stop()` after creation). `nonisolated` throughout
/// to match `process()`'s own isolation (see its doc comment) — this type
/// exists purely to be read/written from that off-main-actor context, so
/// letting it default to the target's MainActor isolation would be
/// actively wrong, not just unnecessary.
private final class AutoGainState {
    nonisolated(unsafe) var peakDb: Float
    nonisolated(unsafe) var peakAmplitude: Float

    nonisolated init(minimumPeakDb: Float, minimumPeakAmplitude: Float) {
        peakDb = minimumPeakDb
        peakAmplitude = minimumPeakAmplitude
    }
}

/// Thread-safe holder for a value the main actor (`HubService`, on behalf
/// of the zoom arrow buttons / the scope Off switch) writes while
/// `process()` reads it every buffer on the audio thread — see
/// `AudioCaptureEngine`'s `waterfallZoom`/`oscilloscopeZoom` doc comment for
/// why this needs locking where `WaterfallBitmap`/`AutoGainState` don't.
/// Updates are rare (button taps) and reads are ~21Hz, so an uncontended
/// lock is plenty. `nonisolated` + `@unchecked Sendable`: the whole point
/// of this type is safe access from any isolation domain via its own lock,
/// not the target's default MainActor isolation.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value: Value

    nonisolated init(_ value: Value) {
        self.value = value
    }

    nonisolated func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    nonisolated func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

/// Keeps a persistent `binCount`×`historyRows` RGBA pixel buffer, newest
/// row at the top, and scrolls it down by one row per frame before writing
/// the new row in. This used to keep the last `historyRows` intensity rows
/// and re-color every pixel from scratch each frame — ~38,400 gradient
/// lookups per frame, ~825k/s at 21 fps — which was fine in a Release build
/// but measured (2026-09-09, `sample`) at ~0.75 of a core in a Debug build,
/// where each lookup's `zip`/`dropFirst` iteration went through unspecialized
/// generic iterators with a malloc/free per pixel. Now each frame is one
/// `memmove` plus `binCount` table lookups (see `WaterfallPalette.lut`).
private final class WaterfallBitmap {
    private let binCount: Int
    private let historyRows: Int
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    /// Packed RGBA8888, one `UInt32` per pixel, R in the lowest byte — the
    /// same byte order in memory (`r, g, b, a`) as `premultipliedLast`
    /// expects on this little-endian platform. Only ever touched from
    /// `appendRow` — see `AutoGainState`'s doc comment for the isolation
    /// reasoning.
    nonisolated(unsafe) private var pixels: [UInt32]

    nonisolated init(binCount: Int, historyRows: Int) {
        self.binCount = binCount
        self.historyRows = historyRows
        pixels = [UInt32](repeating: WaterfallPalette.lut[0], count: binCount * historyRows)
    }

    /// `row` is `binCount` intensity values, 0...1. Prepends as the newest
    /// row (top of the image), dropping the oldest once full. `nonisolated`
    /// to match `process()` — see `AutoGainState`'s doc comment for why.
    nonisolated func appendRow(_ row: [Float]) -> CGImage? {
        let rowPixels = binCount
        let shiftedPixels = rowPixels * (historyRows - 1)
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            // Overlapping move (row N -> row N+1 for every row) — memmove,
            // not memcpy, semantics are required here.
            memmove(base + rowPixels, base, shiftedPixels * MemoryLayout<UInt32>.size)
            for col in 0..<rowPixels {
                base[col] = WaterfallPalette.lut[WaterfallPalette.index(forIntensity: row[col])]
            }
        }

        // Copied, not wrapped — `pixels` is mutated again next frame, while
        // the CGImage handed out may still be on screen.
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
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
/// or semantic ones. Consumers go through `lut`/`index(forIntensity:)`, a
/// 256-step quantization of the gradient built once; `color(forIntensity:)`
/// is the exact definition that table is built from (see `WaterfallBitmap`
/// for why the per-pixel path no longer calls it directly).
private enum WaterfallPalette {
    /// 256 packed RGBA8888 pixels (R in the lowest byte, alpha 255), entry
    /// `i` being the gradient color at intensity `i / 255`.
    nonisolated(unsafe) static let lut: [UInt32] = (0..<256).map { step in
        let color = color(forIntensity: Float(step) / 255)
        return UInt32(color.r) | UInt32(color.g) << 8 | UInt32(color.b) << 16 | 0xFF00_0000
    }

    /// Clamps to 0...1 (so a NaN or out-of-range intensity can't index out
    /// of bounds) and rounds to the nearest of `lut`'s 256 steps.
    nonisolated static func index(forIntensity value: Float) -> Int {
        let clamped = max(0, min(1, value))
        return Int(clamped * 255 + 0.5)
    }

    nonisolated(unsafe) private static let stops: [(threshold: Float, r: UInt8, g: UInt8, b: UInt8)] = [
        (0.00, 0, 0, 0),
        (0.25, 0, 0, 180),
        (0.50, 0, 180, 180),
        (0.75, 0, 220, 0),
        (0.90, 255, 220, 0),
        (1.00, 255, 40, 0),
    ]

    nonisolated static func color(forIntensity value: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
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
    nonisolated(unsafe) private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    nonisolated(unsafe) private static let traceColor = CGColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1)

    nonisolated static func makeImage(samples: [Float], width: Int, height: Int, peakAmplitude: Float, zoom: Float) -> CGImage? {
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

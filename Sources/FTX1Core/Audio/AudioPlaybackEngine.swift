import AVFoundation
import Foundation
import os

/// Plays the Mac's relayed radio audio (see `AudioStreamFormat`/
/// `RigWebSocketClient.onAudioData`) with a user-adjustable volume and a
/// client-side "virtual" noise-gate squelch (`SquelchGate`) — entirely
/// independent of the rig's own hardware squelch. Lives in `FTX1Core`
/// rather than a single app target even though only the iPad wires up UI
/// for it today — same precedent as `RigWebSocketClient` sitting unused by
/// the Mac target: this plumbing is generic to "any WebSocket client," not
/// iPad-specific.
///
/// Compiles into the Mac target too via the shared package — `AVAudioSession`
/// doesn't exist there, hence the `#if os(iOS)` guards below.
public final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Exists purely as a gate: its `outputVolume` is snapped to 0/1 by
    /// `squelchGate`'s open/closed state, chained ahead of the engine's main
    /// mixer. The user's volume is handled separately via `player.volume` —
    /// no need for a second gain stage here.
    private let gateMixer = AVAudioMixerNode()

    private var squelchGate: SquelchGate
    private var converter: AVAudioConverter?
    private var playbackFormat: AVAudioFormat?
    private var isRunning = false
    /// Throttles the "push while not running" diagnostic below to once per
    /// not-running streak, rather than once per ~50ms audio chunk.
    private var hasLoggedPushWhileNotRunning = false

    /// Chunks accumulated before the very first `scheduleBuffer` call —
    /// absorbs ordinary network jitter so a real first-packet timing hiccup
    /// doesn't immediately stutter. A fixed warm-up, not a full adaptive
    /// jitter buffer: once primed, every later chunk is scheduled as it
    /// arrives.
    private var prebuffer: [AVAudioPCMBuffer] = []
    private var hasPrimed = false
    private let prebufferTargetSeconds: Double = 0.12

    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    public var squelchThreshold: Float {
        get { squelchGate.threshold }
        set { squelchGate.threshold = newValue }
    }

    /// When true, `squelchThreshold` is no longer settable from outside —
    /// `push(pcm:)` recomputes it every chunk from the live noise floor
    /// (see `SquelchGate.updateAutoThreshold`) and reports each change via
    /// `onAutoSquelchThresholdChange` instead.
    public var isAutoSquelch: Bool {
        get { squelchGate.isAutoEnabled }
        set { squelchGate.isAutoEnabled = newValue }
    }

    /// Fires with the newly-computed threshold on every `push(pcm:)` call
    /// while `isAutoSquelch` is on, so the UI slider can track it live.
    /// Invoked inline from `push(pcm:)` — never hops threads itself, so it
    /// lands on whatever the caller's own context is (both current callers
    /// already run `push(pcm:)` on the main actor, see their doc comments).
    /// Never fires for a manually-set threshold; that flows the other way
    /// (UI sets `squelchThreshold` directly).
    public var onAutoSquelchThresholdChange: ((Float) -> Void)?

    public init() {
        squelchGate = SquelchGate(threshold: Float(AudioPlaybackSettings.squelchThreshold))
        player.volume = Float(AudioPlaybackSettings.volume)
    }

    /// Idempotent — safe to call when already running. Builds the node
    /// graph against whatever format the engine's output actually wants
    /// right now (queried fresh each call, since the hardware output
    /// device/rate can differ between sessions) and passes that same
    /// explicit format to every `connect()` call in the chain. Relying on
    /// implicit format negotiation between an 8kHz mono wire buffer and
    /// whatever the main mixer happens to be running at is the likely
    /// source of audible clicks or an outright crash.
    public func start() {
        guard !isRunning else { return }

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            // Playback can still work without an explicit category on some
            // configurations — not worth failing start() over.
        }
        #endif

        let hardwareFormat = engine.outputNode.inputFormat(forBus: 0)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) ?? hardwareFormat
        playbackFormat = format

        engine.attach(player)
        engine.attach(gateMixer)
        engine.connect(player, to: gateMixer, format: format)
        engine.connect(gateMixer, to: engine.mainMixerNode, format: format)

        guard let wireFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioStreamFormat.sampleRate,
            channels: 1,
            interleaved: true
        ), let newConverter = AVAudioConverter(from: wireFormat, to: format) else { return }
        converter = newConverter

        prebuffer.removeAll()
        hasPrimed = false
        gateMixer.outputVolume = 0

        do {
            try engine.start()
            player.play()
            isRunning = true
            Self.logger.notice("started, playbackFormat sampleRate=\(format.sampleRate, privacy: .public)")
        } catch {
            // This used to fail completely silently — no log, no error
            // surfaced to the caller — which made "isRunning stays false,
            // every later push(pcm:) silently no-ops" indistinguishable
            // from "actually playing, just squelched" from the outside.
            Self.logger.error("engine.start() failed: \(String(describing: error), privacy: .public)")
            engine.disconnectNodeInput(player)
            engine.disconnectNodeInput(gateMixer)
        }
    }

    private static let logger = Logger(subsystem: "com.ftx1remote", category: "audio-playback")

    /// Fully tears the engine down rather than just pausing the player —
    /// leaving it running across a disconnect risks double-scheduling
    /// buffers (and hearing the previous session's tail) on the next
    /// `start()`.
    public func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        engine.disconnectNodeInput(player)
        engine.disconnectNodeInput(gateMixer)
        converter = nil
        playbackFormat = nil
        prebuffer.removeAll()
        hasPrimed = false
        isRunning = false

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// One chunk of raw Int16 mono PCM at `AudioStreamFormat.sampleRate`, as
    /// delivered by `RigWebSocketClient.onAudioData` (tag byte already
    /// stripped). Converts to the engine's playback format, updates the
    /// squelch gate from this chunk's RMS level, and schedules it — after a
    /// small warm-up window is buffered on the very first chunks.
    public func push(pcm: Data) {
        guard isRunning, let converter, let playbackFormat else {
            if !hasLoggedPushWhileNotRunning {
                hasLoggedPushWhileNotRunning = true
                Self.logger.error("push(pcm:) called while not running (isRunning=\(self.isRunning, privacy: .public)) — every push silently no-ops until start() succeeds")
            }
            return
        }
        hasLoggedPushWhileNotRunning = false
        guard let buffer = convert(pcm: pcm, converter: converter, format: playbackFormat) else {
            Self.logger.error("convert(pcm:) failed for a \(pcm.count, privacy: .public)-byte chunk")
            return
        }

        let rms = SquelchGate.rms(ofInt16Bytes: pcm)
        let isOpen = squelchGate.update(rms: rms)
        gateMixer.outputVolume = isOpen ? 1 : 0
        if squelchGate.isAutoEnabled {
            onAutoSquelchThresholdChange?(squelchGate.threshold)
        }

        pushLogCounter += 1
        if pushLogCounter % 40 == 0 {
            // Roughly every ~2s at typical chunk sizes — confirms buffers
            // are actually being scheduled, and whether the squelch gate
            // (which can silence output even while everything else is
            // working correctly) is open or closed, without logging every
            // single chunk.
            Self.logger.notice("push: rms=\(rms, privacy: .public) threshold=\(self.squelchGate.threshold, privacy: .public) gateOpen=\(isOpen, privacy: .public) volume=\(self.player.volume, privacy: .public) engineRunning=\(self.engine.isRunning, privacy: .public)")
        }

        guard hasPrimed else {
            prebuffer.append(buffer)
            let bufferedSeconds = prebuffer.reduce(0.0) { $0 + Double($1.frameLength) / playbackFormat.sampleRate }
            guard bufferedSeconds >= prebufferTargetSeconds else { return }
            for buffered in prebuffer {
                player.scheduleBuffer(buffered)
            }
            prebuffer.removeAll()
            hasPrimed = true
            return
        }

        player.scheduleBuffer(buffer)
    }

    private var pushLogCounter = 0

    private func convert(pcm: Data, converter: AVAudioConverter, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            inputBuffer.int16ChannelData?[0].update(from: src, count: frameCount)
        }

        // Generous headroom over the naive ratio — the converter can emit a
        // few extra frames around a resample boundary; undersizing the
        // output buffer truncates audio rather than erroring.
        let estimatedOutputFrames = Int(Double(frameCount) * format.sampleRate / AudioStreamFormat.sampleRate) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(estimatedOutputFrames)) else { return nil }

        // One-shot conversion: hand the converter the whole input buffer
        // exactly once, then tell it there's nothing more this call.
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }
}

#if os(iOS)
import AVFoundation
import os

/// The device microphone as transmit audio: an `AVAudioEngine` input tap,
/// downsampled to the relay's 8 kHz Int16 mono (`AudioStreamFormat`) by a
/// `PiAudioDownsampler` (one long-lived converter, so its filter state
/// carries over chunk boundaries), handed to `onChunk` about every 20 ms.
/// Runs only while PTT is held — `start()` on press, `stop()` on release.
///
/// The session is `.playAndRecord` only while this runs: `start()` switches
/// to it and `stop()` deactivates it, and the models stop their receive
/// `AudioPlaybackEngine`s for the length of a press (receive audio is muted
/// while keyed anyway, so the rig's monitor audio can't feed back into
/// the mic) and restart them — back on `.playback` — afterwards. Listening
/// never runs on a record-capable session. A Simulator connect deadlocked
/// in CoreAudio when it did, and it would also move the route and show
/// the mic indicator for no reason.
///
/// No echo cancellation (`.voiceChat` would also duck and reroute audio);
/// muting the receive side covers what it would be for.
///
/// `@unchecked Sendable`: `start()`/`stop()` come from the main actor; the
/// tap runs on the audio thread and touches only the downsampler and
/// `onChunk`, both fixed at init.
public final class TXAudioCapture: @unchecked Sendable {
    public enum CaptureError: Error {
        case noInput
    }

    private let engine = AVAudioEngine()
    private let downsampler = PiAudioDownsampler()
    private let onChunk: @Sendable (Data) -> Void
    private let logger: Logger
    private var isRunning = false

    public init(logSubsystem: String, onChunk: @escaping @Sendable (Data) -> Void) {
        self.onChunk = onChunk
        logger = Logger(subsystem: logSubsystem, category: "tx-audio")
    }

    /// Asks the first time; afterwards answers at once.
    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    public func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        let input = engine.inputNode
        // On iOS the tap has to use the node's output format (the macOS
        // `inputFormat` workaround in AudioCaptureEngine doesn't apply).
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        let sampleRate = format.sampleRate
        let downsampler = downsampler
        let onChunk = onChunk
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let pcm = downsampler.convert(samples, sourceRate: sampleRate)
            if !pcm.isEmpty { onChunk(pcm) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        logger.notice("microphone started at \(sampleRate, privacy: .public) Hz")
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        // The receive engines' next start() puts the category back.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        logger.notice("microphone stopped")
    }
}
#endif

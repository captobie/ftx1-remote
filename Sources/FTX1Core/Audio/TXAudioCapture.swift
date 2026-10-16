#if os(iOS)
import AVFoundation
import os

/// The device microphone as transmit audio: an `AVAudioEngine` input tap,
/// downsampled to the relay's 8 kHz Int16 mono (`AudioStreamFormat`) by a
/// `PiAudioDownsampler` (one long-lived converter, so its filter state
/// carries over chunk boundaries), handed to `onChunk` about every 20 ms.
/// Runs only while PTT is held — `start()` on press, `stop()` on release.
///
/// The session is `SharedAudioSession`'s `.playAndRecord`, already active
/// while receive plays, so a press only starts this input engine — no
/// category switch and no stopping the receive players (the models mute
/// them while keyed, so the rig's monitor audio can't feed back into the
/// mic). Starting and stopping run on this capture's own serial queue,
/// never the main thread: on a real iPad Air the old main-thread version
/// froze the UI for ~4 s per press (see `SharedAudioSession`).
///
/// No echo cancellation (`.voiceChat` would also duck and reroute audio);
/// muting the receive side covers what it would be for.
///
/// `@unchecked Sendable`: the engine and `isRunning` are touched only on
/// `queue` (`start()` and `stop()` both hop there, in call order, so a
/// stop right after a start runs after it); the tap runs on the audio
/// thread and touches only the downsampler and `onChunk`, both fixed at
/// init.
public final class TXAudioCapture: @unchecked Sendable {
    public enum CaptureError: Error {
        case noInput
    }

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.ftx1remote.tx-audio-capture", qos: .userInitiated)
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

    /// Starts the microphone on `queue`; returns once it runs (or throws).
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the microphone on `queue`, after any start already queued.
    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func startOnQueue() throws {
        guard !isRunning else { return }
        try SharedAudioSession.acquire()

        let input = engine.inputNode
        // On iOS the tap has to use the node's output format (the macOS
        // `inputFormat` workaround in AudioCaptureEngine doesn't apply).
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            SharedAudioSession.release()
            throw CaptureError.noInput
        }
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
            SharedAudioSession.release()
            throw error
        }
        isRunning = true
        logger.notice("microphone started at \(sampleRate, privacy: .public) Hz")
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        // Receive keeps the session if it's playing; the last user
        // deactivates it.
        SharedAudioSession.release()
        logger.notice("microphone stopped")
    }
}
#endif

#if os(iOS)
import Foundation

/// Hold-to-talk plumbing shared by the iPad's two routes
/// (`RigClientViewModel`, `PiDirectViewModel`): runs a `TXAudioCapture`
/// and hands its chunks, strictly in order, to one async sink (the
/// WebSocket or the Pi's TX audio connection). Separate `Task`s per chunk
/// could reorder them, hence the `AsyncStream` and one consumer.
///
/// Keying itself stays with the models: they key before `start` and unkey
/// `unkeyDelay` after `stop`, so the tail of the last word still in
/// flight (network + the far end's ~120 ms prebuffer) isn't cut off.
@MainActor
public final class MicrophoneTransmitter {
    public static let unkeyDelay: Duration = .milliseconds(300)

    private let logSubsystem: String
    private var capture: TXAudioCapture?
    private var continuation: AsyncStream<Data>.Continuation?
    private var consumer: Task<Void, Never>?

    public init(logSubsystem: String) {
        self.logSubsystem = logSubsystem
    }

    public var isRunning: Bool { capture != nil }

    /// Throws if the microphone can't start; nothing is left running then.
    /// `finish` runs once after the last chunk has been sunk.
    public func start(
        sink: @escaping @Sendable (Data) async -> Void,
        finish: @escaping @Sendable () async -> Void = {}
    ) throws {
        stop()
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(50))
        let capture = TXAudioCapture(logSubsystem: logSubsystem) { pcm in
            continuation.yield(pcm)
        }
        try capture.start()
        self.capture = capture
        self.continuation = continuation
        consumer = Task {
            for await pcm in stream {
                await sink(pcm)
            }
            await finish()
        }
    }

    /// Stops the microphone; chunks already captured are still sunk.
    public func stop() {
        capture?.stop()
        capture = nil
        continuation?.finish()
        continuation = nil
        consumer = nil
    }
}
#endif

import Combine
import Foundation
import FTX1Core

/// The decoders' MyKiwiSDR source ("Local SDR" in code): the MyKiwiSDR
/// window's decoded Kiwi audio, handed straight from `LocalSDRModel` (the
/// window's own `@StateObject`) to the CW and RTTY/PSK receivers on
/// `HubService`. Unlike the WebSDR source there's no page output to tap —
/// the samples come from the client before the window's volume and mute,
/// at the rate the Kiwi reports (~11998.9 Hz; both decoders resample).
///
/// Consumers register like `WebSDRAudioSource`'s (`isWanted`, `onSamples`)
/// and call `update()` when their answer may have changed. The producer
/// (the window's model) checks `isWanted` before converting each frame, so
/// nothing is done per frame while no decoder listens. Nothing per frame is
/// published: `status` changes only on transitions, `mode` on a tune.
///
/// Never connects anything: picking the source in a decoder window while
/// the MyKiwiSDR window is closed or disconnected just shows
/// `.notConnected`.
final class LocalSDRAudioSource: ObservableObject {
    enum Status: Equatable {
        /// No MyKiwiSDR session (window closed, or not connected yet).
        case notConnected
        case receiving
        /// Connected, but next to nothing arriving for a while.
        case silent
    }

    @Published private(set) var status = Status.notConnected
    /// The Kiwi's demodulation as a rig mode while connected, nil otherwise.
    @Published private(set) var mode: RigMode?

    private struct Consumer {
        let isWanted: @MainActor () -> Bool
        let onSamples: @MainActor ([Float], Double) -> Void
    }

    private var consumers: [String: Consumer] = [:]
    private var sampleRate: Double?
    /// Silence: below −80 dBFS for 3 s, as the WebSDR source's.
    private var quietSince: Date?
    private static let silenceThreshold: Float = 1e-4
    private static let silenceDuration: TimeInterval = 3

    func addConsumer(
        id: String,
        isWanted: @escaping @MainActor () -> Bool,
        onSamples: @escaping @MainActor ([Float], Double) -> Void
    ) {
        consumers[id] = Consumer(isWanted: isWanted, onSamples: onSamples)
        update()
    }

    /// Whether any decoder is listening — the producer skips its per-frame
    /// work while none is.
    private(set) var isWanted = false

    func update() {
        let wanted = consumers.values.contains { $0.isWanted() }
        // Silence is only tracked while frames are delivered.
        if wanted, !isWanted { quietSince = nil }
        isWanted = wanted
    }

    // MARK: - Producer (LocalSDRModel)

    /// The Kiwi's audio is ready at `sampleRate`.
    func sessionStarted(sampleRate: Double, mode: KiwiSDRMode) {
        self.sampleRate = sampleRate
        quietSince = nil
        setStatus(.receiving)
        modeChanged(mode)
    }

    func modeChanged(_ kiwiMode: KiwiSDRMode) {
        guard sampleRate != nil else { return }
        let rigMode = kiwiMode.rigMode
        if mode != rigMode { mode = rigMode }
    }

    /// Disconnect, a dropped connection, or the window closing.
    func sessionEnded() {
        sampleRate = nil
        quietSince = nil
        setStatus(.notConnected)
        if mode != nil { mode = nil }
    }

    /// One Kiwi frame, before volume/mute. Call only while `isWanted`.
    func deliver(_ pcm: [Int16]) {
        guard let sampleRate, !pcm.isEmpty else { return }
        let samples = pcm.map { Float($0) / 32768 }
        trackSilence(samples)
        for consumer in consumers.values where consumer.isWanted() {
            consumer.onSamples(samples, sampleRate)
        }
    }

    private func trackSilence(_ samples: [Float]) {
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        if peak > Self.silenceThreshold {
            quietSince = nil
            setStatus(.receiving)
        } else {
            let now = Date()
            if let quietSince {
                if now.timeIntervalSince(quietSince) >= Self.silenceDuration { setStatus(.silent) }
            } else {
                quietSince = now
            }
        }
    }

    private func setStatus(_ new: Status) {
        if status != new { status = new }
    }
}

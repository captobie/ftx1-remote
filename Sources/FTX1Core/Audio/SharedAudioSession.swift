#if os(iOS)
import AVFoundation
import os

/// The one `AVAudioSession` setup every receive player (`AudioPlaybackEngine`)
/// and the transmit microphone (`TXAudioCapture`) share: `.playAndRecord`
/// to the speaker (or A2DP), active while any of them runs, deactivated
/// once the last one stops.
///
/// Why one mode for both (2026-10-16): the players used `.playback` and
/// the microphone switched to `.playAndRecord` for each press, which meant
/// stopping both players first. On a real iPad Air (4th gen) every stop
/// deactivated the session under the other player's running I/O (~1 s
/// each), the switch and the mic start took another second, and the
/// release did it all in reverse — a 3.9 s main-thread hang per press, so a
/// short press was released before the mic ever ran and sent no audio
/// (found with `log collect` from the iPad; the Simulator does all of this
/// in milliseconds). With the session already `.playAndRecord`, a press
/// only starts the input engine, and receive keeps running (the models
/// mute it while keyed). iOS shows the microphone indicator only while
/// input actually runs, not for the category.
///
/// Thread-safe: players call it from the main actor, `TXAudioCapture` from
/// its own queue.
public enum SharedAudioSession {
    private static let lock = OSAllocatedUnfairLock(initialState: 0)
    private static let logger = Logger(subsystem: "com.ftx1remote", category: "audio-session")

    /// One more user; configures and activates the session for the first.
    public static func acquire() throws {
        try lock.withLock { users in
            if users == 0 {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true)
                logger.notice("session active (playAndRecord)")
            }
            users += 1
        }
    }

    /// One fewer; the last one deactivates, so other apps' audio resumes.
    public static func release() {
        lock.withLock { users in
            guard users > 0 else { return }
            users -= 1
            if users == 0 {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                logger.notice("session inactive")
            }
        }
    }
}
#endif

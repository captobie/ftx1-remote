import Foundation

/// Per-device iPad audio-playback settings (volume + virtual-squelch
/// threshold) — `UserDefaults`-backed directly rather than `@AppStorage`,
/// same pattern as `AppearanceSettings`, so the non-View `AudioPlaybackEngine`
/// can read it too. Never synced between devices.
public enum AudioPlaybackSettings {
    public static let volumeKey = "audio.playback.volume"
    public static let squelchThresholdKey = "audio.playback.squelchThreshold"
    public static let isMutedKey = "audio.playback.isMuted"

    public static var volume: Double {
        get {
            (UserDefaults.standard.object(forKey: volumeKey) as? Double) ?? 0.8
        }
        set {
            UserDefaults.standard.set(newValue, forKey: volumeKey)
        }
    }

    public static var squelchThreshold: Double {
        get {
            (UserDefaults.standard.object(forKey: squelchThresholdKey) as? Double) ?? 0.02
        }
        set {
            UserDefaults.standard.set(newValue, forKey: squelchThresholdKey)
        }
    }

    public static var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: isMutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: isMutedKey) }
    }
}

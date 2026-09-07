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

    /// See `SquelchGate`'s doc comment — this is now the RMS level at or
    /// below which a chunk counts as a genuine "quieting" dip, not a level
    /// that must be exceeded. 0.015 is a starting guess (comfortably above
    /// the ~0.001-0.003 quiet dips and comfortably below the ~0.06 static
    /// floor seen in the 2026-09-08 hardware capture this design is based
    /// on) pending further real-traffic tuning.
    public static var squelchThreshold: Double {
        get {
            (UserDefaults.standard.object(forKey: squelchThresholdKey) as? Double) ?? 0.015
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

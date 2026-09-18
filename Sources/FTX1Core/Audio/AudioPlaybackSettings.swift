import Foundation

/// Per-device audio-playback settings (volume + virtual-squelch threshold)
/// — `UserDefaults`-backed directly rather than `@AppStorage`, same pattern
/// as `AppearanceSettings`, so the non-View `AudioPlaybackEngine` can read
/// it too. Never synced between devices.
///
/// The un-prefixed `volume`/`squelchThreshold`/`isMuted` below are the
/// Main-channel settings — the only ones that existed before Main/Sub
/// stereo capture (2026-09-18, see repo CLAUDE.md), and still the only ones
/// iPad has UI for (its audio relay is Main-only). `subVolume`/
/// `subSquelchThreshold`/`subIsMuted` are new, Mac-only-for-now (Remote
/// mode only — see `HubService`).
public enum AudioPlaybackSettings {
    public static let volumeKey = "audio.playback.volume"
    public static let squelchThresholdKey = "audio.playback.squelchThreshold"
    public static let isMutedKey = "audio.playback.isMuted"
    public static let subVolumeKey = "audio.playback.sub.volume"
    public static let subSquelchThresholdKey = "audio.playback.sub.squelchThreshold"
    public static let subIsMutedKey = "audio.playback.sub.isMuted"

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

    /// Same defaults as the Main-channel settings above — no evidence yet
    /// that Sub audio needs different starting points, and keeping them
    /// identical makes an unexpectedly-quiet Sub slider less surprising on
    /// first use.
    public static var subVolume: Double {
        get {
            (UserDefaults.standard.object(forKey: subVolumeKey) as? Double) ?? 0.8
        }
        set {
            UserDefaults.standard.set(newValue, forKey: subVolumeKey)
        }
    }

    public static var subSquelchThreshold: Double {
        get {
            (UserDefaults.standard.object(forKey: subSquelchThresholdKey) as? Double) ?? 0.015
        }
        set {
            UserDefaults.standard.set(newValue, forKey: subSquelchThresholdKey)
        }
    }

    public static var subIsMuted: Bool {
        get { UserDefaults.standard.bool(forKey: subIsMutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: subIsMutedKey) }
    }
}

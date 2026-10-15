import Foundation

/// Configuration for the optional WPSD (Pi-Star-family hotspot dashboard)
/// callsign lookup, backed by `UserDefaults` directly rather than
/// `@AppStorage` — same pattern as `RigctldSettings`/`AudioInputSettings`,
/// so `HubService` (not a SwiftUI `View`) can read these too.
public enum WPSDSettings {
    public static let enabledKey = "wpsd.enabled"
    public static let hostKey = "wpsd.host"

    public static var enabled: Bool {
        get { SettingsStore.defaults.bool(forKey: enabledKey) }
        set { SettingsStore.defaults.set(newValue, forKey: enabledKey) }
    }

    /// Hotspot address (IP or hostname, optionally with a port), e.g.
    /// "192.168.1.50". Empty means "not configured" — lookup stays disabled
    /// regardless of `enabled` until a host is set.
    public static var host: String {
        get { SettingsStore.defaults.string(forKey: hostKey) ?? "" }
        set { SettingsStore.defaults.set(newValue, forKey: hostKey) }
    }
}

import Foundation

/// Configuration for the optional WPSD (Pi-Star-family hotspot dashboard)
/// callsign lookup, backed by `UserDefaults` directly rather than
/// `@AppStorage` — same pattern as `RigctldSettings`/`AudioInputSettings`,
/// so `HubService` (not a SwiftUI `View`) can read these too.
enum WPSDSettings {
    static let enabledKey = "wpsd.enabled"
    static let hostKey = "wpsd.host"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Hotspot address (IP or hostname, optionally with a port), e.g.
    /// "192.168.1.50". Empty means "not configured" — lookup stays disabled
    /// regardless of `enabled` until a host is set.
    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }
}

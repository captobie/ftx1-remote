import Foundation

/// The operator's own callsign and Maidenhead grid square — backed by
/// `UserDefaults` directly rather than `@AppStorage`, same pattern as
/// `AppearanceSettings`/`APRSSettings`, so non-`View` code (`FT8Spot`
/// construction in `HubService`) can read it too. Lives in `FTX1Core`
/// rather than a single app target on the same reasoning as
/// `AppearanceSettings`: any future app target that identifies the
/// operator needs the same values.
///
/// The Mac's PSK Reporter upload reports as this callsign/grid and won't
/// run while either is empty. The values aren't validated against real
/// callsign/grid syntax here; garbage in just means a garbage report.
public enum StationSettings {
    public static let callsignKey = "station.callsign"
    public static let gridSquareKey = "station.gridSquare"

    public static var callsign: String {
        get { SettingsStore.defaults.string(forKey: callsignKey) ?? "" }
        set { SettingsStore.defaults.set(newValue, forKey: callsignKey) }
    }

    public static var gridSquare: String {
        get { SettingsStore.defaults.string(forKey: gridSquareKey) ?? "" }
        set { SettingsStore.defaults.set(newValue, forKey: gridSquareKey) }
    }
}

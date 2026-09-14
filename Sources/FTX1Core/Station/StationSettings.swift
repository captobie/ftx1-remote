import Foundation

/// The operator's own callsign and Maidenhead grid square — backed by
/// `UserDefaults` directly rather than `@AppStorage`, same pattern as
/// `AppearanceSettings`/`APRSSettings`, so non-`View` code (`FT8Spot`
/// construction in `HubService`) can read it too. Lives in `FTX1Core`
/// rather than a single app target on the same reasoning as
/// `AppearanceSettings`: any future app target that identifies the
/// operator (a PSK Reporter uploader, most immediately) needs the same
/// values.
///
/// Nothing read this before FT8 needed a "my callsign/grid" to stamp onto
/// each `FT8Spot` for a future PSK Reporter upload — the values aren't
/// validated against real callsign/grid syntax here; garbage in just means
/// a garbage report later, same as leaving the field blank.
public enum StationSettings {
    public static let callsignKey = "station.callsign"
    public static let gridSquareKey = "station.gridSquare"

    public static var callsign: String {
        get { UserDefaults.standard.string(forKey: callsignKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: callsignKey) }
    }

    public static var gridSquare: String {
        get { UserDefaults.standard.string(forKey: gridSquareKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: gridSquareKey) }
    }
}

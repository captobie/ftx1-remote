import Foundation

/// Configuration for APRS decoding — backed by `UserDefaults` directly
/// rather than `@AppStorage`, same pattern as `WPSDSettings`, so
/// `HubService` (not a SwiftUI `View`) can read these too.
public enum APRSSettings {
    public static let enabledKey = "aprs.enabled"
    public static let frequencyHzKey = "aprs.frequencyHz"
    public static let toleranceHzKey = "aprs.toleranceHz"
    public static let maxStationsKey = "aprs.maxStations"
    public static let maxMessagesKey = "aprs.maxMessages"

    /// US APRS calling frequency — the sensible default; other regions
    /// (144.800 MHz EU, etc.) just edit this in Settings.
    public static let defaultFrequencyHz = 144_390_000
    public static let defaultToleranceHz = 5_000
    public static let defaultMaxStations = 1_000
    public static let defaultMaxMessages = 1_000

    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static var frequencyHz: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: frequencyHzKey)
            return value == 0 ? defaultFrequencyHz : value
        }
        set { UserDefaults.standard.set(newValue, forKey: frequencyHzKey) }
    }

    public static var toleranceHz: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: toleranceHzKey)
            return value == 0 ? defaultToleranceHz : value
        }
        set { UserDefaults.standard.set(newValue, forKey: toleranceHzKey) }
    }

    /// How many distinct stations/messages `APRSStore` keeps before
    /// evicting the least-recently-heard/oldest — unbounded growth would
    /// otherwise slowly bloat the persisted history file forever. Guards
    /// against a stray 0/negative value (e.g. an emptied Settings field)
    /// falling back to the default rather than evicting everything.
    public static var maxStations: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: maxStationsKey)
            return value > 0 ? value : defaultMaxStations
        }
        set { UserDefaults.standard.set(newValue, forKey: maxStationsKey) }
    }

    public static var maxMessages: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: maxMessagesKey)
            return value > 0 ? value : defaultMaxMessages
        }
        set { UserDefaults.standard.set(newValue, forKey: maxMessagesKey) }
    }

    /// Whether decoding should be active for the given VFO frequency —
    /// enabled and within `toleranceHz` of the configured APRS frequency.
    public static func isActive(atFrequencyHz frequencyHz: Int) -> Bool {
        enabled && abs(frequencyHz - Self.frequencyHz) <= toleranceHz
    }
}

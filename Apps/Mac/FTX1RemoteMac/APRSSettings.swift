import Foundation

/// Configuration for APRS decoding — backed by `UserDefaults` directly
/// rather than `@AppStorage`, same pattern as `WPSDSettings`, so
/// `HubService` (not a SwiftUI `View`) can read these too.
enum APRSSettings {
    static let enabledKey = "aprs.enabled"
    static let frequencyHzKey = "aprs.frequencyHz"
    static let toleranceHzKey = "aprs.toleranceHz"

    /// US APRS calling frequency — the sensible default; other regions
    /// (144.800 MHz EU, etc.) just edit this in Settings.
    static let defaultFrequencyHz = 144_390_000
    static let defaultToleranceHz = 5_000

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var frequencyHz: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: frequencyHzKey)
            return value == 0 ? defaultFrequencyHz : value
        }
        set { UserDefaults.standard.set(newValue, forKey: frequencyHzKey) }
    }

    static var toleranceHz: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: toleranceHzKey)
            return value == 0 ? defaultToleranceHz : value
        }
        set { UserDefaults.standard.set(newValue, forKey: toleranceHzKey) }
    }

    /// Whether decoding should be active for the given VFO frequency —
    /// enabled and within `toleranceHz` of the configured APRS frequency.
    static func isActive(atFrequencyHz frequencyHz: Int) -> Bool {
        enabled && abs(frequencyHz - Self.frequencyHz) <= toleranceHz
    }
}

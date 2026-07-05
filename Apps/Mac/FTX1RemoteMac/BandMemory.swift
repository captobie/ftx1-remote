import Foundation

/// Remembers the last frequency tuned on each band, so picking a band in
/// the UI returns you to where you left off rather than always jumping to
/// a fixed calling frequency. Backed by `UserDefaults` directly (not
/// `@AppStorage`) for the same reason as `RigctldSettings`: `HubService`
/// isn't a SwiftUI `View`.
enum BandMemory {
    private static let key = "band.lastFrequencyHzByName"

    static func lastFrequencyHz(forBand name: String) -> Int? {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int]
        return stored?[name]
    }

    static func recordFrequencyHz(_ hz: Int, forBand name: String) {
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        stored[name] = hz
        UserDefaults.standard.set(stored, forKey: key)
    }
}

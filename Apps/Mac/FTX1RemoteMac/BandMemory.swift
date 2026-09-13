import FTX1Core
import Foundation

/// Remembers the last frequency and mode used on each band, so picking a
/// band in the UI returns you to where you left off rather than always
/// jumping to a fixed calling frequency (and, for ham bands, whatever mode
/// you were last in) — see `HubService.send(_:)`'s `.setBand` handling.
/// Backed by `UserDefaults` directly (not `@AppStorage`) for the same
/// reason as `RigctldSettings`: `HubService` isn't a SwiftUI `View`.
enum BandMemory {
    private static let frequencyKey = "band.lastFrequencyHzByName"
    private static let modeKey = "band.lastModeByName"
    private static let filterWidthKey = "band.lastFilterWidthIndexByName"

    static func lastFrequencyHz(forBand name: String) -> Int? {
        let stored = UserDefaults.standard.dictionary(forKey: frequencyKey) as? [String: Int]
        return stored?[name]
    }

    static func recordFrequencyHz(_ hz: Int, forBand name: String) {
        var stored = UserDefaults.standard.dictionary(forKey: frequencyKey) as? [String: Int] ?? [:]
        stored[name] = hz
        UserDefaults.standard.set(stored, forKey: frequencyKey)
    }

    static func lastMode(forBand name: String) -> RigMode? {
        let stored = UserDefaults.standard.dictionary(forKey: modeKey) as? [String: String]
        return stored?[name].flatMap(RigMode.init(rawValue:))
    }

    static func recordMode(_ mode: RigMode, forBand name: String) {
        var stored = UserDefaults.standard.dictionary(forKey: modeKey) as? [String: String] ?? [:]
        stored[name] = mode.rawValue
        UserDefaults.standard.set(stored, forKey: modeKey)
    }

    /// The raw "SH" WIDTH index (0-23) last seen on this band — see
    /// `RigState.filterWidthIndex`'s doc comment for why this needs its own
    /// per-band memory alongside `lastMode`, rather than being left to the
    /// rig's own apparent per-mode memory (which was observed *not* to hold
    /// across a mode-forcing band switch and back).
    static func lastFilterWidthIndex(forBand name: String) -> Int? {
        let stored = UserDefaults.standard.dictionary(forKey: filterWidthKey) as? [String: Int]
        return stored?[name]
    }

    static func recordFilterWidthIndex(_ index: Int, forBand name: String) {
        var stored = UserDefaults.standard.dictionary(forKey: filterWidthKey) as? [String: Int] ?? [:]
        stored[name] = index
        UserDefaults.standard.set(stored, forKey: filterWidthKey)
    }
}

import Foundation

/// User-adjustable polling rates (Settings → Polling), backed by
/// `UserDefaults` directly rather than `@AppStorage` — same pattern as
/// `APRSSettings`/`WPSDSettings`, so `HubService` and
/// `WPSDCallsignMonitor` (not SwiftUI views) can read them too.
///
/// Read fresh on every loop iteration by their consumers, so a change
/// applies at the next tick — no reconnect or relaunch needed. Every
/// getter clamps to `range` and falls back to the default for a missing
/// key, so a stray 0 (e.g. an emptied field) can never turn a poll loop
/// into a tight spin against rigctld or the hotspot.
enum PollingSettings {
    struct Setting {
        let key: String
        let defaultValue: Int
        let range: ClosedRange<Int>

        var value: Int {
            get {
                guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
                return UserDefaults.standard.integer(forKey: key).clamped(to: range)
            }
            nonmutating set { UserDefaults.standard.set(newValue.clamped(to: range), forKey: key) }
        }
    }

    /// Fast tier (VFO, mode, S-meter/SWR, PTT) — the delay between the end
    /// of one fast-tier pass and the start of the next, not the whole
    /// cycle: each pass itself takes roughly a second of sequential CAT
    /// reads on top of this.
    static let fastPollMilliseconds = Setting(key: "polling.fastPollMs", defaultValue: 500, range: 100...5_000)
    /// Slow tier (menu/settings fields) runs once every this many fast-tier
    /// passes.
    static let slowTierEvery = Setting(key: "polling.slowTierEvery", defaultValue: 6, range: 1...60)
    /// Wait before retrying after the rigctld connection fails.
    static let reconnectDelaySeconds = Setting(key: "polling.reconnectDelaySeconds", defaultValue: 3, range: 1...60)
    /// WPSD live-caller lookup — see `WPSDCallsignMonitor` for why this
    /// stays conservative (the hotspot's PHP backend is slow under load).
    static let wpsdCallerSeconds = Setting(key: "polling.wpsdCallerSeconds", defaultValue: 3, range: 1...60)
    /// WPSD linked-reflector lookup.
    static let wpsdReflectorSeconds = Setting(key: "polling.wpsdReflectorSeconds", defaultValue: 30, range: 5...600)

    static let all = [fastPollMilliseconds, slowTierEvery, reconnectDelaySeconds, wpsdCallerSeconds, wpsdReflectorSeconds]

    static func restoreDefaults() {
        for setting in all {
            UserDefaults.standard.removeObject(forKey: setting.key)
        }
    }

    static var fastPollInterval: Duration { .milliseconds(fastPollMilliseconds.value) }
    static var reconnectDelay: Duration { .seconds(reconnectDelaySeconds.value) }
    static var wpsdCallerInterval: Duration { .seconds(wpsdCallerSeconds.value) }
    static var wpsdReflectorInterval: Duration { .seconds(wpsdReflectorSeconds.value) }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

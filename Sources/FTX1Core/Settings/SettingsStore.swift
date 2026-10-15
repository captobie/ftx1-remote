import Foundation

/// Where the app's own settings and files live: `UserDefaults.standard`
/// and Application Support/FTX1Remote, except while the iPad's Demo Mode
/// runs, which points both somewhere throwaway (`use(defaults:
/// dataDirectory:)`) so a demo session never touches the real setup —
/// mutes, VOL/SQL, the audio swap parity, the transmit lock, APRS settings
/// and history, the memory-list cache, the CW settings.
///
/// Read by every settings enum and store that persists something
/// (`AudioPlaybackSettings`, `APRSSettings`, `StationSettings`,
/// `WPSDSettings`, `HomeFrequency`, `PiDirectViewModel.transmitEnabled`,
/// `APRSPersistence`, `MemoryListStore`, and FTX1CW's `CWReceiver`/
/// `CWSender`). Objects read their settings when they're made, so the
/// demo makes its own after switching. Display preferences
/// (`AppearanceSettings`) stay on `.standard`.
public enum SettingsStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentDefaults = UserDefaults.standard
    nonisolated(unsafe) private static var currentDataDirectory: URL?

    public static var defaults: UserDefaults {
        lock.withLock { currentDefaults }
    }

    /// Application Support/FTX1Remote, or the demo's folder; created on
    /// first use. nil if there's no Application Support.
    public static var dataDirectory: URL? {
        let override = lock.withLock { currentDataDirectory }
        let directory = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FTX1Remote", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Redirects settings and files (Demo Mode).
    public static func use(defaults: UserDefaults, dataDirectory: URL) {
        lock.withLock {
            currentDefaults = defaults
            currentDataDirectory = dataDirectory
        }
    }

    /// Back to the real ones.
    public static func useStandard() {
        lock.withLock {
            currentDefaults = .standard
            currentDataDirectory = nil
        }
    }
}

import Foundation

/// Which external logbook the app works with, and how to reach it —
/// backed by `UserDefaults` directly (same pattern as `APRSSettings`) so
/// non-View code (the future QSO logger and worked-before lookup) can read
/// it too. Only MacLoggerDX so far; `Logger` is the seam for others.
enum LogbookSettings {
    enum Logger: String, CaseIterable {
        case none
        case macLoggerDX

        var displayName: String {
            switch self {
            case .none: "None"
            case .macLoggerDX: "MacLoggerDX"
            }
        }
    }

    static let loggerKey = "logbook.logger"
    /// A log file the user picked by hand; empty means "use the one
    /// MacLoggerDX itself has open" (`MacLoggerDX.detectedLogPath`).
    static let macLoggerDXLogPathKey = "logbook.macLoggerDX.logPath"
    static let macLoggerDXUDPHostKey = "logbook.macLoggerDX.udpHost"
    static let macLoggerDXUDPPortKey = "logbook.macLoggerDX.udpPort"

    /// MacLoggerDX listens for WSJT-X's UDP messages on WSJT-X's own
    /// default port (seen with `lsof` against MacLoggerDX 6.62).
    static let defaultUDPHost = "127.0.0.1"
    static let defaultUDPPort = 2237

    static var logger: Logger {
        get { Logger(rawValue: UserDefaults.standard.string(forKey: loggerKey) ?? "") ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: loggerKey) }
    }

    static var macLoggerDXLogPathOverride: String {
        get { UserDefaults.standard.string(forKey: macLoggerDXLogPathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: macLoggerDXLogPathKey) }
    }

    /// The log file to read: the hand-picked one if set, otherwise
    /// whatever MacLoggerDX's own preferences say it has open.
    static var macLoggerDXLogPath: String? {
        let override = macLoggerDXLogPathOverride
        return override.isEmpty ? MacLoggerDX.detectedLogPath : override
    }

    static var macLoggerDXUDPHost: String {
        get {
            let value = UserDefaults.standard.string(forKey: macLoggerDXUDPHostKey) ?? ""
            return value.isEmpty ? defaultUDPHost : value
        }
        set { UserDefaults.standard.set(newValue, forKey: macLoggerDXUDPHostKey) }
    }

    static var macLoggerDXUDPPort: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: macLoggerDXUDPPortKey)
            return (1...65535).contains(value) ? value : defaultUDPPort
        }
        set { UserDefaults.standard.set(newValue, forKey: macLoggerDXUDPPortKey) }
    }

    // MARK: Wavelog

    /// Wavelog is a second logbook beside `logger`, not one of its
    /// choices: every QSO goes to both (user request, 2026-10-24). The API
    /// v2 token is in the keychain (`WavelogToken`), not here.
    static let wavelogEnabledKey = "logbook.wavelog.enabled"
    static let wavelogURLKey = "logbook.wavelog.url"
    static let wavelogStationIDKey = "logbook.wavelog.stationID"
    /// The picked location's name and callsign, shown before the list has
    /// been fetched again.
    static let wavelogStationNameKey = "logbook.wavelog.stationName"
    static let wavelogStationCallsignKey = "logbook.wavelog.stationCallsign"

    static var wavelogEnabled: Bool {
        UserDefaults.standard.bool(forKey: wavelogEnabledKey)
    }

    static var wavelogURL: String {
        UserDefaults.standard.string(forKey: wavelogURLKey) ?? ""
    }

    static var wavelogStationID: String {
        UserDefaults.standard.string(forKey: wavelogStationIDKey) ?? ""
    }

    /// Where QSOs go, or why they can't, in words for the Log pane.
    static func wavelogTarget() -> Result<(url: String, token: String, stationID: String), WavelogSetupError> {
        let url = wavelogURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return .failure(WavelogSetupError("Wavelog has no URL — set it in Settings → Logbook")) }
        let token = WavelogToken.read()
        guard !token.isEmpty else { return .failure(WavelogSetupError("Wavelog has no API token — set it in Settings → Logbook")) }
        let station = wavelogStationID
        guard !station.isEmpty else { return .failure(WavelogSetupError("No Wavelog station location — pick one in Settings → Logbook")) }
        return .success((url, token, station))
    }

    struct WavelogSetupError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

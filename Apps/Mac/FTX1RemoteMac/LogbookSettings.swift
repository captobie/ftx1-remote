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
}

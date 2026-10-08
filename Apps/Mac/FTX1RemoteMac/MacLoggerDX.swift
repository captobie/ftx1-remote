import AppKit
import FTX1Core
import SQLite3

/// What the app knows about MacLoggerDX without talking to it: whether
/// it's running, what its own preferences say, and a read-only look at its
/// log file. Logging itself will go over WSJT-X's UDP protocol (user
/// decision, 2026-10-07), so nothing here ever writes to the log.
///
/// Facts below were read off MacLoggerDX 6.62 on the user's Mac, not from
/// documentation (there's none for the file format): the log is SQLite,
/// one QSO table named `qso_table_v008`, `qso_start` in Unix seconds.
nonisolated enum MacLoggerDX {
    static let bundleIdentifier = "com.dogparksoftware.MacLoggerDX"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// The log file MacLoggerDX has open, from its own preferences.
    static var detectedLogPath: String? {
        let path = preference("qso_data_source_sql_db_path") as? String
        return path?.isEmpty == false ? path : nil
    }

    /// MacLoggerDX's "listen for WSJT-X UDP broadcasts" preference — nil
    /// when it has never been set (e.g. MacLoggerDX not installed).
    static var listensForWSJTXUDP: Bool? {
        (preference("listen_for_wsjt_udp_broadcasts") as? NSNumber)?.boolValue
    }

    private static func preference(_ key: String) -> Any? {
        // Re-read from disk: MacLoggerDX may have changed it since launch.
        CFPreferencesAppSynchronize(bundleIdentifier as CFString)
        return CFPreferencesCopyAppValue(key as CFString, bundleIdentifier as CFString)
    }

    struct LogSummary: Equatable {
        var qsoCount: Int
        var callCount: Int
        var lastQSO: Date?
    }

    enum LogError: Error, CustomStringConvertible {
        case missing
        case cannotOpen(String)
        case noQSOTable

        var description: String {
            switch self {
            case .missing: "File not found"
            case .cannotOpen(let message): "Can't read it: \(message)"
            case .noQSOTable: "Doesn't look like a MacLoggerDX log (no QSO table)"
            }
        }
    }

    /// Counts what's in the log.
    static func readSummary(path: String) throws(LogError) -> LogSummary {
        let db = try open(path)
        defer { sqlite3_close(db) }
        let table = try qsoTable(db)

        let summaryQuery = "SELECT COUNT(*), COUNT(DISTINCT UPPER(call)), MAX(qso_start) FROM \"\(table)\""
        let summary = try queryRow(db, summaryQuery) { statement in
            LogSummary(
                qsoCount: Int(sqlite3_column_int64(statement, 0)),
                callCount: Int(sqlite3_column_int64(statement, 1)),
                lastQSO: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            )
        }
        return summary ?? LogSummary(qsoCount: 0, callCount: 0, lastQSO: nil)
    }

    /// Every QSO's call, band, mode and start, for `WorkedStations`. The
    /// band is `band_rx`, or `band_tx` where that's empty.
    static func readWorkedQSOs(path: String) throws(LogError) -> [WorkedStations.QSO] {
        let db = try open(path)
        defer { sqlite3_close(db) }
        let table = try qsoTable(db)
        let sql = "SELECT call, COALESCE(NULLIF(band_rx, ''), band_tx, ''), COALESCE(mode, ''), COALESCE(qso_start, 0) FROM \"\(table)\""
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var qsos: [WorkedStations.QSO] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let call = sqlite3_column_text(statement, 0) else { continue }
                qsos.append(WorkedStations.QSO(
                    call: String(cString: call),
                    band: String(cString: sqlite3_column_text(statement, 1)),
                    mode: String(cString: sqlite3_column_text(statement, 2)),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                ))
            case SQLITE_DONE:
                return qsos
            default:
                throw .cannotOpen(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Whether the log has a QSO with `call` starting within `tolerance`
    /// of `start` — how a UDP-logged QSO is confirmed, since MacLoggerDX
    /// sends nothing back.
    static func containsQSO(call: String, start: Date, tolerance: TimeInterval = 120, path: String) throws(LogError) -> Bool {
        let db = try open(path)
        defer { sqlite3_close(db) }
        let table = try qsoTable(db)
        let sql = "SELECT 1 FROM \"\(table)\" WHERE UPPER(call) = UPPER(?1) AND ABS(qso_start - ?2) <= ?3 LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, call, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, tolerance)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw .cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Opens the log read-only. Never `immutable`: MacLoggerDX keeps
    /// writing to the file while we read it. The caller closes it.
    private static func open(_ path: String) throws(LogError) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { throw .missing }
        var db: OpaquePointer?
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw .cannotOpen(message)
        }
        sqlite3_busy_timeout(db, 1000)
        return db
    }

    /// The QSO table's name carries a schema version; take the newest one
    /// so a future v009 still reads (its columns are checked when used).
    private static func qsoTable(_ db: OpaquePointer?) throws(LogError) -> String {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'qso_table_v%' ORDER BY name DESC LIMIT 1"
        guard let table = try queryRow(db, sql, { String(cString: sqlite3_column_text($0, 0)) }) else {
            throw .noQSOTable
        }
        return table
    }

    /// Runs `sql` and reads its first row, if any.
    private static func queryRow<T>(_ db: OpaquePointer?, _ sql: String, _ read: (OpaquePointer) -> T) throws(LogError) -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return read(statement)
        case SQLITE_DONE: return nil
        default: throw .cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
    }
}

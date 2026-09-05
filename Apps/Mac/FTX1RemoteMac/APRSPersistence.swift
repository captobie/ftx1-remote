import FTX1Core
import Foundation

/// Saves/loads decoded APRS history to disk so it survives an app
/// restart — the only persistence layer in the app today (everything else
/// is either live rig state or `UserDefaults`-backed settings), so this
/// stays deliberately minimal: one JSON file, no migrations.
enum APRSPersistence {
    private struct Snapshot: Codable {
        var stations: [APRSStation]
        var messages: [APRSMessage]
    }

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("FTX1Remote", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("aprs-history.json")
    }

    static func load() -> (stations: [APRSStation], messages: [APRSMessage]) {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return ([], []) }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return ([], []) }
        return (snapshot.stations, snapshot.messages)
    }

    static func save(stations: [APRSStation], messages: [APRSMessage]) {
        guard let fileURL else { return }
        let snapshot = Snapshot(stations: stations, messages: messages)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

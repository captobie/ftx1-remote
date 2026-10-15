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

    /// The history file in the settings folder current right now
    /// (`SettingsStore` — Demo Mode's while it runs). `APRSStore` takes it
    /// once, at init, so it keeps writing where it read from.
    static var currentFileURL: URL? {
        SettingsStore.dataDirectory?.appendingPathComponent("aprs-history.json")
    }

    static func load(from fileURL: URL?) -> (stations: [APRSStation], messages: [APRSMessage]) {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return ([], []) }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return ([], []) }
        return (snapshot.stations, snapshot.messages)
    }

    static func save(stations: [APRSStation], messages: [APRSMessage], to fileURL: URL?) {
        guard let fileURL else { return }
        let snapshot = Snapshot(stations: stations, messages: messages)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear(_ fileURL: URL?) {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

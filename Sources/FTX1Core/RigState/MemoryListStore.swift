import Combine
import Foundation

/// The rig's programmed memory channels, for the Mac's memory list window
/// (`MemoryListView`) and the iPad's VFO-box channel list — on the Mac
/// hub, pushed to clients as `MemoryListPush`; on the iPad's Pi-direct
/// route, its own store reading the Pi's rigctld. CAT has no "list memories" command, so a refresh
/// reads every channel in turn with "MR" (plus "MT" for the tag of each
/// programmed one) — see `RigctldClient.readMemoryChannel`. That's a few
/// hundred round trips sharing the link with the poll loop, so the result
/// is cached on disk and the window shows the cache until the user hits
/// Refresh; a scan runs on its own only when there's no cache yet.
///
/// A plain `let` on `HubService`, not `@Published` there, same as
/// `ft8Store`: the scan publishes progress per channel.
///
/// In `FTX1Core` since 2026-10-09 (was Mac-only); explicitly `@MainActor`
/// since the package doesn't have the app targets' MainActor default. The
/// cache file is per device.
@MainActor
public final class MemoryListStore: ObservableObject {
    @Published public private(set) var entries: [MemoryChannelEntry]
    /// The channel being read while a scan runs, nil otherwise.
    @Published public private(set) var scanningChannel: Int?
    @Published public private(set) var lastScanned: Date?
    /// Why the last scan stopped early, if it did.
    @Published public private(set) var scanError: String?

    /// A scan stops after this many blank channels in a row. Blank channels
    /// are cheap (one "MR" answered "?;" at once), but channels are
    /// normally filled from 1, and reading all 999 would take several times
    /// longer than a typical list plus this margin. A gap this long would
    /// hide the channels past it.
    public static let blankRunLimit = 100

    /// The link a refresh reads through; nil (Pi direct while disconnected)
    /// makes `refresh()` a no-op. Changing it cancels a running scan.
    public var rigctld: RigctldClient? {
        didSet { if rigctld !== oldValue { cancel() } }
    }
    private var scanTask: Task<Void, Never>?

    public var isScanning: Bool { scanningChannel != nil }

    /// What a channel picker needs — also the `MemoryListPush` payload.
    public var snapshot: MemoryListSnapshot {
        MemoryListSnapshot(entries: entries, scanned: lastScanned, scanningChannel: scanningChannel)
    }

    public init(rigctld: RigctldClient? = nil) {
        self.rigctld = rigctld
        let snapshot = MemoryListPersistence.load()
        entries = snapshot?.entries ?? []
        lastScanned = snapshot?.scanned
    }

    /// Re-reads the channel list from the rig. While it runs, rows below
    /// the scan position keep their cached values, so the list doesn't
    /// empty out; channels the scan finds blank are dropped as it passes
    /// them. Saved to disk only when the scan completes.
    public func refresh() {
        guard scanTask == nil, let rigctld else { return }
        scanError = nil
        scanTask = Task { [weak self] in
            await self?.scan(rigctld)
            self?.scanTask = nil
            self?.scanningChannel = nil
        }
    }

    public func cancel() {
        scanTask?.cancel()
    }

    private func scan(_ rigctld: RigctldClient) async {
        var found: [MemoryChannelEntry] = []
        var blankRun = 0
        for channel in RigState.memoryChannelRange {
            if Task.isCancelled {
                scanError = "Stopped at channel \(channel)."
                return
            }
            scanningChannel = channel
            do {
                if let entry = try await rigctld.readMemoryChannel(channel) {
                    found.append(entry)
                    blankRun = 0
                } else {
                    blankRun += 1
                }
            } catch RigctldError.notConnected, RigctldError.connectionLost {
                scanError = "Lost the rig connection at channel \(channel)."
                return
            } catch {
                // A timed-out read (the client has already reconnected):
                // count it as blank rather than give up on the whole list.
                blankRun += 1
            }
            entries = found + entries.filter { $0.channel > channel }
            if blankRun >= Self.blankRunLimit { break }
        }
        entries = found
        lastScanned = Date()
        MemoryListPersistence.save(entries: found, scanned: lastScanned!)
    }
}

/// The channel list as a value: entries plus when it was read, and the
/// channel being read while a scan runs.
public struct MemoryListSnapshot: Codable, Sendable, Equatable {
    public var entries: [MemoryChannelEntry]
    public var scanned: Date?
    public var scanningChannel: Int?

    public init(entries: [MemoryChannelEntry], scanned: Date?, scanningChannel: Int?) {
        self.entries = entries
        self.scanned = scanned
        self.scanningChannel = scanningChannel
    }
}

/// One JSON file in Application Support, like `APRSPersistence`.
private enum MemoryListPersistence {
    struct Snapshot: Codable {
        var entries: [MemoryChannelEntry]
        var scanned: Date
    }

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("FTX1Remote", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("memory-channels.json")
    }

    static func load() -> Snapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(entries: [MemoryChannelEntry], scanned: Date) {
        guard let fileURL, let data = try? JSONEncoder().encode(Snapshot(entries: entries, scanned: scanned)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

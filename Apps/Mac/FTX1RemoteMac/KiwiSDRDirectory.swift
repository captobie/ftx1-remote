import Combine
import Foundation
import os

/// The public KiwiSDR directory behind the WebSDR window's "Stations…"
/// sheet.
///
/// **Source: `rx.linkfanel.net/kiwisdr_com.js`**, the community mirror of
/// kiwisdr.com/public that feeds the well-known "dyatlov" receiver map
/// (Pierre Ynard). The official kiwisdr.com/public list is deliberately
/// gated (click-to-show plus an `x-kiwi-auth` header), so the app doesn't
/// imitate it. The mirror is a JS file (`var kiwisdr_com = [ … ];`) whose
/// array is JSON apart from a trailing comma; it's ~900 KB and regenerated
/// a few times an hour.
///
/// **Etiquette**: fetched only when the sheet opens (and only if the disk
/// cache is older than `staleAfter`) or on an explicit Refresh — never
/// polled in the background. Conditional GET (`If-None-Match`), and a
/// User-Agent naming the app. The raw file is cached in Application
/// Support, so the list shows instantly and survives the mirror being down.
final class KiwiSDRDirectory: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    static let sourceURL = URL(string: "http://rx.linkfanel.net/kiwisdr_com.js")!
    static let staleAfter: TimeInterval = 30 * 60

    @Published private(set) var stations: [KiwiSDRStation] = []
    @Published private(set) var state: LoadState = .idle
    /// When the list on screen was last fetched from the mirror (or the
    /// cache file's date, when shown from cache).
    @Published private(set) var fetchedAt: Date?

    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "kiwisdr-directory")

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FTX1Remote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kiwisdr_com.js")
    }

    private let etagKey = "webSDR.directoryETag"

    /// Called when the sheet opens: shows the cached list immediately, then
    /// fetches only if it's stale (or there's no cache).
    func loadIfNeeded() {
        if stations.isEmpty, let cacheDate = cacheModificationDate() {
            // Cache parse is async, so decide freshness from the file date
            // now; a fresh cache that fails to parse falls back to a fetch.
            let fresh = Date().timeIntervalSince(cacheDate) < Self.staleAfter
            loadFromCache(date: cacheDate, fetchIfUnusable: fresh)
            if fresh { return }
        } else if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.staleAfter {
            return
        }
        refresh()
    }

    func refresh() {
        guard state != .loading else { return }
        state = .loading
        Task { await fetch() }
    }

    private func cacheModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
    }

    private func loadFromCache(date: Date, fetchIfUnusable: Bool) {
        let data = try? Data(contentsOf: cacheURL)
        Task {
            var parsed: [KiwiSDRStation]?
            if let data { parsed = await Self.parseOffMain(data) }
            // A network result may have landed first; don't overwrite it.
            guard stations.isEmpty else { return }
            if let parsed, !parsed.isEmpty {
                stations = parsed
                fetchedAt = date
            } else if fetchIfUnusable {
                refresh()
            }
        }
    }

    private func fetch() async {
        var request = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        request.setValue("FTX1Remote/\(version) (KiwiSDR station directory)", forHTTPHeaderField: "User-Agent")
        let haveCache = FileManager.default.fileExists(atPath: cacheURL.path)
        if haveCache, !stations.isEmpty, let etag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304 {
                touchCache()
                fetchedAt = Date()
                state = .idle
                return
            }
            guard http?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard let parsed = await Self.parseOffMain(data), !parsed.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try? data.write(to: cacheURL, options: .atomic)
            UserDefaults.standard.set(http?.value(forHTTPHeaderField: "ETag"), forKey: etagKey)
            stations = parsed
            fetchedAt = Date()
            state = .idle
            Self.logger.info("fetched \(parsed.count) stations (\(data.count) bytes)")
        } catch {
            Self.logger.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(stations.isEmpty
                ? "Couldn't load the station list: \(error.localizedDescription)"
                : "Couldn't refresh — showing the cached list. (\(error.localizedDescription))")
        }
    }

    private func touchCache() {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheURL.path)
    }

    /// ~900 KB of JSON — parsed off the main actor.
    private static func parseOffMain(_ data: Data) async -> [KiwiSDRStation]? {
        await Task.detached(priority: .userInitiated) { parse(data) }.value
    }

    /// `var kiwisdr_com = [ {…}, {…}, ];` → stations. Strips everything
    /// outside the outer array and the trailing comma JSON doesn't allow.
    nonisolated static func parse(_ data: Data) -> [KiwiSDRStation]? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"), start < end
        else { return nil }
        var body = String(text[start...end])
        if let trailingComma = body.range(of: #",\s*\]$"#, options: .regularExpression) {
            body.replaceSubrange(trailingComma, with: "]")
        }
        guard let entries = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]] else {
            return nil
        }
        return entries.compactMap { entry in
            KiwiSDRStation(entry: entry.compactMapValues { $0 as? String })
        }
    }
}


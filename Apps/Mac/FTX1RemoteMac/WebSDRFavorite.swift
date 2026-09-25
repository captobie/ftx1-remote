import Foundation

/// One saved WebSDR-window station, KiwiSDR or classic WebSDR. Picking a favorite behaves like picking from
/// the directory (`WebSDRFollowModel.select`): it fills the host and, when
/// known, the receive ranges, and never connects.
///
/// `bands` is what fixes the "hand-typed host has no range" gap for
/// favorites: a favorite starred from the directory (or added while a
/// directory pick is the current host) keeps that station's ranges, so a
/// converter-fed Kiwi keeps following above 30 MHz. A favorite added from a
/// typed host has none and uses KiwiSDR's 0–30 MHz, same as before.
nonisolated struct WebSDRFavorite: Codable, Identifiable, Hashable, Sendable {
    /// The host field's value, e.g. "kiwi.example.org:8073".
    var hostPort: String
    /// Shown in the Favorites menu; the station's directory name, or the
    /// host for a typed one. Renamable in Manage Favorites.
    var name: String
    var location: String
    /// "lo-hi,lo-hi" (the directory listing's own format), or nil if unknown.
    /// A WebSDR's come from its own page (`SDRPageBridge.readBands`) the
    /// first time it's connected.
    var bands: String?
    /// nil until known: a host typed by hand, or saved before WebSDR support
    /// (synthesized `Codable` decodes a missing key as nil, so those still
    /// load). Treated as a KiwiSDR until the page says otherwise.
    var platform: SDRPlatform?

    var id: String { WebSDRFavorite.key(hostPort) }

    var bandRanges: [ClosedRange<Int>]? {
        bands.map { KiwiSDRStation.parseBands($0) }
    }

    init(hostPort: String, name: String, location: String = "", bands: [ClosedRange<Int>]? = nil,
         platform: SDRPlatform? = nil) {
        self.hostPort = hostPort
        self.name = name
        self.location = location
        self.bands = bands.map(WebSDRFavorite.encode)
        self.platform = platform
    }

    init(station: KiwiSDRStation) {
        self.init(hostPort: station.hostPort, name: station.name,
                  location: station.location, bands: station.bands, platform: .kiwiSDR)
    }

    /// The host field's form of a station URL: no `http://`, no trailing
    /// slash (same as `KiwiSDRStation.hostPort`).
    static func hostPort(from url: URL) -> String {
        var s = url.absoluteString
        if s.hasPrefix("http://") { s.removeFirst("http://".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Host comparison key: "Kiwi.Example.org:8073/" and "kiwi.example.org:8073"
    /// are the same station.
    static func key(_ hostPort: String) -> String {
        var s = hostPort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("http://") { s.removeFirst("http://".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func encode(_ bands: [ClosedRange<Int>]) -> String {
        bands.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
    }
}

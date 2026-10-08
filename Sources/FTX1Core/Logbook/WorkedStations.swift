import Foundation

/// The logbook's QSOs indexed by callsign, for "worked before?" while
/// operating — built once from the whole log and asked per callsign, so it
/// can be consulted on every decoded-text render.
///
/// Calls are matched on their base call: the longest `/`-separated part,
/// so K6NA/P, W1/K6NA and K6NA are one station (the same rule
/// `CWCallsigns` uses to judge a call). Bands compare case-insensitively
/// ("40M" in MacLoggerDX's log, "40m" in `BandPlan`).
public struct WorkedStations: Sendable {
    public struct QSO: Equatable, Sendable {
        public var call: String
        /// ADIF-style band name, any case; empty if the log has none.
        public var band: String
        public var mode: String
        public var date: Date

        public init(call: String, band: String, mode: String, date: Date) {
            self.call = call
            self.band = band
            self.mode = mode
            self.date = date
        }
    }

    public enum Status: Equatable, Sendable {
        case never
        /// Worked, but only on other bands than the one asked about.
        case otherBand
        case thisBand
    }

    public struct Summary: Equatable, Sendable {
        public var count: Int
        /// The most recent QSO with this station.
        public var last: QSO
        /// Every band worked, lowercased, e.g. ["20m", "40m"].
        public var bands: Set<String>
    }

    private var byCall: [String: [QSO]] = [:]

    public static let empty = WorkedStations(qsos: [])

    public init(qsos: [QSO]) {
        for qso in qsos {
            let key = Self.baseCall(qso.call)
            guard !key.isEmpty else { continue }
            byCall[key, default: []].append(qso)
        }
    }

    public var stationCount: Int { byCall.count }

    public func status(of call: String, band: String?) -> Status {
        guard let qsos = byCall[Self.baseCall(call)] else { return .never }
        guard let band = band?.lowercased(), !band.isEmpty else { return .otherBand }
        return qsos.contains { $0.band.lowercased() == band } ? .thisBand : .otherBand
    }

    public func summary(of call: String) -> Summary? {
        guard let qsos = byCall[Self.baseCall(call)], let last = qsos.max(by: { $0.date < $1.date }) else {
            return nil
        }
        let bands = Set(qsos.map { $0.band.lowercased() }.filter { !$0.isEmpty })
        return Summary(count: qsos.count, last: last, bands: bands)
    }

    /// Uppercased longest `/` part — the station itself, without a
    /// portable/maritime suffix or a country prefix. On a tie the later
    /// part wins, the usual PREFIX/CALL order (VP2E/K6NA → K6NA).
    public static func baseCall(_ call: String) -> String {
        let parts = call.uppercased().split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.reduce("") { $1.count >= $0.count ? $1 : $0 }
    }
}

import Combine
import FTX1Core
import Foundation

/// Owns the app's decoded APRS station/message history — what
/// `APRSStationListView`/`APRSMessageListView` (the S.LIST/M.LIST windows)
/// display. Fed by `APRSDecoder`'s output, which always arrives on the
/// main actor (same contract as `AudioCaptureEngine.onNewFrame`), so this
/// itself doesn't need to be an actor.
///
/// Loads from disk on init and saves after every update — APRS traffic is
/// sparse (packets per minute at most on a quiet channel), so a
/// synchronous save per update costs nothing and needs no debouncing.
@MainActor
final class APRSStore: ObservableObject {
    @Published private(set) var stations: [APRSStation] = []
    @Published private(set) var messages: [APRSMessage] = []

    init() {
        let loaded = APRSPersistence.load()
        stations = loaded.stations
        messages = loaded.messages
        // Trim on load too, not just on record — covers a limit lowered
        // in Settings since the history file was last written.
        trimStations()
        trimMessages()
    }

    /// Upserts by callsign (including SSID) — a station heard again
    /// updates its existing entry (position, comment, last-heard time)
    /// rather than duplicating. `source` is likewise overwritten on every
    /// update rather than being part of the upsert key — see
    /// `APRSStation`'s doc comment: it reflects whichever channel most
    /// recently heard the station, not a fixed identity.
    func recordStation(
        callsign: String,
        latitude: Double?,
        longitude: Double?,
        symbolTable: String?,
        symbolCode: String?,
        comment: String?,
        heardAt: Date,
        source: APRSSource
    ) {
        if let index = stations.firstIndex(where: { $0.callsign == callsign }) {
            var station = stations[index]
            if let latitude { station.latitude = latitude }
            if let longitude { station.longitude = longitude }
            if let symbolTable { station.symbolTable = symbolTable }
            if let symbolCode { station.symbolCode = symbolCode }
            if let comment { station.comment = comment }
            station.lastHeardAt = heardAt
            station.source = source
            stations[index] = station
        } else {
            stations.append(APRSStation(
                callsign: callsign,
                latitude: latitude,
                longitude: longitude,
                symbolTable: symbolTable,
                symbolCode: symbolCode,
                comment: comment,
                lastHeardAt: heardAt,
                source: source
            ))
        }
        trimStations()
        persist()
    }

    func recordMessage(from: String, to: String, text: String, messageID: String?, receivedAt: Date, source: APRSSource) {
        messages.append(APRSMessage(from: from, to: to, text: text, messageID: messageID, receivedAt: receivedAt, source: source))
        trimMessages()
        persist()
    }

    func clearHistory() {
        stations = []
        messages = []
        APRSPersistence.clear()
    }

    /// Evicts the least-recently-heard stations once over
    /// `APRSSettings.maxStations` — a station is only ever added here when
    /// it's genuinely new (an already-known callsign updates in place), so
    /// this is the only place the array can grow past the limit.
    private func trimStations() {
        let limit = APRSSettings.maxStations
        guard stations.count > limit else { return }
        stations.sort { $0.lastHeardAt > $1.lastHeardAt }
        stations.removeLast(stations.count - limit)
    }

    /// Evicts the oldest messages once over `APRSSettings.maxMessages` —
    /// unlike stations, every received message is appended (never
    /// deduped/updated in place), so this is the only bound on growth.
    private func trimMessages() {
        let limit = APRSSettings.maxMessages
        guard messages.count > limit else { return }
        messages.sort { $0.receivedAt > $1.receivedAt }
        messages.removeLast(messages.count - limit)
    }

    private func persist() {
        APRSPersistence.save(stations: stations, messages: messages)
    }
}

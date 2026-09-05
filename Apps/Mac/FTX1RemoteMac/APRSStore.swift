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
    }

    /// Upserts by callsign (including SSID) — a station heard again
    /// updates its existing entry (position, comment, last-heard time)
    /// rather than duplicating.
    func recordStation(
        callsign: String,
        latitude: Double?,
        longitude: Double?,
        symbolTable: String?,
        symbolCode: String?,
        comment: String?,
        heardAt: Date
    ) {
        if let index = stations.firstIndex(where: { $0.callsign == callsign }) {
            var station = stations[index]
            if let latitude { station.latitude = latitude }
            if let longitude { station.longitude = longitude }
            if let symbolTable { station.symbolTable = symbolTable }
            if let symbolCode { station.symbolCode = symbolCode }
            if let comment { station.comment = comment }
            station.lastHeardAt = heardAt
            stations[index] = station
        } else {
            stations.append(APRSStation(
                callsign: callsign,
                latitude: latitude,
                longitude: longitude,
                symbolTable: symbolTable,
                symbolCode: symbolCode,
                comment: comment,
                lastHeardAt: heardAt
            ))
        }
        persist()
    }

    func recordMessage(from: String, to: String, text: String, messageID: String?, receivedAt: Date) {
        messages.append(APRSMessage(from: from, to: to, text: text, messageID: messageID, receivedAt: receivedAt))
        persist()
    }

    func clearHistory() {
        stations = []
        messages = []
        APRSPersistence.clear()
    }

    private func persist() {
        APRSPersistence.save(stations: stations, messages: messages)
    }
}

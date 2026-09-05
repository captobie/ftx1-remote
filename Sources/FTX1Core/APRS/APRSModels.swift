import Foundation

/// A station heard via decoded APRS packets, keyed by callsign (including
/// SSID, e.g. "N0CALL-9" — SSID is part of the key since it's a distinct
/// station identity, same as how AX.25 treats it). Updated in place as
/// further packets arrive from the same station rather than duplicated.
public struct APRSStation: Codable, Sendable, Identifiable, Equatable {
    public var id: String { callsign }

    public var callsign: String
    public var latitude: Double?
    public var longitude: Double?
    /// Single-character strings rather than `Character` — `Character`
    /// doesn't conform to `Codable`.
    public var symbolTable: String?
    public var symbolCode: String?
    public var comment: String?
    public var lastHeardAt: Date

    public init(
        callsign: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        symbolTable: String? = nil,
        symbolCode: String? = nil,
        comment: String? = nil,
        lastHeardAt: Date
    ) {
        self.callsign = callsign
        self.latitude = latitude
        self.longitude = longitude
        self.symbolTable = symbolTable
        self.symbolCode = symbolCode
        self.comment = comment
        self.lastHeardAt = lastHeardAt
    }
}

/// A decoded APRS message packet (data type identifier `:`). Not deduped
/// or updated in place like `APRSStation` — every received message is its
/// own list entry, so `id` is a fresh UUID rather than a derived key.
public struct APRSMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var from: String
    public var to: String
    public var text: String
    public var messageID: String?
    public var receivedAt: Date

    public init(
        id: String = UUID().uuidString,
        from: String,
        to: String,
        text: String,
        messageID: String? = nil,
        receivedAt: Date
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.text = text
        self.messageID = messageID
        self.receivedAt = receivedAt
    }
}

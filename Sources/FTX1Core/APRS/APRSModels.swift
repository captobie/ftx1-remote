import Foundation

/// Which audio channel a decoded APRS packet arrived on — see
/// `HubService`'s `aprsDecoder`/`aprsDecoderSub`, two fully independent
/// decoder instances gated on the Main/Sub VFO frequency respectively.
public enum APRSSource: String, Codable, Sendable {
    case main
    case sub
}

/// A station heard via decoded APRS packets, keyed by callsign (including
/// SSID, e.g. "N0CALL-9" — SSID is part of the key since it's a distinct
/// station identity, same as how AX.25 treats it). Updated in place as
/// further packets arrive from the same station rather than duplicated —
/// including `source`, which reflects whichever channel most recently
/// heard the station rather than being part of the upsert key (a station
/// heard on both Main and Sub is one physical station, not two rows).
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
    public var source: APRSSource

    public init(
        callsign: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        symbolTable: String? = nil,
        symbolCode: String? = nil,
        comment: String? = nil,
        lastHeardAt: Date,
        source: APRSSource = .main
    ) {
        self.callsign = callsign
        self.latitude = latitude
        self.longitude = longitude
        self.symbolTable = symbolTable
        self.symbolCode = symbolCode
        self.comment = comment
        self.lastHeardAt = lastHeardAt
        self.source = source
    }

    /// Defaults `source` to `.main` when decoding history files persisted
    /// before the Sub-channel APRS feature existed — every one of them is
    /// genuinely Main-only, and without this a missing key would otherwise
    /// throw and `APRSPersistence.load()`'s `try?` would silently drop all
    /// prior history.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callsign = try container.decode(String.self, forKey: .callsign)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        symbolTable = try container.decodeIfPresent(String.self, forKey: .symbolTable)
        symbolCode = try container.decodeIfPresent(String.self, forKey: .symbolCode)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        lastHeardAt = try container.decode(Date.self, forKey: .lastHeardAt)
        source = try container.decodeIfPresent(APRSSource.self, forKey: .source) ?? .main
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
    public var source: APRSSource

    public init(
        id: String = UUID().uuidString,
        from: String,
        to: String,
        text: String,
        messageID: String? = nil,
        receivedAt: Date,
        source: APRSSource = .main
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.text = text
        self.messageID = messageID
        self.receivedAt = receivedAt
        self.source = source
    }

    /// See `APRSStation.init(from:)` — same backward-compatibility reasoning.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        text = try container.decode(String.self, forKey: .text)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        source = try container.decodeIfPresent(APRSSource.self, forKey: .source) ?? .main
    }
}

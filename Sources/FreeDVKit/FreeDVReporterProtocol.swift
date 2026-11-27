import Foundation

/// FreeDV Reporter's wire format (qso.freedv.org): Socket.IO v4 over an
/// Engine.IO v4 WebSocket, as freedv-backend's `FreeDVReporter`/
/// `SocketIoClient` (BSD-2) speak it. Pure functions, so the framing and
/// the event shapes are unit-tested apart from the network.
///
/// Engine.IO packets are one type digit + payload: "0" open (JSON with
/// `pingInterval`/`pingTimeout` in ms), "2" ping (answer "3"), "1" close,
/// "4" message. A message carries a Socket.IO packet: "0" connect (the
/// client's carries the auth JSON), "2" event (`["name", {...}]`),
/// "1" disconnect, "4" connect error.
public enum FreeDVReporterProtocol {
    public static let defaultHost = "qso.freedv.org"
    /// freedv-backend's FREEDV_REPORTER_PROTOCOL_VERSION.
    public static let protocolVersion = 2
    /// How FreeDV names RADE V1 in `tx_report`/`rx_report`.
    public static let radeModeName = "RADEV1"

    public static func url(host: String = defaultHost, secure: Bool = true) -> URL {
        URL(string: "\(secure ? "wss" : "ws")://\(host)/socket.io/?EIO=4&transport=websocket")!
    }

    /// What the server sent, decoded as far as the client needs.
    public enum Incoming: Equatable {
        case open(pingInterval: TimeInterval, pingTimeout: TimeInterval)
        case ping
        case close
        /// The Socket.IO namespace connected.
        case connected
        case disconnected
        case connectError(String)
        case event(name: String, payload: Any?)
        case unknown(String)

        public static func == (lhs: Incoming, rhs: Incoming) -> Bool {
            switch (lhs, rhs) {
            case let (.open(a, b), .open(c, d)): a == c && b == d
            case (.ping, .ping), (.close, .close), (.connected, .connected), (.disconnected, .disconnected): true
            case let (.connectError(a), .connectError(b)): a == b
            case let (.event(a, _), .event(b, _)): a == b
            case let (.unknown(a), .unknown(b)): a == b
            default: false
            }
        }
    }

    public static func parse(_ frame: String) -> Incoming {
        guard let type = frame.first else { return .unknown(frame) }
        let body = String(frame.dropFirst())
        switch type {
        case "0":
            let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let interval = (json?["pingInterval"] as? Double ?? 25_000) / 1000
            let timeout = (json?["pingTimeout"] as? Double ?? 20_000) / 1000
            return .open(pingInterval: interval, pingTimeout: timeout)
        case "1": return .close
        case "2": return .ping
        case "4": return parseSocketIO(body)
        default: return .unknown(frame)
        }
    }

    private static func parseSocketIO(_ packet: String) -> Incoming {
        guard let type = packet.first else { return .unknown(packet) }
        let body = String(packet.dropFirst())
        switch type {
        case "0": return .connected
        case "1": return .disconnected
        case "4":
            let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            return .connectError(json?["message"] as? String ?? body)
        case "2":
            guard let array = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [Any],
                  let name = array.first as? String
            else { return .unknown(packet) }
            return .event(name: name, payload: array.count > 1 ? array[1] : nil)
        default:
            return .unknown(packet)
        }
    }

    public static let pong = "3"

    /// The namespace connect with the station's auth: role "report".
    public static func connectFrame(callsign: String, gridSquare: String, version: String,
                                    receiveOnly: Bool, os: String) -> String {
        let auth: [String: Any] = [
            "role": "report",
            "callsign": callsign,
            "grid_square": gridSquare,
            "version": version,
            "rx_only": receiveOnly,
            "os": os,
            "protocol_version": protocolVersion,
        ]
        return "40" + json(auth)
    }

    /// A read-only connect (the website's role): nothing about us is sent.
    /// Used by the live test only.
    public static func viewConnectFrame() -> String {
        "40" + json(["role": "view", "protocol_version": protocolVersion] as [String: Any])
    }

    public static func eventFrame(_ name: String, _ payload: [String: Any]? = nil) -> String {
        var array: [Any] = [name]
        if let payload { array.append(payload) }
        return "42" + json(array)
    }

    public static func frequencyChange(_ hz: Int) -> String {
        eventFrame("freq_change", ["freq": max(0, hz)])
    }

    public static func transmitReport(transmitting: Bool, mode: String = radeModeName) -> String {
        eventFrame("tx_report", ["mode": mode, "transmitting": transmitting])
    }

    public static func receiveReport(callsign: String, snrDB: Int, mode: String = radeModeName) -> String {
        eventFrame("rx_report", ["callsign": callsign, "mode": mode, "snr": snrDB])
    }

    public static func message(_ text: String) -> String {
        eventFrame("message_update", ["message": text])
    }

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// One station on FreeDV Reporter, as the station list shows it.
public struct FreeDVReporterStation: Identifiable, Equatable, Sendable {
    /// The server's session id.
    public let id: String
    public var callsign: String
    public var gridSquare: String
    public var version: String = ""
    public var receiveOnly = false
    public var frequencyHz: Int?
    public var mode: String?
    public var transmitting = false
    /// The station's free-text status message.
    public var message: String = ""
    /// The last callsign this station reported hearing, with the SNR.
    public var lastHeardCallsign: String?
    public var lastHeardSNR: Double?
    /// When the server last changed anything about this station.
    public var lastUpdate: Date?
}

/// Applies FreeDV Reporter events to the station list. Pure, so it's
/// tested with the event shapes freedv-backend reads.
public struct FreeDVReporterStations: Equatable, Sendable {
    public private(set) var stations: [String: FreeDVReporterStation] = [:]

    public init() {}

    public mutating func removeAll() {
        stations = [:]
    }

    /// Returns true when something changed.
    @discardableResult
    public mutating func apply(event name: String, payload: Any?) -> Bool {
        if name == "bulk_update" {
            guard let events = payload as? [Any] else { return false }
            var changed = false
            for case let event as [Any] in events {
                guard let inner = event.first as? String else { continue }
                changed = apply(event: inner, payload: event.count > 1 ? event[1] : nil) || changed
            }
            return changed
        }
        guard let object = payload as? [String: Any], let sid = object["sid"] as? String else { return false }
        let lastUpdate = Self.date(object["last_update"])
        switch name {
        case "new_connection":
            guard let callsign = object["callsign"] as? String else { return false }
            var station = stations[sid] ?? FreeDVReporterStation(id: sid, callsign: callsign,
                                                                 gridSquare: object["grid_square"] as? String ?? "")
            station.callsign = callsign
            station.gridSquare = object["grid_square"] as? String ?? station.gridSquare
            station.version = object["version"] as? String ?? station.version
            station.receiveOnly = object["rx_only"] as? Bool ?? station.receiveOnly
            station.lastUpdate = lastUpdate ?? station.lastUpdate
            stations[sid] = station
        case "remove_connection":
            return stations.removeValue(forKey: sid) != nil
        case "freq_change":
            guard var station = stations[sid] else { return false }
            station.frequencyHz = Self.int(object["freq"])
            station.lastUpdate = lastUpdate ?? station.lastUpdate
            stations[sid] = station
        case "tx_report":
            guard var station = stations[sid] else { return false }
            station.mode = object["mode"] as? String ?? station.mode
            station.transmitting = object["transmitting"] as? Bool ?? false
            station.lastUpdate = lastUpdate ?? station.lastUpdate
            stations[sid] = station
        case "rx_report":
            guard var station = stations[sid] else { return false }
            station.lastHeardCallsign = object["callsign"] as? String
            station.lastHeardSNR = (object["snr"] as? NSNumber)?.doubleValue
            station.lastUpdate = lastUpdate ?? station.lastUpdate
            stations[sid] = station
        case "message_update":
            guard var station = stations[sid] else { return false }
            station.message = object["message"] as? String ?? ""
            station.lastUpdate = lastUpdate ?? station.lastUpdate
            stations[sid] = station
        default:
            return false
        }
        return true
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let hz = number.int64Value
        return hz > 0 ? Int(hz) : nil
    }

    /// The server's timestamps are ISO 8601, with or without fractions.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        // Python's isoformat without a zone: read as UTC.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}

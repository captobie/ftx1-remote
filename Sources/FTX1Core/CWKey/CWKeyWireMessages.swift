import Foundation

/// The relayed straight-key messages of `docs/cw-protocol.md`, as sent to
/// the Pi's `ftx1-cwkey.py` (newline-delimited JSON on TCP 8534) — and
/// later over the hub's WebSocket.
public enum CWKeyWire {
    public static let protocolVersion = 1

    public struct Hello: Codable, Equatable, Sendable {
        public var type = "cw_hello"
        public var seq: UInt32
        public var id: String
        public var version = CWKeyWire.protocolVersion
        /// "RTS" or "DTR".
        public var line: String
        public var inverted: Bool
        public var playoutDelayMs: Int
        public var heartbeatTimeoutMs: Int
        public var maxKeyDownMs: Int

        public init(seq: UInt32, id: String, line: String, inverted: Bool,
                    playoutDelayMs: Int, heartbeatTimeoutMs: Int, maxKeyDownMs: Int) {
            self.seq = seq
            self.id = id
            self.line = line
            self.inverted = inverted
            self.playoutDelayMs = playoutDelayMs
            self.heartbeatTimeoutMs = heartbeatTimeoutMs
            self.maxKeyDownMs = maxKeyDownMs
        }
    }

    public struct Key: Codable, Equatable, Sendable {
        public var type = "cw"
        public var seq: UInt32
        /// The key interface's own millisecond clock, passed through.
        public var t: UInt32
        /// "down" or "up".
        public var state: String

        public init(seq: UInt32, t: UInt32, down: Bool) {
            self.seq = seq
            self.t = t
            state = down ? "down" : "up"
        }
    }

    public struct Heartbeat: Codable, Equatable, Sendable {
        public var type = "cw_hb"
        public var seq: UInt32
        public var t: UInt32

        public init(seq: UInt32, t: UInt32) {
            self.seq = seq
            self.t = t
        }
    }

    public struct Bye: Codable, Equatable, Sendable {
        public var type = "cw_bye"
        public var seq: UInt32

        public init(seq: UInt32) {
            self.seq = seq
        }
    }

    public struct Status: Codable, Equatable, Sendable {
        public var type: String
        public var armed: Bool
        public var keyed: Bool
        public var holder: Bool
        public var cutoff: String?
        public var latched: String?
        public var error: String?
        public var playoutDelayMs: Int?
    }

    /// One JSON line (with its newline).
    public static func line<Message: Encodable>(_ message: Message) -> Data {
        var data = (try? JSONEncoder().encode(message)) ?? Data()
        data.append(0x0A)
        return data
    }
}

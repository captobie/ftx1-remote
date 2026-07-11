import Foundation

/// Commands a client (iOS/iPadOS, or the Mac's own local UI) can send
/// to the Mac hub over the WebSocket connection.
///
/// Kept as an enum with associated values internally, but encodes/decodes
/// to the flat `{"cmd": ..., "value": ...}` shape from the protocol draft
/// so it stays simple to read on the wire and easy to extend later.
public enum RigCommand: Sendable, Equatable {
    case setFrequency(hz: Int)
    case setMode(RigMode)
    case setPTT(Bool)
    case setBand(String)
    /// 0.0–1.0, relative RFPOWER setting (not watts) — see `RigState.powerLevel`.
    case setPowerLevel(Double)
    /// CW break-in on/off — see `RigState.breakIn`. Maps to the FTX-1's own
    /// raw "BI" CAT command in `CommandQueue` (per the CAT Operation
    /// Reference Manual), not a hamlib func — doesn't distinguish semi vs.
    /// full break-in, which is a separate menu item on the real rig.
    case setBreakIn(Bool)
    /// CW electronic keyer on/off — see `RigState.keyerEnabled`. Maps to
    /// the FTX-1's raw "KR" CAT command.
    case setKeyer(Bool)

    private enum CodingKeys: String, CodingKey {
        case cmd
        case value
    }

    private enum CommandName: String, Codable {
        case setFreq = "set_freq"
        case setMode = "set_mode"
        case ptt
        case setBand = "set_band"
        case setPower = "set_power"
        case setBreakIn = "set_break_in"
        case setKeyer = "set_keyer"
    }
}

extension RigCommand: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(CommandName.self, forKey: .cmd)
        switch name {
        case .setFreq:
            self = .setFrequency(hz: try container.decode(Int.self, forKey: .value))
        case .setMode:
            self = .setMode(try container.decode(RigMode.self, forKey: .value))
        case .ptt:
            self = .setPTT(try container.decode(Bool.self, forKey: .value))
        case .setBand:
            self = .setBand(try container.decode(String.self, forKey: .value))
        case .setPower:
            self = .setPowerLevel(try container.decode(Double.self, forKey: .value))
        case .setBreakIn:
            self = .setBreakIn(try container.decode(Bool.self, forKey: .value))
        case .setKeyer:
            self = .setKeyer(try container.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setFrequency(let hz):
            try container.encode(CommandName.setFreq, forKey: .cmd)
            try container.encode(hz, forKey: .value)
        case .setMode(let mode):
            try container.encode(CommandName.setMode, forKey: .cmd)
            try container.encode(mode, forKey: .value)
        case .setPTT(let on):
            try container.encode(CommandName.ptt, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setBand(let band):
            try container.encode(CommandName.setBand, forKey: .cmd)
            try container.encode(band, forKey: .value)
        case .setPowerLevel(let level):
            try container.encode(CommandName.setPower, forKey: .cmd)
            try container.encode(level, forKey: .value)
        case .setBreakIn(let on):
            try container.encode(CommandName.setBreakIn, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setKeyer(let on):
            try container.encode(CommandName.setKeyer, forKey: .cmd)
            try container.encode(on, forKey: .value)
        }
    }
}

/// Server -> client push. Sent by the Mac hub whenever rigctld reports
/// a change, or as a full snapshot right after a client connects.
public struct RigStatePush: Codable, Sendable, Equatable {
    public let type: String  // "state" — reserved for future push types (e.g. "log", "error")
    public let state: RigState

    public init(state: RigState) {
        self.type = "state"
        self.state = state
    }
}

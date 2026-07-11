import Foundation

/// Snapshot of the FTX-1's live state, as reported by rigctld.
/// This is the single shared model both the Mac hub and mobile clients
/// render against — the Mac derives it from rigctld polling/events,
/// mobile derives it from WebSocket state pushes.
public struct RigState: Codable, Equatable, Sendable {
    public var frequencyHz: Int
    public var mode: RigMode
    public var band: String?
    public var powerWatts: Double?
    public var swr: Double?
    public var ptt: Bool
    public var lastUpdated: Date
    /// The other VFO's frequency (whichever isn't currently active) — see
    /// `RigctldClient.getSecondaryFrequency()`.
    public var secondaryFrequencyHz: Int?
    /// The other VFO's mode — see `RigctldClient.getSecondaryMode()`. Often
    /// nil in practice: reading it isn't reliable on every rig/backend.
    public var secondaryMode: RigMode?
    /// The RFPOWER *setting* (0.0–1.0, relative), not the metered output —
    /// that's `powerWatts`.
    public var powerLevel: Double?
    /// CW break-in (the FTX-1's raw "BI" CAT command) — nil until the first
    /// successful read, same as the other optional fields above.
    public var breakIn: Bool?
    /// CW electronic keyer on/off (the FTX-1's raw "KR" CAT command).
    public var keyerEnabled: Bool?

    public init(
        frequencyHz: Int = 0,
        mode: RigMode = .usb,
        band: String? = nil,
        powerWatts: Double? = nil,
        swr: Double? = nil,
        ptt: Bool = false,
        lastUpdated: Date = Date(),
        secondaryFrequencyHz: Int? = nil,
        secondaryMode: RigMode? = nil,
        powerLevel: Double? = nil,
        breakIn: Bool? = nil,
        keyerEnabled: Bool? = nil
    ) {
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.band = band
        self.powerWatts = powerWatts
        self.swr = swr
        self.ptt = ptt
        self.lastUpdated = lastUpdated
        self.secondaryFrequencyHz = secondaryFrequencyHz
        self.secondaryMode = secondaryMode
        self.powerLevel = powerLevel
        self.breakIn = breakIn
        self.keyerEnabled = keyerEnabled
    }
}

public enum RigMode: String, Codable, Sendable, CaseIterable, Hashable {
    case usb = "USB"
    case lsb = "LSB"
    case cw = "CW"
    case fm = "FM"
    case am = "AM"
    case rtty = "RTTY"
    case dataUSB = "PKTUSB"
    /// Yaesu's C4FM digital voice mode — this rig's hamlib backend reports
    /// it as "FM-D" (see `\dump_caps`'s mode list), not a dedicated "C4FM"
    /// string, so the raw value has to stay "FM-D" for `RigMode(rawValue:)`
    /// to recognize it; `displayName` shows the name operators actually use.
    case c4fm = "FM-D"
    case unknown = "UNKNOWN"

    public var displayName: String {
        switch self {
        case .c4fm: "C4FM"
        default: rawValue
        }
    }
}

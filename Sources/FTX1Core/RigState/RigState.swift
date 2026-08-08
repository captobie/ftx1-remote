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
    /// CW keyer speed in WPM, 4-60 (the FTX-1's raw "KS" CAT command).
    public var cwSpeedWpm: Int?
    /// CW sidetone/pitch in Hz, 300-1050 in 10Hz steps (the FTX-1's raw "KP"
    /// CAT command, which encodes this as 00-75 rather than Hz directly —
    /// see `CommandQueue`/`HubService` for the conversion).
    public var cwPitchHz: Int?
    /// CW (semi) break-in delay in milliseconds — one of `BreakInDelay.
    /// allValuesMs` (the FTX-1's raw "SD" CAT command, which encodes this as
    /// a non-linear 00-33 code rather than milliseconds directly — see
    /// `BreakInDelay`).
    public var bkDelayMs: Int?
    /// CW spot (sidetone-only zero-beat aid) on/off (the FTX-1's raw "CS"
    /// CAT command).
    public var cwSpot: Bool?
    /// Monitor (sidetone) level, 0-100 (the FTX-1's raw "ML" CAT command
    /// with its P1 sub-selector set to 1 — see `CommandQueue`/`HubService`).
    /// Separate from monitor on/off, which "ML" also carries under P1=0 but
    /// which this app doesn't expose — the physical MONI button handles
    /// that on the rig itself.
    public var moniLevel: Int?

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
        keyerEnabled: Bool? = nil,
        cwSpeedWpm: Int? = nil,
        cwPitchHz: Int? = nil,
        bkDelayMs: Int? = nil,
        cwSpot: Bool? = nil,
        moniLevel: Int? = nil
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
        self.cwSpeedWpm = cwSpeedWpm
        self.cwPitchHz = cwPitchHz
        self.bkDelayMs = bkDelayMs
        self.cwSpot = cwSpot
        self.moniLevel = moniLevel
    }
}

/// The FTX-1's raw "SD" CW break-in delay CAT command doesn't encode
/// milliseconds directly — it's a 2-digit code 00-33 per the CAT Operation
/// Reference Manual: codes 00-05 are fixed odd values (30/50/100/150/200/
/// 250ms), then 06-33 step linearly in 100ms increments up to 3000ms.
public enum BreakInDelay {
    /// Raw "SD" code (0-33) -> milliseconds. `nil` for any code outside
    /// that range.
    public static func milliseconds(forCode code: Int) -> Int? {
        switch code {
        case 0: 30
        case 1: 50
        case 2: 100
        case 3: 150
        case 4: 200
        case 5: 250
        case 6...33: 300 + (code - 6) * 100
        default: nil
        }
    }

    /// Reverse of `milliseconds(forCode:)`. Every value in `allValuesMs`
    /// round-trips through this exactly.
    public static func code(forMilliseconds ms: Int) -> Int? {
        (0...33).first { milliseconds(forCode: $0) == ms }
    }

    /// All valid values in order, for driving a UI stepper/picker.
    public static let allValuesMs: [Int] = (0...33).compactMap(milliseconds(forCode:))
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

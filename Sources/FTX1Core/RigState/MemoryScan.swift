import Foundation

/// The rig's own scan, per P7 of the raw "RI" (RADIO INFORMATION) answer —
/// see `RigState.memoryScan`. The app only starts it in Memory mode
/// (`RigCommand.setMemoryScan`), where it's the rig's memory scan.
public enum MemoryScanState: String, Codable, Sendable {
    case stopped
    case scanning
    /// Stopped on a busy channel; the rig resumes on its own per its SCAN
    /// RESUME menu setting, or when told to scan again (a Skip).
    case paused
}

/// The P2 of the raw "SC" (SCAN) command: off, or scanning up/down.
public enum MemoryScanDirection: String, Codable, Sendable {
    case off
    case up
    case down

    var catDigit: Int {
        switch self {
        case .off: return 0
        case .up: return 1
        case .down: return 2
        }
    }
}

/// The raw "RI0" answer: "RI" + P1..P8 + ";", one digit each. Probed against
/// the rig 2026-10-06: P7 0/1/2 = stopped/scanning/paused and P8 = squelch
/// open, as the manual says (e.g. "RI00000021;" paused on a busy channel).
/// Only the fields the app uses are kept.
public struct RadioInformation: Equatable, Sendable {
    /// P3: CW MESSAGE 0 stopped, 1 recording, 2 playing.
    public var cwMessageRaw: Int
    /// P4: 1 TX, 2 TX INHIBIT (both keyed), 0 RX.
    public var isTransmitting: Bool
    /// P7.
    public var scan: MemoryScanState
    /// P8: squelch open (BUSY).
    public var squelchOpen: Bool

    public init?(reply: String) {
        guard reply.hasPrefix("RI") else { return nil }
        let digits = Array(reply.dropFirst(2).prefix { $0.isNumber }).compactMap(\.wholeNumberValue)
        guard digits.count >= 8 else { return nil }
        cwMessageRaw = digits[2]
        isTransmitting = digits[3] != 0
        switch digits[6] {
        case 1: scan = .scanning
        case 2: scan = .paused
        default: scan = .stopped
        }
        squelchOpen = digits[7] == 1
    }
}

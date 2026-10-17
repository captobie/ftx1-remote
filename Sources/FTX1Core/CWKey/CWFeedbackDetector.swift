import Foundation

/// Spots RF feedback: the rig's own transmission getting into the key
/// interface's key input, so every keyed element comes back as a "press"
/// one loop later (playout delay + transport) and keys the rig again — a
/// self-sustaining oscillation. Seen 2026-10-17 in Remote mode: one tap
/// became ~190 ms marks repeating every ~310 ms; a bigger ferrite on the
/// key lead cured it.
///
/// The signature is a machine-steady period: in that capture the presses
/// started every 308.2 / 310.0 / 308.9 / 310.4 ms (2.2 ms spread) and
/// ended every 316.1 / 315.9 / 318.3 / 316.9 ms, a period of the playout
/// delay plus a little. A hand on a straight key can't repeat itself to a
/// few ms. So it trips on `requiredPeriods` consecutive mark-to-mark
/// periods whose starts agree within `spread`, whose ends agree within
/// `spread`, and which all lie between the playout delay and the delay +
/// `maxTransport`.
///
/// Only the operator's own events (the key interface's clock, seconds) are
/// needed, so the hub runs it in both modes. Known limit, for when the
/// paddle path returns: an electronic keyer's dit run is just as steady,
/// and would trip it if its period (two dit lengths) fell inside that
/// band — e.g. 7–16 WPM at the 150 ms Local delay.
public struct CWFeedbackDetector: Sendable {
    public var loopDelay: Double
    public var spread: Double
    public var requiredPeriods: Int
    public var maxTransport: Double

    private var marks: [(down: Double, up: Double)] = []
    private var openDown: Double?
    public private(set) var tripped = false

    public static let defaultSpread = 0.006
    public static let defaultRequiredPeriods = 4
    public static let defaultMaxTransport = 0.25

    public init(loopDelay: Double, spread: Double = defaultSpread,
                requiredPeriods: Int = defaultRequiredPeriods, maxTransport: Double = defaultMaxTransport) {
        self.loopDelay = loopDelay
        self.spread = spread
        self.requiredPeriods = requiredPeriods
        self.maxTransport = maxTransport
    }

    /// The operator's key changed at `time` (key interface seconds,
    /// unwrapped). Returns true once tripped.
    @discardableResult
    public mutating func operatorChanged(down: Bool, at time: Double) -> Bool {
        if down {
            openDown = time
            return tripped
        }
        guard let start = openDown else { return tripped }
        openDown = nil
        marks.append((start, time))
        if marks.count > requiredPeriods + 1 { marks.removeFirst(marks.count - requiredPeriods - 1) }
        guard marks.count == requiredPeriods + 1 else { return tripped }
        let downPeriods = zip(marks, marks.dropFirst()).map { $1.down - $0.down }
        let upPeriods = zip(marks, marks.dropFirst()).map { $1.up - $0.up }
        let band = loopDelay...(loopDelay + maxTransport)
        if (downPeriods + upPeriods).allSatisfy({ band.contains($0) }),
           downPeriods.max()! - downPeriods.min()! <= spread,
           upPeriods.max()! - upPeriods.min()! <= spread {
            tripped = true
        }
        return tripped
    }

    /// Forgets the marks (the device clock restarted) but not a trip.
    public mutating func clearHistory() {
        marks.removeAll()
        openDown = nil
    }

    /// A new session (re-armed): everything, including a trip.
    public mutating func reset() {
        clearHistory()
        tripped = false
    }
}

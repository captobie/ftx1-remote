import Foundation

/// Decides whether the keying line may be down. The operator's played-out
/// key state (`request`) only keys the rig while every condition holds:
/// armed, key interface connected and heard from within
/// `heartbeatTimeout`, the keying port working, and no transmit block
/// (Enable Transmit, amateur band — `TransmitGate`). Losing any of them
/// forces key-up at once.
///
/// **Latch**: once a hold has been refused or cut off — any condition
/// failing while the operator is down, or a key-down outlasting
/// `maxKeyDown` — the line stays up until the operator's next key-up,
/// even if the condition comes back. So arming, a heartbeat resuming or
/// Enable Transmit coming back on never keys the rig in the middle of a
/// hold; only a fresh key-down does.
///
/// Pure value type, times in host seconds; the driver calls `tick` by
/// `nextDeadline` so the timeouts fire without a new event.
public struct CWKeyingSafety: Sendable {
    public enum Cutoff: Sendable, Equatable {
        case disarmed
        case linkDown
        case heartbeatTimeout
        case keyerUnavailable
        case blocked(String)
        case maxKeyDown
        /// Reported by the far end (the Pi's keyer), as display text.
        case remote(String)

        /// For the UI.
        public var description: String {
            switch self {
            case .disarmed: "Not armed"
            case .linkDown: "Key interface not connected"
            case .heartbeatTimeout: "Key interface stopped responding"
            case .keyerUnavailable: "Keying port not open"
            case .blocked(let reason): reason
            case .maxKeyDown: "Key held too long — release the key"
            case .remote(let reason): reason
            }
        }
    }

    public static let defaultHeartbeatTimeout = 0.5
    public static let defaultMaxKeyDown = 5.0

    public var heartbeatTimeout: Double
    public var maxKeyDown: Double

    public private(set) var armed = false
    public private(set) var linkUp = false
    public private(set) var keyerReady = false
    public private(set) var blockReason: String?
    private var lastHeard: Double?
    /// The heartbeat timeout has passed (so its deadline is not pending).
    private var heartbeatExpired = false

    /// The operator's key, as played out by the jitter buffer.
    public private(set) var requested = false
    /// The keying line's state.
    public private(set) var keyed = false
    private var keyedSince: Double?
    /// Why the current hold is refused, until the operator's next key-up.
    public private(set) var latch: Cutoff?

    public init(heartbeatTimeout: Double = defaultHeartbeatTimeout, maxKeyDown: Double = defaultMaxKeyDown) {
        self.heartbeatTimeout = heartbeatTimeout
        self.maxKeyDown = maxKeyDown
    }

    // MARK: - Inputs

    public mutating func setArmed(_ armed: Bool, now: Double) {
        self.armed = armed
        update(now: now)
    }

    public mutating func setLinkUp(_ up: Bool, now: Double) {
        linkUp = up
        if !up { lastHeard = nil }
        update(now: now)
    }

    /// Any line received from the key interface, at its receive time.
    public mutating func heard(at time: Double, now: Double) {
        lastHeard = max(lastHeard ?? time, time)
        update(now: now)
    }

    /// The keying port opened (true) or failed/closed (false).
    public mutating func setKeyerReady(_ ready: Bool, now: Double) {
        keyerReady = ready
        update(now: now)
    }

    /// nil when transmitting is allowed, else why not.
    public mutating func setBlockReason(_ reason: String?, now: Double) {
        blockReason = reason
        update(now: now)
    }

    /// The operator's key went down/up (played out).
    public mutating func request(down: Bool, now: Double) {
        requested = down
        if !down { latch = nil }
        update(now: now)
    }

    /// Re-checks the timeouts.
    public mutating func tick(now: Double) {
        update(now: now)
    }

    // MARK: - State

    /// The first condition currently stopping keying, ignoring the latch.
    public func cutoff(now: Double) -> Cutoff? {
        if !armed { return .disarmed }
        if !keyerReady { return .keyerUnavailable }
        if !linkUp { return .linkDown }
        guard let lastHeard, now - lastHeard < heartbeatTimeout else { return .heartbeatTimeout }
        if let blockReason { return .blocked(blockReason) }
        return nil
    }

    /// When `tick` next has to run for a timeout to fire on time.
    public var nextDeadline: Double? {
        var deadlines: [Double] = []
        if linkUp, !heartbeatExpired, let lastHeard { deadlines.append(lastHeard + heartbeatTimeout) }
        if keyed, let keyedSince { deadlines.append(keyedSince + maxKeyDown) }
        return deadlines.min()
    }

    private mutating func update(now: Double) {
        heartbeatExpired = lastHeard.map { now - $0 >= heartbeatTimeout } ?? true
        if requested, latch == nil {
            if let cutoff = cutoff(now: now) {
                latch = cutoff
            } else if keyed, let keyedSince, now - keyedSince >= maxKeyDown {
                latch = .maxKeyDown
            }
        }
        let shouldKey = requested && latch == nil
        if shouldKey != keyed {
            keyed = shouldKey
            keyedSince = shouldKey ? now : nil
        }
    }
}

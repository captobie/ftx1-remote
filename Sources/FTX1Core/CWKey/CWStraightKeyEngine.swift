import Foundation

/// Straight-key events in, keying-line state out: device clock unwrap →
/// clock sync → jitter buffer → safety. Pure value type with no threads or
/// timers of its own — the driver feeds it source events and host times,
/// calls `tick` at `nextDeadline`, and sets the key line to `keyed` after
/// every call. That keeps the whole path testable with a fake clock.
public struct CWStraightKeyEngine: Sendable {
    public private(set) var safety: CWKeyingSafety
    public private(set) var buffer: CWJitterBuffer
    private var clock = CWDeviceClockUnwrapper()
    private var sync = CWClockSync()
    /// A device time has been seen since the last restart.
    private var sessionStarted = false

    public private(set) var link: CWKeyLinkState = .closed
    public private(set) var deviceStatus: CWKeyDeviceStatus?
    /// Times the device restarted while connected (banner or clock jump).
    public private(set) var restartCount = 0

    public init(playoutDelay: Double = CWJitterBuffer.defaultPlayoutDelay,
                heartbeatTimeout: Double = CWKeyingSafety.defaultHeartbeatTimeout,
                maxKeyDown: Double = CWKeyingSafety.defaultMaxKeyDown) {
        buffer = CWJitterBuffer(playoutDelay: playoutDelay)
        safety = CWKeyingSafety(heartbeatTimeout: heartbeatTimeout, maxKeyDown: maxKeyDown)
    }

    /// The key line's state.
    public var keyed: Bool { safety.keyed }

    /// The operator's key as played out (what the UI's indicator shows
    /// next to `keyed`).
    public var operatorKeyDown: Bool { safety.requested }

    public var clockOffset: Double? { sync.offset }

    public var nextDeadline: Double? {
        [buffer.nextDeadline, safety.nextDeadline].compactMap { $0 }.min()
    }

    // MARK: - Settings and gates

    public mutating func setPlayoutDelay(_ seconds: Double) {
        buffer.playoutDelay = seconds
    }

    public mutating func setMaxKeyDown(_ seconds: Double, now: Double) {
        safety.maxKeyDown = seconds
        safety.tick(now: now)
    }

    public mutating func setArmed(_ armed: Bool, now: Double) {
        safety.setArmed(armed, now: now)
    }

    public mutating func setKeyerReady(_ ready: Bool, now: Double) {
        safety.setKeyerReady(ready, now: now)
    }

    public mutating func setBlockReason(_ reason: String?, now: Double) {
        safety.setBlockReason(reason, now: now)
    }

    // MARK: - Events

    public mutating func ingest(_ event: CWKeySourceEvent, now: Double) {
        switch event {
        case .link(let state):
            link = state
            if !state.isConnected { restart(now: now) }
            safety.setLinkUp(state.isConnected, now: now)
        case .line(let line, let received):
            ingest(line, received: received, now: now)
        }
        tick(now: now)
    }

    /// Plays out what's due and re-checks the safety timeouts. Transitions
    /// are applied at their own play time; if a late call finds a down and
    /// its up both due, only the final state shows in `keyed` — the element
    /// is dropped rather than sent as a glitch.
    public mutating func tick(now: Double) {
        for transition in buffer.popDue(now: now) {
            safety.request(down: transition.down, now: transition.playAt)
        }
        safety.tick(now: now)
    }

    private mutating func ingest(_ line: CWKeyLine, received: Double, now: Double) {
        if case .banner = line {
            // A (re)booted device: its clock restarts at 0 and anything
            // still buffered belongs to the old session.
            if sessionStarted { restartCount += 1 }
            restart(now: now)
        }
        if case .status(let status) = line { deviceStatus = status }
        guard let deviceMs = line.deviceMs else {
            safety.heard(at: received, now: now)
            return
        }
        let unwrapped = clock.unwrap(deviceMs)
        sessionStarted = true
        if unwrapped.restarted {
            restartCount += 1
            restart(now: now, keepingClock: true)
        }
        sync.add(deviceMs: unwrapped.ms, hostReceived: received)
        safety.heard(at: received, now: now)
        guard let offset = sync.offset else { return }
        switch line {
        case .keyDown: buffer.enqueue(down: true, deviceMs: unwrapped.ms, offset: offset, now: now)
        case .keyUp: buffer.enqueue(down: false, deviceMs: unwrapped.ms, offset: offset, now: now)
        default: break
        }
    }

    /// Forgets the device session: clock (unless the unwrapper has just
    /// rebased it itself), offset, pending transitions, and the operator's
    /// key — released, since the device doesn't resend its state.
    private mutating func restart(now: Double, keepingClock: Bool = false) {
        if !keepingClock {
            clock.reset()
            sessionStarted = false
        }
        sync.reset()
        buffer.flush()
        if safety.requested {
            safety.request(down: false, now: now)
        }
    }
}

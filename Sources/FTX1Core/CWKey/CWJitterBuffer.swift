import Foundation

/// Plays the operator's key transitions out at their original spacing.
///
/// Each transition is scheduled for `deviceTime + offset + playoutDelay`
/// (`CWClockSync`'s offset), so however unevenly the bytes arrive, the
/// element and space lengths that come out are the ones the operator keyed
/// — the fist survives, at the cost of a fixed delay.
///
/// A transition that arrives too late for that slot (a USB or scheduling
/// hiccup longer than the playout delay) is played as soon as possible but
/// still at least its keyed distance after the previous one, so a late
/// burst doesn't squash dits into nothing. That pushes the following ones
/// late too. Marks and character-length spaces keep their length; a space
/// longer than `catchUpSpace` (a word space or a pause) is shortened, down
/// to that length, to get back to the normal delay. Nothing is held more
/// than `maxExtraHold` beyond `now + playoutDelay`.
///
/// Pure value type: the caller passes host times in and asks what's due.
public struct CWJitterBuffer: Sendable {
    public struct Transition: Sendable, Equatable {
        public var down: Bool
        /// Host seconds.
        public var playAt: Double
    }

    /// Seconds between a transition being keyed and being played.
    public var playoutDelay: Double
    /// Seconds a late transition may be held beyond `now + playoutDelay` to
    /// keep its spacing; past that it is shortened.
    public var maxExtraHold: Double
    /// Seconds: spaces longer than this may shrink to it to catch up.
    /// 0.3 s is a word space at ~28 WPM and longer than any letter space
    /// down to ~12 WPM.
    public var catchUpSpace: Double

    private var pending: [Transition] = []
    /// The last transition accepted, to keep spacing and drop repeats.
    private var last: (down: Bool, playAt: Double, deviceMs: Int64)?

    public static let defaultPlayoutDelay = 0.150

    public init(playoutDelay: Double = defaultPlayoutDelay, maxExtraHold: Double = 0.25, catchUpSpace: Double = 0.3) {
        self.playoutDelay = playoutDelay
        self.maxExtraHold = maxExtraHold
        self.catchUpSpace = catchUpSpace
    }

    /// Schedules a transition keyed at `deviceMs` (unwrapped), given the
    /// current clock offset and host time. A repeat of the previous state
    /// (two downs in a row) is ignored.
    public mutating func enqueue(down: Bool, deviceMs: Int64, offset: Double, now: Double) {
        if let last, last.down == down { return }
        var playAt = Double(deviceMs) / 1000 + offset + playoutDelay
        if let last {
            var spacing = max(0, Double(deviceMs - last.deviceMs) / 1000)
            if down { spacing = min(spacing, catchUpSpace) }   // this ends a space
            let spaced = min(last.playAt + spacing, now + playoutDelay + maxExtraHold)
            playAt = max(playAt, spaced)
            // Never before the previous one, whatever the clock did.
            playAt = max(playAt, last.playAt)
        }
        playAt = max(playAt, now)
        pending.append(Transition(down: down, playAt: playAt))
        last = (down, playAt, deviceMs)
    }

    /// Removes and returns every transition due by `now`, in order.
    public mutating func popDue(now: Double) -> [Transition] {
        guard let firstLater = pending.firstIndex(where: { $0.playAt > now }) else {
            defer { pending.removeAll() }
            return pending
        }
        let due = Array(pending[..<firstLater])
        pending.removeFirst(firstLater)
        return due
    }

    /// When the next transition is due, nil if none is waiting.
    public var nextDeadline: Double? { pending.first?.playAt }

    public var isEmpty: Bool { pending.isEmpty }

    /// Drops everything waiting and forgets the last state — on link loss,
    /// a device restart or a safety cutoff.
    public mutating func flush() {
        pending.removeAll()
        last = nil
    }
}

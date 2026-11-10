import Foundation

/// When the MyKiwiSDR window's recording ("Local SDR" in code) starts a new
/// file: one file per frequency, like the WebSDR window, without splitting
/// on every scroll-wheel step.
///
/// A tune splits only if it moved at least `toleranceHz` from the tuning
/// the current file started at (its name), or changed the mode, *and* has
/// held for `settleSeconds`. So nudging a CW signal to zero beat, or a
/// spun wheel passing through, stays in one file; a retune that sticks
/// starts a new one ~1 s later (that second of new audio ends up at the
/// end of the old file). Moving back to the file's own tuning cancels a
/// pending split. Pure, on a caller-supplied clock.
public struct KiwiRecordingSplit: Equatable, Sendable {
    public struct Tuning: Equatable, Sendable {
        public var frequencyHz: Int
        public var mode: KiwiSDRMode

        public init(frequencyHz: Int, mode: KiwiSDRMode) {
            self.frequencyHz = frequencyHz
            self.mode = mode
        }
    }

    public static let toleranceHz = 500
    public static let settleSeconds: TimeInterval = 1

    /// What the current file is named after.
    public private(set) var fileTuning: Tuning
    private var pending: Tuning?
    private var pendingSince: TimeInterval = 0

    public init(fileTuning: Tuning) {
        self.fileTuning = fileTuning
    }

    /// When the caller should call `update` again (the pending split's
    /// settle time), or nil when no split is pending.
    public var nextCheck: TimeInterval? {
        pending == nil ? nil : pendingSince + Self.settleSeconds
    }

    /// Call on every tune, and again at `nextCheck`. Returns the tuning to
    /// start a new file at, or nil to keep writing the current one.
    public mutating func update(tuning: Tuning, now: TimeInterval) -> Tuning? {
        guard differsFromFile(tuning) else {
            pending = nil
            return nil
        }
        if pending != tuning {
            pending = tuning
            pendingSince = now
            return nil
        }
        guard now - pendingSince >= Self.settleSeconds else { return nil }
        fileTuning = tuning
        pending = nil
        return tuning
    }

    private func differsFromFile(_ tuning: Tuning) -> Bool {
        tuning.mode != fileTuning.mode || abs(tuning.frequencyHz - fileTuning.frequencyHz) >= Self.toleranceHz
    }
}

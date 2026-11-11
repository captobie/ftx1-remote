import Foundation

// MARK: - Mode mapping (shared with the WebSDR window's KiwiSDRURLBuilder)

extension KiwiSDRMode {
    /// The Kiwi mode a rig mode follows to, or nil to tune the frequency
    /// only and leave the Kiwi's mode as it is. DATA-U is plain USB
    /// demodulation on the rig, so USB on the Kiwi makes FT8 etc. audible
    /// there too. RTTY (its mark/space sideband is ambiguous), DATA-FM and
    /// C4FM (digital) have no sensible Kiwi equivalent. The rig reports
    /// CW-R as CW.
    public init?(rigMode: RigMode) {
        switch rigMode {
        case .usb, .dataUSB: self = .usb
        case .lsb: self = .lsb
        case .cw: self = .cw
        case .am: self = .am
        case .fm: self = .fm
        case .rtty, .dataFM, .c4fm, .unknown: return nil
        }
    }

    /// The rig mode with the same demodulation.
    public var rigMode: RigMode {
        switch self {
        case .usb: .usb
        case .lsb: .lsb
        case .cw: .cw
        case .am: .am
        case .fm: .fm
        }
    }

    /// The rig mode to set when the Kiwi is tuned to this mode, or nil to
    /// leave the rig's mode alone: when the rig's mode already follows to
    /// this one (so DATA-U stays DATA-U under a Kiwi in USB), and when the
    /// rig's mode has no Kiwi equivalent (RTTY, DATA-FM, C4FM — following
    /// never set the Kiwi's mode from those, so the Kiwi's mode says
    /// nothing about what the rig should be in). The WebSDR window's rule
    /// (`SDRPlatform.rigMode(forPageMode:current:)`).
    public func rigMode(current: RigMode) -> RigMode? {
        guard let followed = KiwiSDRMode(rigMode: current), followed != self else { return nil }
        return rigMode
    }
}

// MARK: - The two directions between a Kiwi and the rig

/// What the rig looks like to the Local SDR window's Tune rig direction.
public struct KiwiRigSnapshot: Equatable, Sendable {
    public var connected: Bool
    public var transmitting: Bool
    public var memoryMode: Bool
    public var frequencyHz: Int
    public var mode: RigMode

    public init(connected: Bool, transmitting: Bool, memoryMode: Bool, frequencyHz: Int, mode: RigMode) {
        self.connected = connected
        self.transmitting = transmitting
        self.memoryMode = memoryMode
        self.frequencyHz = frequencyHz
        self.mode = mode
    }
}

/// The rules between the Local SDR window's Kiwi and the rig's MAIN VFO,
/// both ways, kept pure (time comes in as `now`, seconds on any monotonic
/// clock) so they can be tested with a fake clock. Ports the WebSDR
/// window's rules (`WebSDRFollowModel`): Follow tunes the Kiwi to the rig,
/// Tune rig tunes the rig to what the window tuned, and after the window
/// tunes the rig the rig's not-yet-updated values are ignored for
/// `rigTuneGrace` seconds (`pendingRigTune`), so the two can't fight.
public struct KiwiRigLink: Equatable, Sendable {
    /// How long a rig value that hasn't caught up with the window's tune
    /// is ignored.
    public static let rigTuneGrace: TimeInterval = 3
    /// Rig and Kiwi count as on the same frequency within this.
    public static let sameFrequencyToleranceHz = 10

    public struct PendingRigTune: Equatable, Sendable {
        public var frequencyHz: Int
        /// nil: the window's tune didn't change the rig's mode.
        public var mode: RigMode?
        public var until: TimeInterval
    }

    public enum FollowDecision: Equatable, Sendable {
        /// Tune the Kiwi; `mode` nil = keep the Kiwi's mode.
        case tune(frequencyHz: Int, mode: KiwiSDRMode?)
        /// The Kiwi is already where the rig is.
        case alreadyThere
        /// The rig hasn't caught up with the window's last tune yet.
        case waitingForRig
        case noRigFrequency
        /// Above the Kiwi's reported bandwidth.
        case outOfRange(frequencyHz: Int)
    }

    public enum Refusal: Equatable, Sendable {
        case rigDisconnected
        case noRigFrequency
        case transmitting
        case memoryMode
    }

    public enum TuneRigDecision: Equatable, Sendable {
        /// Send these (nil = leave that one alone).
        case send(frequencyHz: Int?, mode: RigMode?)
        /// The rig is already there.
        case nothing
        case refused(Refusal)
    }

    public private(set) var pendingRigTune: PendingRigTune?

    public init() {}

    /// The rig's (debounced) MAIN frequency and mode changed, or Follow
    /// was turned on: where the Kiwi should go.
    public mutating func follow(rigFrequencyHz: Int, rigMode: RigMode,
                                kiwiFrequencyHz: Int, kiwiMode: KiwiSDRMode,
                                maxFrequencyHz: Int, now: TimeInterval) -> FollowDecision {
        if let pending = pendingRigTune {
            let caughtUp = Self.same(rigFrequencyHz, pending.frequencyHz)
                && (pending.mode == nil || pending.mode == rigMode)
            guard caughtUp || now >= pending.until else { return .waitingForRig }
            pendingRigTune = nil
        }
        guard rigFrequencyHz > 0 else { return .noRigFrequency }
        guard rigFrequencyHz <= maxFrequencyHz else { return .outOfRange(frequencyHz: rigFrequencyHz) }
        let mode = KiwiSDRMode(rigMode: rigMode)
        let modeMatches = mode == nil || mode == kiwiMode
        if Self.same(rigFrequencyHz, kiwiFrequencyHz) && modeMatches { return .alreadyThere }
        return .tune(frequencyHz: rigFrequencyHz, mode: modeMatches ? nil : mode)
    }

    /// The window tuned the Kiwi (entry, click, scroll, drag, mode
    /// picker): what to send the rig. A refusal leaves the Kiwi where the
    /// window put it.
    public mutating func windowTuned(kiwiFrequencyHz: Int, kiwiMode: KiwiSDRMode,
                                     rig: KiwiRigSnapshot, now: TimeInterval) -> TuneRigDecision {
        if let pending = pendingRigTune, now >= pending.until { pendingRigTune = nil }
        // What the rig is about to be (a send still on its way), so a mode
        // change right after a frequency change isn't sent twice.
        let rigFrequency = pendingRigTune?.frequencyHz ?? rig.frequencyHz
        let rigMode = pendingRigTune?.mode ?? rig.mode
        let frequencyChanged = !Self.same(kiwiFrequencyHz, rigFrequency)
        let newMode = kiwiMode.rigMode(current: rigMode)
        guard frequencyChanged || newMode != nil else { return .nothing }
        if let refusal = Self.refusal(for: rig) { return .refused(refusal) }
        pendingRigTune = PendingRigTune(frequencyHz: kiwiFrequencyHz,
                                        mode: newMode ?? pendingRigTune?.mode,
                                        until: now + Self.rigTuneGrace)
        return .send(frequencyHz: frequencyChanged ? kiwiFrequencyHz : nil, mode: newMode)
    }

    /// Why the rig can't be tuned from the window right now, if it can't.
    public static func refusal(for rig: KiwiRigSnapshot) -> Refusal? {
        if !rig.connected { return .rigDisconnected }
        if rig.frequencyHz <= 0 { return .noRigFrequency }
        if rig.transmitting { return .transmitting }
        // The rig rejects a VFO frequency set in Memory mode.
        if rig.memoryMode { return .memoryMode }
        return nil
    }

    /// Clears an expired pending tune; true when it did (follow the rig's
    /// actual state again — the tune was rejected or never arrived).
    public mutating func expirePending(now: TimeInterval) -> Bool {
        guard let pending = pendingRigTune, now >= pending.until else { return false }
        pendingRigTune = nil
        return true
    }

    /// Disconnect, or Tune rig turned off.
    public mutating func reset() { pendingRigTune = nil }

    private static func same(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= sameFrequencyToleranceHz }
}

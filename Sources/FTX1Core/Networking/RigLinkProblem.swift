import Foundation

/// Why the hub isn't talking to the rig, sorted by where the fault is,
/// since each points to a different fix: the computer running rigctld (the
/// Pi in Remote mode) can't be reached, it can be reached but rigctld isn't
/// running on it, or rigctld is fine but the radio behind it doesn't
/// answer. The last one is what the Pi's under-voltage USB drops look like
/// (rigctld keeps accepting TCP and never answers a CAT read), and what an
/// unplugged or switched-off rig looks like in either mode.
public enum RigLinkProblem: Equatable, Sendable {
    /// The host name doesn't resolve (with a MagicDNS name, usually
    /// Tailscale being off on this computer).
    case hostNotFound
    /// No answer from the host at all: it's off, or not on the network.
    case hostUnreachable
    /// The host answers, but nothing listens on rigctld's port.
    case rigctldNotRunning
    /// rigctld answers, but the radio doesn't (`RigResponseMonitor`).
    case rigNotResponding
    /// An established connection dropped; the hub is reconnecting.
    case connectionLost
    /// Anything else, with the error's own description.
    case other(String)

    /// Sorts a connect or poll failure. `RigctldError`s carry where it
    /// failed; anything else is `.other`.
    public init(error: Error) {
        switch error as? RigctldError {
        case .hostNotFound: self = .hostNotFound
        case .connectTimedOut: self = .hostUnreachable
        case .connectionRefused: self = .rigctldNotRunning
        case .connectionLost, .notConnected: self = .connectionLost
        case .rawCommandTimedOut, .replyTimedOut: self = .rigNotResponding
        default: self = .other(error.localizedDescription)
        }
    }

    /// The host itself is the problem (vs. rigctld or the radio on it).
    public var isHostProblem: Bool {
        self == .hostNotFound || self == .hostUnreachable
    }
}

/// Counts the poll loop's main-frequency reads ("FA") in a row that got no
/// usable answer, so a silent rig is reported without one dropped reply
/// tripping it. "FA" is the one read the rig always answers, in every mode
/// (unlike e.g. "GT0" in C4FM), so its failing over and over means the rig
/// itself is gone — rigctld is still there, or the read would have thrown
/// `.connectionLost`/`.notConnected` instead.
public struct RigResponseMonitor: Sendable {
    public enum Change: Equatable, Sendable {
        /// The rig answered for the first time since connecting, or again
        /// after being reported silent.
        case answering
        /// `threshold` reads in a row failed.
        case notResponding
    }

    /// 3 in a row. Each failed read waits out its 1 s raw-CAT timeout,
    /// and the hub's fast frequency lane does too until the report, so a
    /// dead rig is reported in about 10 s (11 s measured against a silent
    /// fake rigctld, 2026-11-12).
    public let threshold: Int
    public private(set) var consecutiveFailures = 0
    /// nil until the first answer or the first report.
    public private(set) var isAnswering: Bool?

    public init(threshold: Int = 3) {
        self.threshold = max(1, threshold)
    }

    /// Records one read; returns a change worth reporting, if any.
    public mutating func record(answered: Bool) -> Change? {
        if answered {
            consecutiveFailures = 0
            guard isAnswering != true else { return nil }
            isAnswering = true
            return .answering
        }
        consecutiveFailures += 1
        guard consecutiveFailures >= threshold, isAnswering != false else { return nil }
        isAnswering = false
        return .notResponding
    }
}

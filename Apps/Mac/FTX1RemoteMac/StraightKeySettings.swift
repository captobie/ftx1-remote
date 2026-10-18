import FTX1Core
import Foundation

/// Tools → CW Key's settings, backed by `UserDefaults` directly
/// (same pattern as `LogbookSettings`) so the keying driver's queue can
/// read them. `nonisolated`: `CWKeyingDriver` builds its keyer off the
/// main actor. Armed is deliberately not stored — it's off at every launch.
nonisolated enum StraightKeySettings {
    static let interfacePortKey = "cw.straightKey.interfacePort"
    static let keyingPortKey = "cw.straightKey.keyingPort"
    static let keyingLineKey = "cw.straightKey.keyingLine"
    static let invertedPolarityKey = "cw.straightKey.invertedPolarity"
    static let playoutDelayMsKey = "cw.straightKey.playoutDelayMs"
    static let remotePlayoutDelayMsKey = "cw.straightKey.remotePlayoutDelayMs"
    static let remoteHeartbeatTimeoutMsKey = "cw.straightKey.remoteHeartbeatTimeoutMs"
    static let maxKeyDownSecondsKey = "cw.straightKey.maxKeyDownSeconds"
    static let keyerWPMKey = "cw.straightKey.keyerWPM"
    static let keyerFollowsRigKey = "cw.straightKey.keyerFollowsRig"
    static let iambicModeBKey = "cw.straightKey.iambicModeB"
    static let paddleReversedKey = "cw.straightKey.paddleReversed"
    static let sidetoneOnKey = "cw.straightKey.sidetoneOn"

    static let playoutDelayRange = 20...1000
    static let maxKeyDownRange = 1...60
    static let remoteHeartbeatRange = 300...5000
    /// The sketch's own "W" range.
    static let keyerWPMRange = 5...50
    /// Remote mode's defaults leave room for Tailscale's jitter.
    static let defaultRemotePlayoutDelayMs = 300
    static let defaultRemoteHeartbeatTimeoutMs = 1000

    /// The Arduino key interface's port; empty = not set.
    static var interfacePort: String {
        get { UserDefaults.standard.string(forKey: interfacePortKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: interfacePortKey) }
    }

    /// The rig's second USB port (CP2105 "Standard COM Port"); empty = not
    /// set. Never the CAT port rigctld uses.
    static var keyingPort: String {
        get { UserDefaults.standard.string(forKey: keyingPortKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: keyingPortKey) }
    }

    static var keyingLine: CWKeyingLine {
        get { UserDefaults.standard.string(forKey: keyingLineKey).flatMap(CWKeyingLine.init(rawValue:)) ?? .rts }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: keyingLineKey) }
    }

    /// Line *cleared* = key down. Off by default: see `ModemLineCWKeyer`
    /// for why normal polarity is the safe one.
    static var invertedPolarity: Bool {
        get { UserDefaults.standard.bool(forKey: invertedPolarityKey) }
        set { UserDefaults.standard.set(newValue, forKey: invertedPolarityKey) }
    }

    /// Local and Remote are stored apart.
    static func playoutDelayMs(remote: Bool) -> Int {
        let key = remote ? remotePlayoutDelayMsKey : playoutDelayMsKey
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return remote ? defaultRemotePlayoutDelayMs : Int(CWJitterBuffer.defaultPlayoutDelay * 1000)
        }
        return UserDefaults.standard.integer(forKey: key).clampedTo(playoutDelayRange)
    }

    static func setPlayoutDelayMs(_ value: Int, remote: Bool) {
        UserDefaults.standard.set(value.clampedTo(playoutDelayRange),
                                  forKey: remote ? remotePlayoutDelayMsKey : playoutDelayMsKey)
    }

    static var remoteHeartbeatTimeoutMs: Int {
        get {
            guard UserDefaults.standard.object(forKey: remoteHeartbeatTimeoutMsKey) != nil else {
                return defaultRemoteHeartbeatTimeoutMs
            }
            return UserDefaults.standard.integer(forKey: remoteHeartbeatTimeoutMsKey).clampedTo(remoteHeartbeatRange)
        }
        set { UserDefaults.standard.set(newValue.clampedTo(remoteHeartbeatRange), forKey: remoteHeartbeatTimeoutMsKey) }
    }

    static var maxKeyDownSeconds: Int {
        get {
            guard UserDefaults.standard.object(forKey: maxKeyDownSecondsKey) != nil else {
                return Int(CWKeyingSafety.defaultMaxKeyDown)
            }
            return UserDefaults.standard.integer(forKey: maxKeyDownSecondsKey).clampedTo(maxKeyDownRange)
        }
        set { UserDefaults.standard.set(newValue.clampedTo(maxKeyDownRange), forKey: maxKeyDownSecondsKey) }
    }

    // The paddle keyer in the key interface. Sent to it whenever it
    // connects or reports something else (`StraightKeyController`); the
    // sketch's own boot defaults are 20 WPM, mode B, not reversed,
    // sidetone on, so these default to the same.

    static var keyerWPM: Int {
        get {
            guard UserDefaults.standard.object(forKey: keyerWPMKey) != nil else { return 20 }
            return UserDefaults.standard.integer(forKey: keyerWPMKey).clampedTo(keyerWPMRange)
        }
        set { UserDefaults.standard.set(newValue.clampedTo(keyerWPMRange), forKey: keyerWPMKey) }
    }

    /// The paddle's speed follows the rig's keyer speed ("KS").
    static var keyerFollowsRig: Bool {
        get { UserDefaults.standard.bool(forKey: keyerFollowsRigKey) }
        set { UserDefaults.standard.set(newValue, forKey: keyerFollowsRigKey) }
    }

    static var iambicModeB: Bool {
        get { UserDefaults.standard.object(forKey: iambicModeBKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: iambicModeBKey) }
    }

    static var paddleReversed: Bool {
        get { UserDefaults.standard.bool(forKey: paddleReversedKey) }
        set { UserDefaults.standard.set(newValue, forKey: paddleReversedKey) }
    }

    static var sidetoneOn: Bool {
        get { UserDefaults.standard.object(forKey: sidetoneOnKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: sidetoneOnKey) }
    }

    static func clampedKeyerWPM(_ wpm: Int) -> Int { wpm.clampedTo(keyerWPMRange) }

    /// `/dev/tty.X` and `/dev/cu.X` are the same device; rigctld's saved
    /// path uses `tty.`.
    static func sameDevice(_ a: String, _ b: String) -> Bool {
        func normalized(_ path: String) -> String { path.replacingOccurrences(of: "/dev/tty.", with: "/dev/cu.") }
        return !a.isEmpty && !b.isEmpty && normalized(a) == normalized(b)
    }
}

private nonisolated extension Int {
    func clampedTo(_ range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

import FTX1Core
import Foundation

/// Tools → Straight Key's settings, backed by `UserDefaults` directly
/// (same pattern as `LogbookSettings`) so the keying driver's queue can
/// read them. `nonisolated`: `CWKeyingDriver` builds its keyer off the
/// main actor. Armed is deliberately not stored — it's off at every launch.
nonisolated enum StraightKeySettings {
    static let interfacePortKey = "cw.straightKey.interfacePort"
    static let keyingPortKey = "cw.straightKey.keyingPort"
    static let keyingLineKey = "cw.straightKey.keyingLine"
    static let invertedPolarityKey = "cw.straightKey.invertedPolarity"
    static let playoutDelayMsKey = "cw.straightKey.playoutDelayMs"
    static let maxKeyDownSecondsKey = "cw.straightKey.maxKeyDownSeconds"

    static let playoutDelayRange = 20...1000
    static let maxKeyDownRange = 1...60

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

    static var playoutDelayMs: Int {
        get {
            guard UserDefaults.standard.object(forKey: playoutDelayMsKey) != nil else {
                return Int(CWJitterBuffer.defaultPlayoutDelay * 1000)
            }
            return UserDefaults.standard.integer(forKey: playoutDelayMsKey).clampedTo(playoutDelayRange)
        }
        set { UserDefaults.standard.set(newValue.clampedTo(playoutDelayRange), forKey: playoutDelayMsKey) }
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

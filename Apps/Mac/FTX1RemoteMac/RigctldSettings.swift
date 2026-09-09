import Foundation

/// Launch configuration for the `rigctld` process, backed by
/// `UserDefaults` directly rather than `@AppStorage` — `HubService` (not a
/// SwiftUI `View`) needs to read these too, and both it and `SettingsView`
/// read/write the same keys so they stay in sync.
enum RigctldSettings {
    /// Whether this Mac talks to rigctld running locally (spawned by
    /// `RigctldProcessController` against a USB-attached rig, today's only
    /// setup) or to one already running remotely (e.g. on a Raspberry Pi
    /// over Tailscale, when the rig's USB cable is plugged in there
    /// instead) — see repo root CLAUDE.md's "Remote rigctld (Option A)".
    /// Both are meant to stay available long-term, selected per session
    /// depending on where the rig is physically connected, not a one-way
    /// migration from one to the other.
    enum ConnectionMode: String, CaseIterable {
        case local
        case remote
    }

    static let connectionModeKey = "rigctld.connectionMode"
    static let remoteHostKey = "rigctld.remoteHost"
    static let binaryPathKey = "rigctld.binaryPath"
    static let modelNumberKey = "rigctld.modelNumber"
    static let devicePathKey = "rigctld.devicePath"
    static let baudRateKey = "rigctld.baudRate"
    static let pttPortKey = "rigctld.pttPort"
    static let transmitEnabledKey = "rigctld.transmitEnabled"

    static var connectionMode: ConnectionMode {
        get { UserDefaults.standard.string(forKey: connectionModeKey).flatMap(ConnectionMode.init(rawValue:)) ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: connectionModeKey) }
    }

    /// Tailscale MagicDNS hostname (or IP) of the remote rigctld host, used
    /// only when `connectionMode == .remote`. Port isn't configurable
    /// separately — rigctld's default 4532 is assumed on the remote host
    /// too.
    static var remoteHost: String {
        get { UserDefaults.standard.string(forKey: remoteHostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: remoteHostKey) }
    }

    static var binaryPath: String {
        get { UserDefaults.standard.string(forKey: binaryPathKey) ?? "/opt/homebrew/bin/rigctld" }
        set { UserDefaults.standard.set(newValue, forKey: binaryPathKey) }
    }

    static var modelNumber: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: modelNumberKey)
            return value == 0 ? 1051 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: modelNumberKey) }
    }

    static var devicePath: String {
        get { UserDefaults.standard.string(forKey: devicePathKey) ?? "/dev/tty.usbserial-01C7A9C50" }
        set { UserDefaults.standard.set(newValue, forKey: devicePathKey) }
    }

    static var baudRate: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: baudRateKey)
            return value == 0 ? 38400 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: baudRateKey) }
    }

    /// A separate serial device rigctld should key PTT on, distinct from
    /// the main CAT control port. Empty means "not configured" — rigctld
    /// then keys PTT via a CAT command over the main radio port, same as
    /// before this setting existed.
    static var pttPort: String {
        get { UserDefaults.standard.string(forKey: pttPortKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: pttPortKey) }
    }

    /// Safety cutoff: when `false`, `HubService` refuses PTT/MOX/antenna-
    /// tune/CW-message-playback from every source (local UI and remote
    /// WebSocket clients alike — see `HubService.send(_:)`). Defaults to
    /// `true` (unset reads as enabled) so this doesn't silently break
    /// existing setups on upgrade — `UserDefaults.bool(forKey:)` itself
    /// defaults missing keys to `false`, so the default has to be handled
    /// explicitly here rather than relied on.
    static var transmitEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: transmitEnabledKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: transmitEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: transmitEnabledKey) }
    }
}

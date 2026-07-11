import Foundation

/// Launch configuration for the `rigctld` process, backed by
/// `UserDefaults` directly rather than `@AppStorage` — `HubService` (not a
/// SwiftUI `View`) needs to read these too, and both it and `SettingsView`
/// read/write the same keys so they stay in sync.
enum RigctldSettings {
    static let binaryPathKey = "rigctld.binaryPath"
    static let modelNumberKey = "rigctld.modelNumber"
    static let devicePathKey = "rigctld.devicePath"
    static let baudRateKey = "rigctld.baudRate"
    static let pttPortKey = "rigctld.pttPort"

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
}

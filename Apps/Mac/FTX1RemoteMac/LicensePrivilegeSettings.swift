import FTX1Core
import Foundation

/// Settings → License: which privileges the transmit gate applies
/// (`TransmitGate`'s `privileges`), backed by `UserDefaults` directly like
/// `LogbookSettings`. Off unless chosen — the gate then checks only the
/// amateur bands, as before.
enum LicensePrivilegeSettings {
    static let choiceKey = "license.privileges"
    static let customProfileKey = "license.customProfile"

    static var choice: PrivilegeChoice {
        get { PrivilegeChoice(rawValue: UserDefaults.standard.string(forKey: choiceKey) ?? "off") }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: choiceKey) }
    }

    /// The operator's own table (JSON). Starts empty, which blocks every
    /// transmission while Custom is chosen.
    static var customProfile: PrivilegeProfile {
        get {
            guard let data = UserDefaults.standard.data(forKey: customProfileKey),
                  let profile = try? JSONDecoder().decode(PrivilegeProfile.self, from: data)
            else { return PrivilegeProfile(name: "Custom", segments: []) }
            return profile
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: customProfileKey) }
    }

    /// What the gate applies for a choice: nil = off.
    static func profile(for choice: PrivilegeChoice, custom: PrivilegeProfile) -> PrivilegeProfile? {
        switch choice {
        case .off: nil
        case .preset(let preset): preset.profile
        case .custom: custom
        }
    }
}

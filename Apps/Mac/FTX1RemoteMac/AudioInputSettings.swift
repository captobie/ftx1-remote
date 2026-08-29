import Foundation

/// Which Core Audio input device the app should capture from, backed by
/// `UserDefaults` directly rather than `@AppStorage` — same pattern as
/// `RigctldSettings`, so a future audio capture service (not a SwiftUI
/// `View`) can read this too. No capture is wired up yet; this just lets a
/// device be selected ahead of features that will need one (e.g. a
/// waterfall/spectrum display fed from a USB sound card connected to the
/// rig).
enum AudioInputSettings {
    static let deviceUIDKey = "audio.inputDeviceUID"

    /// Empty string means "system default input device".
    static var deviceUID: String {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }
}

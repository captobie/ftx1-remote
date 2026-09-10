import Foundation

/// Which Core Audio output device `AudioPlaybackEngine` plays the rig's
/// captured audio through, on the Mac — same `UserDefaults`-backed pattern
/// as `AudioInputSettings`.
enum AudioOutputSettings {
    static let deviceUIDKey = "audio.outputDeviceUID"

    /// Empty string means "system default output device".
    static var deviceUID: String {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }
}

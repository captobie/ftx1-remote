import Foundation

/// Which Core Audio output device the Mac plays a remote client's transmit
/// audio into in `.local` mode — the FTX-1's own USB audio device, so the
/// iPad's microphone reaches the rig (`HubService.handleTXAudio`). Same
/// `UserDefaults`-backed pattern as `AudioOutputSettings`. Unlike that one,
/// empty means "none": transmit audio is dropped rather than played on the
/// system default output.
enum TXAudioOutputSettings {
    static let deviceUIDKey = "audio.txOutputDeviceUID"

    static var deviceUID: String {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }
}

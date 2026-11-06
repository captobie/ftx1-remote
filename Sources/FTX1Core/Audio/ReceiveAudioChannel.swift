/// Which audio a decoder listens to (the CW decoder, the RTTY/PSK
/// decoder). MAIN/SUB are roles, not L/R channels: every audio path
/// already swaps the channels to follow a Main/Sub swap (the Mac's
/// `HubService.audioChannelsSwapped`, the relay the hub sends the iPad,
/// `PiDirectViewModel.audioChannelsSwapped`), so `.main` is always the
/// Main VFO's audio. `.webSDR` is whatever the Mac's WebSDR window is
/// playing (the Mac's `WebSDRAudioSource`); the iPad doesn't offer it.
public enum ReceiveAudioChannel: String, CaseIterable, Sendable {
    case main
    case sub
    case webSDR

    /// Radio terms, not translated.
    public var title: String {
        switch self {
        case .main: "MAIN"
        case .sub: "SUB"
        case .webSDR: "WebSDR"
        }
    }
}

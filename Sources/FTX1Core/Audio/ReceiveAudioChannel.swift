/// Which audio a decoder listens to (the CW decoder, the RTTY/PSK
/// decoder). MAIN/SUB are roles, not L/R channels: every audio path
/// already swaps the channels to follow a Main/Sub swap (the Mac's
/// `HubService.audioChannelsSwapped`, the relay the hub sends the iPad,
/// `PiDirectViewModel.audioChannelsSwapped`), so `.main` is always the
/// Main VFO's audio. `.webSDR` is whatever the Mac's WebSDR window is
/// playing (the Mac's `WebSDRAudioSource`); `.myKiwiSDR` is the Mac's
/// MyKiwiSDR window's decoded audio (`LocalSDRAudioSource`, "Local SDR" in
/// code). The iPad offers neither — it lists `rigReceivers`.
public enum ReceiveAudioChannel: String, CaseIterable, Sendable {
    case main
    case sub
    case webSDR
    case myKiwiSDR

    /// The rig's own receivers — what an app without the Mac's SDR windows
    /// (the iPad) offers.
    public static let rigReceivers: [ReceiveAudioChannel] = [.main, .sub]

    /// Radio terms and product names, not translated.
    public var title: String {
        switch self {
        case .main: "MAIN"
        case .sub: "SUB"
        case .webSDR: "WebSDR"
        case .myKiwiSDR: "MyKiwiSDR"
        }
    }

    /// The rig's MAIN or SUB audio (rather than an SDR's).
    public var isRigReceiver: Bool {
        self == .main || self == .sub
    }

    /// A saved choice, if this app offers it; MAIN otherwise (nothing
    /// saved, a value from a newer version, or a source this app doesn't
    /// have — the iPad reading `myKiwiSDR`).
    public static func restored(rawValue: String?, offered: [ReceiveAudioChannel]) -> ReceiveAudioChannel {
        guard let channel = rawValue.flatMap(ReceiveAudioChannel.init(rawValue:)),
              offered.contains(channel) else { return .main }
        return channel
    }
}

import Combine
import Foundation

/// Where the WebSDR window's Mute is applied: on the page (the normal case)
/// or, while the CW window is capturing the WebSDR's audio, on that capture
/// (`WebSDRAudioTap.setMuted`), since a muted page gives the decoder nothing
/// to decode. A plain `let` on `HubService`, shared by `WebSDRFollowModel`
/// (which sets `muteRequested` and mutes the page only while
/// `!captureActive`) and `WebSDRAudioSource` (which sets `captureActive` and mutes
/// its tap with `muteRequested`).
@MainActor
public final class WebSDRAudioRouting: ObservableObject {
    public init() {}

    /// The WebSDR window wants its audio silenced: its Mute, or Mute on TX
    /// while transmitting.
    @Published public var muteRequested = false
    /// A decoder window's WebSDR tap (`WebSDRAudioSource`) is attached to the WebSDR's audio.
    @Published public var captureActive = false
}

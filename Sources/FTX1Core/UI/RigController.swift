import SwiftUI

/// Common interface for whatever is backing a rig-control screen — the
/// Mac's `HubService` (talks to rigctld directly) or a mobile client's
/// `RigClientViewModel` (talks to the Mac over WebSocket). Lets shared views
/// like `MenuPageView` work against either without depending on Mac-only or
/// mobile-only types.
@MainActor
public protocol RigController: ObservableObject {
    var rigState: RigState { get }
    func send(_ command: RigCommand)

    /// Whether this controller can open Deep Settings screens. Requires a
    /// per-item read capability that only the Mac's direct rigctld link has
    /// today (`HubService.readMenuItem`) — the WebSocket wire protocol has
    /// no request/response mechanism for a remote client to fetch a Deep
    /// Settings item's current value, only fire-and-forget commands and
    /// one-way state pushes. Defaults to `false`.
    var supportsDeepSettings: Bool { get }

    /// Type-erased Deep Settings destination for the given category, or
    /// `nil` if unsupported. Type-erased because the concrete destination
    /// view (`DeepSettingsView`) lives in the Mac app target, which this
    /// shared package can't import — only `HubService`'s conformance
    /// builds a real one.
    func deepSettingsDestination(title: String, p1s: [Int]) -> AnyView?

    /// Whether this controller can decode APRS traffic (S.LIST/M.LIST on
    /// the FM menu page). Requires the Mac's audio-derived decode pipeline
    /// (`AudioCaptureEngine` + `APRSDecoder`) — mobile clients have no
    /// audio input to decode and never will via the WebSocket wire
    /// protocol (same reasoning as `supportsDeepSettings`: this is an
    /// intrinsically Mac-only capability, not a missing wire-protocol
    /// message). Defaults to `false`.
    var supportsAPRSDecoding: Bool { get }

    /// Whether this controller can record/play back its own audio output
    /// (CW page's RECORD/PLAY buttons). Requires the Mac's `AudioRecorder`,
    /// fed from the same `AudioCaptureEngine` tap as APRS/FT8 — mobile
    /// clients have no local audio pipeline to record from, same reasoning
    /// as `supportsAPRSDecoding`. Defaults to `false`.
    var supportsAudioRecording: Bool { get }

    /// Whether a recording is currently in progress. Meaningless (always
    /// `false`) when `supportsAudioRecording` is `false`.
    var isAudioRecording: Bool { get }

    /// Starts a new recording, or closes out the one in progress. No-op
    /// where `supportsAudioRecording` is `false`.
    func toggleAudioRecording()
}

public extension RigController {
    var supportsDeepSettings: Bool { false }
    func deepSettingsDestination(title: String, p1s: [Int]) -> AnyView? { nil }
    var supportsAPRSDecoding: Bool { false }
    var supportsAudioRecording: Bool { false }
    var isAudioRecording: Bool { false }
    func toggleAudioRecording() {}
}

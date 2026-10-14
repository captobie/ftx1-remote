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

    /// Whether this controller can open Deep Settings screens
    /// (`DeepSettingsView`): it needs `readMenuItem` to show each item's
    /// current value. Defaults to `false`, which leaves the MENU grid's six
    /// Deep Settings buttons as disabled placeholders.
    var supportsDeepSettings: Bool { get }

    /// Reads one Deep Settings item's raw P4 value (the "EX" read, see
    /// `RigctldClient.getMenuItem`), or nil if it couldn't be read. Called
    /// only while a Deep Settings tab is open, for that tab's items.
    func readMenuItem(p1: Int, p2: Int, p3: Int) async -> String?

    /// Whether this controller has decoded APRS lists to show (S.LIST/
    /// M.LIST on the FM menu page): the Mac decodes them itself
    /// (`AudioCaptureEngine` + `APRSDecoder`), the iPad's Pi-direct model
    /// decodes the Pi's 44.1 kHz audio, and the iPad's hub model shows the
    /// Mac's (`APRSListPush` — the relayed 8 kHz audio is too coarse to
    /// decode). Defaults to `false` (the iPhone).
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
    func readMenuItem(p1: Int, p2: Int, p3: Int) async -> String? { nil }
    var supportsAPRSDecoding: Bool { false }
    var supportsAudioRecording: Bool { false }
    var isAudioRecording: Bool { false }
    func toggleAudioRecording() {}
}

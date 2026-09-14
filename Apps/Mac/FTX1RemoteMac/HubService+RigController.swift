import FTX1Core
import SwiftUI

/// Makes `HubService` usable by shared views like `MenuPageView` — the only
/// `RigController` conformer that actually supports Deep Settings, since
/// it's the only one with a direct rigctld link to read a menu item's
/// current value from (`readMenuItem`). See `RigController`'s doc comment.
extension HubService: RigController {
    var supportsDeepSettings: Bool { true }

    func deepSettingsDestination(title: String, p1s: [Int]) -> AnyView? {
        AnyView(DeepSettingsView(title: title, p1s: p1s).environmentObject(self))
    }

    /// Only the Mac has an audio input to decode APRS from at all — see
    /// `RigController.supportsAPRSDecoding`'s doc comment.
    var supportsAPRSDecoding: Bool { true }

    /// Only the Mac has `AudioRecorder`'s audio tap — see
    /// `RigController.supportsAudioRecording`'s doc comment.
    var supportsAudioRecording: Bool { true }

    var isAudioRecording: Bool { isRecordingAudio }

    func toggleAudioRecording() {
        audioRecorder.toggle()
    }
}

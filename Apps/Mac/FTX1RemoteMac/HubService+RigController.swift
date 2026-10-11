import FTX1Core
import SwiftUI

/// Makes `HubService` usable by shared views like `MenuPageView`. Deep
/// Settings reads go straight to rigctld (`readMenuItem`, in
/// `HubService.swift`).
extension HubService: RigController {
    var supportsDeepSettings: Bool { true }

    /// Only the Mac has an audio input to decode APRS from at all — see
    /// `RigController.supportsAPRSDecoding`'s doc comment.
    var supportsAPRSDecoding: Bool { true }

    /// Only the Mac has `AudioRecorder`'s audio tap — see
    /// `RigController.supportsAudioRecording`'s doc comment.
    var supportsAudioRecording: Bool { true }

    var isAudioRecording: Bool { isRecordingAudio }

    func toggleAudioRecording() {
        audioRecorder.toggle(label: Self.audioRecordingLabel(frequencyHz: rigState.frequencyHz, mode: rigState.mode))
    }

    /// "147.380.000 FM" — the frequency/mode at the moment RECORD is
    /// pressed, folded into the new file's name by `AudioRecorder.toggle
    /// (label:)` so a recording is identifiable without opening and
    /// listening to it; ignored entirely when RECORD is pressed again to
    /// stop.
    private static func audioRecordingLabel(frequencyHz: Int, mode: RigMode) -> String {
        AudioRecorder.label(frequencyHz: frequencyHz, mode: mode)
    }
}

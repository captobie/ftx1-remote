import Combine
import Foundation
import FTX1Core
import os

/// The Mac's side of the shared `LocalSDRModel`: the hub is the rig host,
/// `HubService.localSDRSource` the decoders' tap, and recordings are WAV
/// files in the Recordings folder.
extension LocalSDRModel {
    static func mac(hub: HubService?) -> LocalSDRModel {
        LocalSDRModel(
            rigHost: hub,
            audioTap: hub?.localSDRSource,
            logSubsystem: "com.ftx1remote.mac",
            configurePlayback: { engine in
                engine.setOutputDevice(AudioOutputDeviceLister.deviceID(forUID: AudioOutputSettings.deviceUID))
            },
            makeRecordingWriter: { frequencyHz, mode, date in
                let label = "\(AudioRecorder.label(frequencyHz: frequencyHz, modeName: mode.label)) MyKiwiSDR"
                var url = AudioRecorder.newRecordingURL(label: label, date: date)
                var n = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = AudioRecorder.newRecordingURL(label: "\(label) \(n)", date: date)
                    n += 1
                }
                Logger(subsystem: "com.ftx1remote.mac", category: "kiwisdr")
                    .notice("recording to \(url.lastPathComponent, privacy: .public)")
                return SDRAudioFileWriter(url: url)
            })
    }
}

extension HubService: SDRRigHost {
    var sdrRigState: RigState { rigState }
    var sdrRigStatePublisher: AnyPublisher<RigState, Never> { $rigState.eraseToAnyPublisher() }
    var sdrRigConnected: Bool { connectionState == .connected }
    func sdrSend(_ command: RigCommand) { send(command) }
    func setSDRAudible(_ audible: Bool, source: SDRAudioSource) {
        switch source {
        case .localSDR: setMainAudioOverride(.localSDR, active: audible)
        case .webSDR: setMainAudioOverride(.webSDR, active: audible)
        }
    }
}

extension LocalSDRAudioSource: LocalSDRAudioTap {}

nonisolated extension SDRAudioFileWriter: LocalSDRRecordingWriter {}

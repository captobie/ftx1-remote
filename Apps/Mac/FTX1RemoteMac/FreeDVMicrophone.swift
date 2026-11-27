import AVFoundation
import AudioToolbox
import FreeDVKit
import os

/// Settings → Audio → FreeDV microphone: the Core Audio input the FreeDV
/// window transmits from. Empty = the system default input.
enum FreeDVMicrophoneSettings {
    static let deviceUIDKey = "audio.freeDVMicrophoneUID"

    static var deviceUID: String {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }
}

/// The FreeDV sender's microphone: an `AVAudioEngine` input tap on the
/// chosen device, running only while the sender transmits (so the Mac's
/// microphone indicator is on only then). A fresh engine per over, so a
/// device change in Settings applies at the next over. Samples go to
/// `onSamples` on the main queue, in order.
@MainActor
final class FreeDVMicrophone: FreeDVMicrophoneSource {
    var onSamples: (([Float], Double) -> Void)?
    private var engine: AVAudioEngine?
    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "freedv-tx")

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    func start() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Asks now; this over can't use it yet.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw Failure(errorDescription: String(localized: "freeDVMic.askedForAccess"))
        default:
            throw Failure(errorDescription: String(localized: "freeDVMic.accessDenied"))
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let uid = FreeDVMicrophoneSettings.deviceUID
        if !uid.isEmpty {
            guard let deviceID = AudioInputDeviceLister.deviceID(forUID: uid), let unit = input.audioUnit else {
                throw Failure(errorDescription: String(localized: "freeDVMic.notConnected"))
            }
            var id = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                throw Failure(errorDescription: String(localized: "freeDVMic.couldntStart \(String(status))"))
            }
        }
        engine.prepare()
        // The input side follows a CurrentDevice switch; `format: nil`
        // (the output side) may not — see AudioCaptureEngine.startEngine.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Failure(errorDescription: String(localized: "freeDVMic.couldntStart \("no input format")"))
        }
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(rate: rate) { [weak self] samples, rate in
            self?.onSamples?(samples, rate)
        })
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure(errorDescription: String(localized: "freeDVMic.couldntStart \(error.localizedDescription)"))
        }
        self.engine = engine
        Self.logger.notice("microphone started: \(uid.isEmpty ? "system default" : uid, privacy: .public), \(rate, privacy: .public) Hz")
    }

    /// Runs on Core Audio's thread, so it must not inherit the main actor
    /// (this target's default isolation) — it would trap there. Hands the
    /// first channel to `deliver` on the main queue, in order.
    private nonisolated static func tapBlock(rate: Double,
                                             deliver: @escaping @MainActor ([Float], Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(samples, rate) }
            }
        }
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}

import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import FTX1CW
import os

/// The CW window's Monitor: a local sidetone for what the send pane keys.
/// With the rig remote (on the Pi) there's nothing to hear while its keyer
/// memory plays, so each chunk `CWSender` plays is synthesized here at the
/// rig's keyer speed and CW pitch (`KS`/`KP`) and played on the Mac's audio
/// output (Settings → Audio, same device as the rig's receive audio).
///
/// It's a model of the keying, not a copy of it: PARIS timing from
/// `CWText.keying(of:)`, started when the play command is sent, so it runs
/// a network hop ahead of the rig and ignores the rig's weighting. Stop
/// cuts it off with the rig. Not for the CW Key window: the key interface
/// has its own sidetone.
final class CWMonitor: ObservableObject {
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.enabled) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.enabled)
            if !isEnabled { stop() }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// Which chunk is playing, so a finished one can't stop the engine
    /// under a newer one.
    private var generation = 0
    private let logger = Logger(subsystem: "com.ftx1remote.mac", category: "cw-monitor")

    private enum DefaultsKey {
        static let enabled = "cw.monitor"
    }

    /// The rig's default pitch, used until `KP` has been read.
    nonisolated private static let defaultPitchHz = 700
    nonisolated private static let level: Float = 0.25
    /// Rise/fall time, so elements don't click.
    nonisolated private static let rampSeconds = 0.005

    /// A chunk the rig is starting to key, or nil when keying was stopped.
    func handle(_ chunk: CWKeyingChunk?) {
        guard let chunk else { stop(); return }
        guard isEnabled else { return }
        play(chunk)
    }

    func stop() {
        generation += 1
        guard engine.isRunning else { return }
        player.stop()
        engine.stop()
    }

    private func play(_ chunk: CWKeyingChunk) {
        guard startEngineIfNeeded(), let format,
              let buffer = Self.render(chunk, format: format) else { return }
        generation += 1
        let current = generation
        player.stop()
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                // Let the device go once the chunk is done, unless another
                // one started in the meantime.
                guard let self, self.generation == current else { return }
                self.stop()
            }
        }
        player.play()
    }

    private func startEngineIfNeeded() -> Bool {
        if engine.isRunning { return true }
        if format == nil {
            engine.attach(player)
        } else {
            engine.disconnectNodeOutput(player)
        }
        // Set the device before reading its format and starting (see
        // `AudioPlaybackEngine.setOutputDevice`).
        if let deviceID = AudioOutputDeviceLister.deviceID(forUID: AudioOutputSettings.deviceUID),
           let audioUnit = engine.outputNode.audioUnit {
            var mutableDeviceID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                logger.error("output device: OSStatus \(status, privacy: .public)")
            }
        }
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: hardwareRate > 0 ? hardwareRate : 48000,
                                         channels: 1) else { return false }
        self.format = format
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            return true
        } catch {
            logger.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The chunk as a tone keyed on and off, with raised-cosine edges.
    nonisolated private static func render(_ chunk: CWKeyingChunk, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let samplesPerUnit = Int(1.2 / Double(max(chunk.wpm, 4)) * rate)
        let runs = CWText.keying(of: chunk.text)
        let total = runs.reduce(0) { $0 + $1.units } * samplesPerUnit
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)

        let pitch = Double(chunk.pitchHz ?? defaultPitchHz)
        let step = 2 * Double.pi * pitch / rate
        let ramp = max(Int(rampSeconds * rate), 1)
        var position = 0
        for run in runs {
            let length = run.units * samplesPerUnit
            if run.down {
                let rampLength = min(ramp, length / 2)
                for index in 0..<length {
                    var gain = level
                    if index < rampLength {
                        gain *= Float(0.5 - 0.5 * cos(Double.pi * Double(index) / Double(rampLength)))
                    } else if index >= length - rampLength {
                        gain *= Float(0.5 - 0.5 * cos(Double.pi * Double(length - index) / Double(rampLength)))
                    }
                    samples[position + index] = gain * Float(sin(step * Double(position + index)))
                }
            } else {
                for index in 0..<length { samples[position + index] = 0 }
            }
            position += length
        }
        return buffer
    }
}

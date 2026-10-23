import AVFoundation
import Combine
import FTX1Core
import os

#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// The send pane's Monitor (the Mac's CW window, the iPad's CW pane): a
/// local sidetone for what the rig's keyer sends. With the rig remote (on
/// the Pi) there's nothing to hear while its keyer memory plays, so each
/// chunk `CWSender` plays is synthesized here at the rig's keyer speed and
/// CW pitch (`KS`/`KP`) and played locally — on the Mac, on the output
/// picked in Settings → Audio (`outputDeviceID`); on the iPad, through
/// `SharedAudioSession` like the receive players.
///
/// It's a model of the keying, not a copy of it: PARIS timing from
/// `CWText.keying(of:)`, started when the play command is sent, so it runs
/// a network hop ahead of the rig and ignores the rig's weighting. Stop
/// cuts it off with the rig. Not for the Mac's CW Key window: the key
/// interface has its own sidetone.
@MainActor
public final class CWMonitor: ObservableObject {
    @Published public var isEnabled: Bool {
        didSet {
            SettingsStore.defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { stop() }
        }
    }

    #if os(macOS)
    /// The output device to play on, looked up at each start; nil = the
    /// system default.
    public var outputDeviceID: (() -> AudioDeviceID?)?
    #endif

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// Which chunk is playing, so a finished one can't stop the engine
    /// under a newer one.
    private var generation = 0
    #if os(iOS)
    /// This monitor's share of `SharedAudioSession`, while the engine runs.
    private var holdsSession = false
    #endif
    private let logger: Logger

    /// Off by default, remembered.
    public static let enabledKey = "cw.monitor"

    /// - Parameter logSubsystem: the app's `os.Logger` subsystem; category
    ///   "cw-monitor".
    public init(logSubsystem: String) {
        logger = Logger(subsystem: logSubsystem, category: "cw-monitor")
        isEnabled = SettingsStore.defaults.bool(forKey: Self.enabledKey)
    }

    /// The rig's default pitch, used until `KP` has been read.
    nonisolated private static let defaultPitchHz = 700
    nonisolated private static let level: Float = 0.25
    /// Rise/fall time, so elements don't click.
    nonisolated private static let rampSeconds = 0.005

    /// A chunk the rig is starting to key, or nil when keying was stopped.
    public func handle(_ chunk: CWKeyingChunk?) {
        guard let chunk else { stop(); return }
        guard isEnabled else { return }
        play(chunk)
    }

    public func stop() {
        generation += 1
        if engine.isRunning {
            player.stop()
            engine.stop()
        }
        #if os(iOS)
        if holdsSession {
            holdsSession = false
            SharedAudioSession.release()
        }
        #endif
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
        #if os(macOS)
        // Set the device before reading its format and starting (see
        // `AudioPlaybackEngine.setOutputDevice`).
        if let deviceID = outputDeviceID?(), let audioUnit = engine.outputNode.audioUnit {
            var mutableDeviceID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                logger.error("output device: OSStatus \(status, privacy: .public)")
            }
        }
        #else
        if !holdsSession {
            do {
                try SharedAudioSession.acquire()
                holdsSession = true
            } catch {
                logger.error("audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
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
            stop()
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

import Combine
import Foundation
import FTX1Core
import os

/// What FreeDV transmit needs from the app: the Mac's `HubService`.
@MainActor
public protocol FreeDVTransmitLink: AnyObject {
    /// Why a transmission can't start (or must stop) now, nil when it may:
    /// the transmit gate, no rig, no transmit audio path, the wrong
    /// sideband for the band, the rig keyed by something else
    /// (`keyedBySender` false).
    func freeDVTransmitBlock(keyedBySender: Bool) -> String?
    /// What the rig reports (PTT).
    var freeDVRigIsKeyed: Bool { get }
    func freeDVSetKeyed(_ keyed: Bool)
    /// 16-bit little-endian mono PCM at 8 kHz (`AudioStreamFormat`).
    func freeDVSendAudio(_ pcm: Data)
}

/// The microphone the sender runs while it transmits (the Mac's
/// `FreeDVMicrophone`). Samples arrive through `FreeDVSender.ingestMicrophone`.
@MainActor
public protocol FreeDVMicrophoneSource: AnyObject {
    /// Starts capture; throws a message for the window if it can't.
    func start() throws
    func stop()
}

/// Time for `FreeDVSender`'s checks and play-out wait; replaced in tests.
public protocol FreeDVClock: Sendable {
    /// Seconds on a monotonic clock.
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async
}

public struct SystemFreeDVClock: FreeDVClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }
}

/// The microphone's level while transmitting, apart from the sender so its
/// ~20 updates a second re-render only the meter.
@MainActor
public final class FreeDVMicLevelStore: ObservableObject {
    /// Peak of the last chunk, dBFS (−60 floor).
    @Published public private(set) var peakDB: Float = -60

    nonisolated init() {}

    func update(peak: Float) {
        let db = max(-60, 20 * log10(max(peak, 1e-6)))
        if abs(db - peakDB) >= 1 { peakDB = db }
    }

    func reset() {
        if peakDB != -60 { peakDB = -60 }
    }
}

/// Tools → FreeDV's transmitter: keys the rig, encodes the microphone with
/// `RADEEncoder` and sends the modem audio through the app's transmit
/// audio path; RX (or releasing the space bar) sends the end-of-over with
/// the station's callsign, lets the audio play out, then unkeys.
///
/// Stops on its own when the transmit gate closes, when the rig stops
/// reporting PTT (after a grace period), and at `maxTransmitSeconds`.
@MainActor
public final class FreeDVSender: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        /// Keyed, sending the microphone.
        case transmitting
        /// The end-of-over and tail are playing out; unkeys when done.
        case finishing
    }

    /// How a transmission was started: the TX button latches; the space bar
    /// lasts only while held.
    public enum Trigger: Sendable {
        case toggle
        case momentary
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var trigger: Trigger = .toggle
    /// When the current transmission keyed (for the elapsed time).
    @Published public private(set) var startedAt: Date?
    /// Why the last start was refused or the last transmission stopped
    /// early; cleared on the next start.
    @Published public private(set) var statusMessage: String?
    /// Output level relative to the FreeDV app's (16383 of 32767), dB.
    @Published public var levelDB: Double {
        didSet {
            defaults.set(levelDB, forKey: Key.level)
            let gain = Self.gain(levelDB: levelDB)
            queue.async { [box] in box.gain = gain }
        }
    }

    public let micLevel = FreeDVMicLevelStore()
    public var isActive: Bool { state != .idle }
    /// Called whenever `state` changes (the receiver pauses while active).
    public var onStateChanged: ((State) -> Void)?

    /// Safety limit for one over.
    public static let maxTransmitSeconds: Double = 300
    /// PTT may read "off" for this long after keying before it counts.
    static let pttGraceSeconds: Double = 2
    /// How long PTT may read "off" mid-transmission before the sender stops.
    static let pttLossSeconds: Double = 1
    /// Kept keyed this long past the audio's estimated end (sink buffering).
    static let playoutMarginSeconds: Double = 0.3
    public static let levelRange: ClosedRange<Double> = -20...0

    private weak var link: FreeDVTransmitLink?
    private let microphone: FreeDVMicrophoneSource
    private let callsign: () -> String
    private let clock: FreeDVClock
    private let logger: Logger
    private let defaults = SettingsStore.defaults
    private let queue = DispatchQueue(label: "com.ftx1remote.freedv-encoder", qos: .userInitiated)

    /// The encoder lives on `queue` only.
    private final class EncoderBox: @unchecked Sendable {
        var encoder: RADEEncoder?
        let resampler = FreeDVResampler(outputRate: RADEEncoder.speechSampleRate)
        var gain: Float = 1
    }
    private let box = EncoderBox()

    private var monitorTask: Task<Void, Never>?
    private var keyedAt: TimeInterval = 0
    private var pttOffSince: TimeInterval?
    /// Modem audio handed to the link this over, and when the first went.
    private var sentSamples = 0
    private var firstSentAt: TimeInterval?
    /// Bumped per transmission so a late chunk from the last one is dropped.
    private var generation = 0

    private enum Key {
        static let level = "freedv.txLevelDb"
    }

    /// - Parameter callsign: the station callsign for the end-of-over, read
    ///   at each over's end (Settings → Station).
    public init(link: FreeDVTransmitLink, microphone: FreeDVMicrophoneSource, logSubsystem: String,
                callsign: @escaping () -> String = { StationSettings.callsign },
                clock: FreeDVClock = SystemFreeDVClock()) {
        self.link = link
        self.microphone = microphone
        self.callsign = callsign
        self.clock = clock
        logger = Logger(subsystem: logSubsystem, category: "freedv-tx")
        SettingsStore.defaults.register(defaults: [Key.level: 0.0])
        levelDB = min(Self.levelRange.upperBound, max(Self.levelRange.lowerBound,
                                                      SettingsStore.defaults.double(forKey: Key.level)))
        box.gain = Self.gain(levelDB: levelDB)
    }

    nonisolated static func gain(levelDB: Double) -> Float {
        RADEEncoder.nominalOutputScale * Float(pow(10, levelDB / 20))
    }

    // MARK: - Control

    /// TX, or the space bar going down. Refused (with `statusMessage`)
    /// when the link says no.
    public func start(_ trigger: Trigger) {
        guard state == .idle, let link else { return }
        if let reason = link.freeDVTransmitBlock(keyedBySender: false) {
            statusMessage = reason
            return
        }
        guard let encoder = RADEEncoder() else {
            statusMessage = String(localized: "freeDVSender.encoderFailed", bundle: .module)
            return
        }
        statusMessage = nil
        generation += 1
        let gain = Self.gain(levelDB: levelDB)
        queue.async { [box] in
            box.encoder = encoder
            box.resampler.reset()
            box.gain = gain
        }
        sentSamples = 0
        firstSentAt = nil
        pttOffSince = nil
        keyedAt = clock.now()
        self.trigger = trigger
        startedAt = Date()
        setState(.transmitting)
        link.freeDVSetKeyed(true)
        do {
            try microphone.start()
        } catch {
            logger.error("microphone: \(error.localizedDescription, privacy: .public)")
            stopNow(reason: error.localizedDescription)
            return
        }
        logger.notice("keyed (\(trigger == .toggle ? "TX" : "space", privacy: .public))")
        monitorTask = Task { [weak self] in await self?.monitor() }
    }

    /// RX, or the space bar coming up after a momentary start: the
    /// end-of-over goes out, then the rig unkeys.
    public func finish() {
        guard state == .transmitting else { return }
        microphone.stop()
        micLevel.reset()
        setState(.finishing)
        let call = callsign().trimmingCharacters(in: .whitespaces)
        let generation = generation
        queue.async { [box, weak self] in
            guard let encoder = box.encoder else { return }
            let tail = [Float](repeating: 0, count: Int(RADEEncoder.tailSilenceSeconds * RADEEncoder.modemSampleRate))
            let modem = encoder.finish(callsign: call.isEmpty ? nil : call) + tail
            box.encoder = nil
            let pcm = Self.int16Data(modem, gain: box.gain)
            DispatchQueue.main.async { [weak self] in
                self?.send(pcm, samples: modem.count, generation: generation)
                self?.logger.notice("end of over (\(call.isEmpty ? "no callsign" : call, privacy: .public))")
                Task { [weak self] in await self?.unkeyAfterPlayout(generation: generation) }
            }
        }
    }

    /// The space bar came up: ends the over only if the space bar started it.
    public func releaseMomentary() {
        if state == .transmitting, trigger == .momentary { finish() }
    }

    /// Stop now: unkey at once, no end-of-over (the gate closed, the link
    /// dropped, the window closed while keyed).
    public func stop() {
        guard state != .idle else { return }
        stopNow(reason: nil)
    }

    // MARK: - Audio

    /// Microphone samples, on the main actor, at the device's rate.
    public func ingestMicrophone(samples: [Float], sampleRate: Double) {
        guard state == .transmitting else { return }
        micLevel.update(peak: samples.lazy.map(abs).max() ?? 0)
        let generation = generation
        queue.async { [box, weak self] in
            guard let encoder = box.encoder else { return }
            let speech = box.resampler.resample(samples, sampleRate: sampleRate)
            let modem = encoder.process(speech)
            guard !modem.isEmpty else { return }
            let pcm = Self.int16Data(modem, gain: box.gain)
            // Main queue, not a Task: keeps the frames in order.
            DispatchQueue.main.async { [weak self] in
                self?.send(pcm, samples: modem.count, generation: generation)
            }
        }
    }

    private func send(_ pcm: Data, samples: Int, generation: Int) {
        guard generation == self.generation, state != .idle else { return }
        if firstSentAt == nil { firstSentAt = clock.now() }
        sentSamples += samples
        link?.freeDVSendAudio(pcm)
    }

    nonisolated static func int16Data(_ modem: [Float], gain: Float) -> Data {
        var data = Data(count: modem.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in modem.enumerated() {
                out[i] = Int16(max(-1, min(1, sample * gain)) * 32767).littleEndian
            }
        }
        return data
    }

    // MARK: - Ending

    private func unkeyAfterPlayout(generation: Int) async {
        let sentSeconds = Double(sentSamples) / RADEEncoder.modemSampleRate
        let elapsed = firstSentAt.map { clock.now() - $0 } ?? 0
        let remaining = max(0, sentSeconds - elapsed) + Self.playoutMarginSeconds
        await clock.sleep(seconds: remaining)
        guard generation == self.generation, state == .finishing else { return }
        link?.freeDVSetKeyed(false)
        endTransmission()
    }

    private func stopNow(reason: String?) {
        microphone.stop()
        micLevel.reset()
        generation += 1
        queue.async { [box] in box.encoder = nil }
        link?.freeDVSetKeyed(false)
        if let reason {
            statusMessage = reason
            logger.notice("stopped: \(reason, privacy: .public)")
        }
        endTransmission()
    }

    private func endTransmission() {
        monitorTask?.cancel()
        monitorTask = nil
        startedAt = nil
        setState(.idle)
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onStateChanged?(new)
    }

    /// Every 100 ms while transmitting: the gate, PTT, the time limit.
    private func monitor() async {
        while !Task.isCancelled, state == .transmitting {
            await clock.sleep(seconds: 0.1)
            guard !Task.isCancelled, state == .transmitting, let link else { return }
            let now = clock.now()
            if let reason = link.freeDVTransmitBlock(keyedBySender: true) {
                stopNow(reason: reason)
                return
            }
            if now - keyedAt > Self.maxTransmitSeconds {
                statusMessage = String(localized: "freeDVSender.timeLimit", bundle: .module)
                finish()
                return
            }
            if link.freeDVRigIsKeyed {
                pttOffSince = nil
            } else if now - keyedAt > Self.pttGraceSeconds {
                let since = pttOffSince ?? now
                pttOffSince = since
                if now - since > Self.pttLossSeconds {
                    stopNow(reason: String(localized: "freeDVSender.unkeyedElsewhere", bundle: .module))
                    return
                }
            }
        }
    }
}

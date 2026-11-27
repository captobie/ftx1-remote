import AVFoundation
import Combine
import Foundation
import FTX1Core
import os

/// What the FreeDV receiver needs to know about the rig.
public struct FreeDVRigInfo: Equatable, Sendable {
    public var transmitting = false
    public var mainMode: RigMode = .unknown
    public var subMode: RigMode?
    public var mainFrequencyHz: Int?
    public var subFrequencyHz: Int?

    public init(transmitting: Bool = false, mainMode: RigMode = .unknown, subMode: RigMode? = nil,
                mainFrequencyHz: Int? = nil, subFrequencyHz: Int? = nil) {
        self.transmitting = transmitting
        self.mainMode = mainMode
        self.subMode = subMode
        self.mainFrequencyHz = mainFrequencyHz
        self.subFrequencyHz = subFrequencyHz
    }

    /// Modes and frequencies only while connected: before the first read,
    /// `RigState` holds placeholder values (`mode` is USB).
    public init(state: RigState, connected: Bool) {
        self.init(
            transmitting: state.ptt,
            mainMode: connected ? state.mode : .unknown,
            subMode: connected ? state.secondaryMode : nil,
            mainFrequencyHz: connected && state.frequencyHz > 0 ? state.frequencyHz : nil,
            subFrequencyHz: connected ? state.secondaryFrequencyHz : nil
        )
    }
}

/// One station heard: a callsign from an end-of-over.
public struct FreeDVHeardStation: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var callsign: String
    public var time: Date
    /// The SNR the over was received at (last reading while in sync).
    public var snrDB: Float?
    public var channel: ReceiveAudioChannel
    /// The source's dial frequency then, if known.
    public var frequencyHz: Int?
    /// Heard in a decoded file, not live.
    public var fromFile: Bool
}

/// Sync, SNR and tuning offset, published apart from the heard list so
/// ~20 updates a second re-render only the status line.
@MainActor
public final class FreeDVStatusStore: ObservableObject {
    @Published public private(set) var sync = false
    @Published public private(set) var snrDB: Float = 0
    @Published public private(set) var frequencyOffsetHz: Float = 0

    nonisolated init() {}

    func update(_ status: RADEStatus) {
        if sync != status.sync { sync = status.sync }
        guard status.sync else { return }
        if abs(snrDB - status.snrDB) >= 0.5 { snrDB = status.snrDB }
        if abs(frequencyOffsetHz - status.frequencyOffsetHz) >= 0.5 { frequencyOffsetHz = status.frequencyOffsetHz }
    }

    func reset() {
        sync = false
        snrDB = 0
        frequencyOffsetHz = 0
    }
}

/// Tools → FreeDV's receiver: FreeDV RADE V1 from the rig's MAIN or SUB
/// audio, the WebSDR window's or the MyKiwiSDR window's, decoded to speech
/// and played on the Mac's audio output; callsigns from each end-of-over
/// go to `heard`.
///
/// Fed like `DigiReceiver`: the app hands it every receive chunk; it keeps
/// only the selected channel, and only between `start()` and `stop()` (the
/// window's appear/disappear). Decoding runs on its own serial queue; the
/// status readings are in `status`.
@MainActor
public final class FreeDVReceiver: ObservableObject {
    @Published public var channel: ReceiveAudioChannel {
        didSet {
            guard channel != oldValue else { return }
            defaults.set(channel.rawValue, forKey: Key.channel)
            resetDecoder()
            onSourceChanged?()
            updateModeHint()
        }
    }
    /// Playback volume of the decoded speech, 0…1.
    @Published public var volume: Double {
        didSet {
            defaults.set(volume, forKey: Key.volume)
            playback?.volume = Float(volume)
        }
    }
    /// Decoded speech not played (decoding, the heard list and the rig
    /// audio mute carry on regardless).
    @Published public var isMuted: Bool {
        didSet { defaults.set(isMuted, forKey: Key.muted) }
    }
    /// In sync, held a moment after sync drops so a brief fade doesn't
    /// flip the rig's audio back on between words.
    @Published public private(set) var isReceivingVoice = false
    @Published public private(set) var heard: [FreeDVHeardStation] = []
    @Published public private(set) var isSubAudioAvailable = false
    @Published public private(set) var isPausedForTransmit = false
    /// The selected receiver's mode when it isn't USB/DATA-U.
    @Published public private(set) var unsuitableSourceMode: RigMode?
    @Published public private(set) var isDecodingFile = false
    /// The speech decoded from the last file, saved in the recordings folder.
    @Published public private(set) var lastDecodedFile: URL?
    @Published public var errorMessage: String?

    public let status = FreeDVStatusStore()
    public private(set) var isRunning = false
    /// Called whenever `isRunning` or `channel` changes — the Mac's WebSDR
    /// and MyKiwiSDR sources start or stop their taps from here.
    public var onSourceChanged: (() -> Void)?
    /// Called on the player before it starts (the Mac picks its output device).
    public var configurePlayback: ((AudioPlaybackEngine) -> Void)?
    /// The dial frequency of a source the rig doesn't report (MyKiwiSDR).
    public var frequencyOfSource: ((ReceiveAudioChannel) -> Int?)?

    /// The decoder and resampler live on `queue` only.
    private final class DecoderBox: @unchecked Sendable {
        var decoder: RADEDecoder?
        let resampler = FreeDVResampler()
        var lastSyncSNR: Float?
    }

    private struct ChunkResult: Sendable {
        var speech: Data
        var status: RADEStatus
        var callsigns: [(String, Float?)]
    }

    private let box = DecoderBox()
    private let queue = DispatchQueue(label: "com.ftx1remote.freedv-decoder", qos: .userInitiated)
    private let defaults = SettingsStore.defaults
    private let recordingsDirectory: URL?
    private var playback: AudioPlaybackEngine?
    private var rigInfo = FreeDVRigInfo()
    private var myKiwiSDRMode: RigMode?
    private var lastSubSampleAt: Date?
    private var voiceHoldTask: Task<Void, Never>?
    private let logger: Logger
    /// Bumped on every reset, so output already on its way to the main
    /// actor from before it is dropped.
    private var generation = 0

    private static let maxHeard = 200
    private static let subAudioTimeout: TimeInterval = 2
    /// How long `isReceivingVoice` stays on after sync drops.
    static let voiceHoldSeconds: Double = 1.5
    /// RADE's speech, queued a little ahead (input arrives in ~46 ms taps).
    private static let playbackPrebufferSeconds = 0.25

    private enum Key {
        static let channel = "freedv.channel"
        static let volume = "freedv.volume"
        static let muted = "freedv.muted"
    }

    /// - Parameters:
    ///   - channels: the sources this app offers; a saved choice outside
    ///     them falls back to MAIN.
    ///   - recordingsDirectory: where a decoded file's speech is saved (nil:
    ///     file decoding only fills the heard list).
    public init(logSubsystem: String, channels: [ReceiveAudioChannel] = ReceiveAudioChannel.allCases,
                recordingsDirectory: URL? = nil) {
        logger = Logger(subsystem: logSubsystem, category: "freedv")
        self.recordingsDirectory = recordingsDirectory
        let defaults = SettingsStore.defaults
        defaults.register(defaults: [Key.volume: 0.8, Key.muted: false])
        channel = ReceiveAudioChannel.restored(rawValue: defaults.string(forKey: Key.channel), offered: channels)
        volume = defaults.double(forKey: Key.volume)
        isMuted = defaults.bool(forKey: Key.muted)
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let engine = AudioPlaybackEngine(squelchEnabled: false, inputSampleRate: RADEDecoder.speechSampleRate,
                                         prebufferSeconds: Self.playbackPrebufferSeconds)
        configurePlayback?(engine)
        engine.start()
        engine.volume = Float(volume)
        playback = engine
        resetDecoder()
        logger.notice("started, rade_c API \(RADEDecoder.libraryVersion, privacy: .public), source \(self.channel.rawValue, privacy: .public)")
        onSourceChanged?()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        playback?.stop()
        playback = nil
        generation += 1
        queue.async { [box] in box.decoder = nil }
        status.reset()
        setReceivingVoice(false, immediately: true)
        onSourceChanged?()
    }

    private func resetDecoder() {
        generation += 1
        status.reset()
        setReceivingVoice(false, immediately: true)
        guard isRunning else { return }
        queue.async { [box] in
            box.decoder = RADEDecoder()
            box.resampler.reset()
            box.lastSyncSNR = nil
        }
    }

    // MARK: - Audio

    /// Every receive chunk, on the main actor, whether or not decoding is
    /// on — cheap when it isn't.
    public func ingest(samples: [Float], sampleRate: Double, channel source: ReceiveAudioChannel) {
        trackSubAvailability(source)
        guard isRunning, !isPausedForTransmit, source == channel else { return }
        let generation = generation
        queue.async { [box, weak self] in
            guard let result = Self.decode(samples, sampleRate: sampleRate, in: box) else { return }
            Task { @MainActor [weak self] in
                self?.handle(result, generation: generation)
            }
        }
    }

    /// On `queue`.
    private nonisolated static func decode(_ samples: [Float], sampleRate: Double, in box: DecoderBox) -> ChunkResult? {
        guard let decoder = box.decoder else { return nil }
        let modem = box.resampler.resample(samples, sampleRate: sampleRate)
        let output = decoder.process(modem)
        var callsigns: [(String, Float?)] = []
        for end in output.endsOfOver {
            if let callsign = end.callsign { callsigns.append((callsign, box.lastSyncSNR)) }
        }
        if output.status.sync { box.lastSyncSNR = output.status.snrDB }
        return ChunkResult(speech: Self.int16Data(output.speech), status: output.status, callsigns: callsigns)
    }

    private func handle(_ result: ChunkResult, generation: Int) {
        guard generation == self.generation else { return }
        status.update(result.status)
        setReceivingVoice(result.status.sync, immediately: false)
        if !result.speech.isEmpty, !isMuted { playback?.push(pcm: result.speech) }
        for (callsign, snr) in result.callsigns {
            addHeard(callsign, snrDB: snr, fromFile: false)
        }
    }

    private func setReceivingVoice(_ sync: Bool, immediately: Bool) {
        if sync {
            voiceHoldTask?.cancel()
            voiceHoldTask = nil
            if !isReceivingVoice { isReceivingVoice = true }
        } else if immediately {
            voiceHoldTask?.cancel()
            voiceHoldTask = nil
            if isReceivingVoice { isReceivingVoice = false }
        } else if isReceivingVoice, voiceHoldTask == nil {
            voiceHoldTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.voiceHoldSeconds))
                guard !Task.isCancelled, let self else { return }
                self.voiceHoldTask = nil
                if !self.status.sync { self.isReceivingVoice = false }
            }
        }
    }

    private func addHeard(_ callsign: String, snrDB: Float?, fromFile: Bool) {
        let frequency: Int? = switch channel {
        case .main: rigInfo.mainFrequencyHz
        case .sub: rigInfo.subFrequencyHz
        case .webSDR, .myKiwiSDR: frequencyOfSource?(channel)
        }
        heard.insert(FreeDVHeardStation(callsign: callsign, time: Date(), snrDB: snrDB, channel: channel,
                                        frequencyHz: fromFile ? nil : frequency, fromFile: fromFile), at: 0)
        if heard.count > Self.maxHeard { heard.removeLast(heard.count - Self.maxHeard) }
        logger.notice("heard \(callsign, privacy: .public)\(fromFile ? " (file)" : "", privacy: .public)")
    }

    public func clearHeard() {
        heard = []
    }

    private nonisolated static func int16Data(_ speech: [Float]) -> Data {
        guard !speech.isEmpty else { return Data() }
        var data = Data(count: speech.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in speech.enumerated() {
                out[i] = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            }
        }
        return data
    }

    private func trackSubAvailability(_ source: ReceiveAudioChannel) {
        let now = Date()
        switch source {
        case .sub:
            lastSubSampleAt = now
            if !isSubAudioAvailable { isSubAudioAvailable = true }
        case .main:
            guard isSubAudioAvailable else { return }
            if let lastSubSampleAt, now.timeIntervalSince(lastSubSampleAt) < Self.subAudioTimeout { return }
            isSubAudioAvailable = false
        case .webSDR, .myKiwiSDR:
            break
        }
    }

    // MARK: - Rig

    public func rigInfoChanged(_ info: FreeDVRigInfo) {
        rigInfo = info
        let paused = info.transmitting
        if paused != isPausedForTransmit {
            isPausedForTransmit = paused
            if paused { resetDecoder() }
        }
        updateModeHint()
    }

    /// The MyKiwiSDR window's demodulation while it's connected (nil otherwise).
    public func setMyKiwiSDRMode(_ mode: RigMode?) {
        guard mode != myKiwiSDRMode else { return }
        myKiwiSDRMode = mode
        updateModeHint()
    }

    private func updateModeHint() {
        let mode: RigMode? = switch channel {
        case .main: rigInfo.mainMode == .unknown ? nil : rigInfo.mainMode
        case .sub: rigInfo.subMode
        case .webSDR: nil
        case .myKiwiSDR: myKiwiSDRMode
        }
        var hint: RigMode?
        if let mode, mode != .unknown, !Self.suitableModes.contains(mode) { hint = mode }
        if unsuitableSourceMode != hint { unsuitableSourceMode = hint }
    }

    /// FreeDV is sent on upper sideband; DATA-U is the rig's USB data mode.
    static let suitableModes: Set<RigMode> = [.usb, .dataUSB]

    // MARK: - Files

    /// Decodes a recording (any rate, first channel) as fast as it goes:
    /// callsigns into `heard`, the speech into a WAV in the recordings
    /// folder (`lastDecodedFile`). Live decoding carries on meanwhile.
    public func decodeFile(at url: URL) {
        guard !isDecodingFile else { return }
        isDecodingFile = true
        lastDecodedFile = nil
        let destination = recordingsDirectory.map {
            RecordingNames.url(label: "FreeDV \(url.deletingPathExtension().lastPathComponent)", date: Date(), in: $0)
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.decodeFileContents(url, writingTo: destination)
            await self?.finishFile(result, destination: destination, source: url)
        }
    }

    private struct FileResult: Sendable {
        var callsigns: [(String, Float?)] = []
        var speechSamples = 0
        var error: String?
    }

    private nonisolated static func decodeFileContents(_ url: URL, writingTo destination: URL?) -> FileResult {
        var result = FileResult()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let decoder = RADEDecoder() else {
            result.error = "RADE"
            return result
        }
        let resampler = FreeDVResampler()
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            var writer: AVAudioFile?
            let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RADEDecoder.speechSampleRate,
                                             channels: 1, interleaved: false)!
            if let destination {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: RADEDecoder.speechSampleRate,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ]
                writer = try AVAudioFile(forWriting: destination, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            let frames: AVAudioFrameCount = 8192
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return result }
            var lastSyncSNR: Float?
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
                let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
                let output = decoder.process(resampler.resample(samples, sampleRate: format.sampleRate))
                for end in output.endsOfOver {
                    if let callsign = end.callsign { result.callsigns.append((callsign, lastSyncSNR)) }
                }
                if output.status.sync { lastSyncSNR = output.status.snrDB }
                if let writer, !output.speech.isEmpty,
                   let speech = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(output.speech.count)) {
                    speech.frameLength = AVAudioFrameCount(output.speech.count)
                    output.speech.withUnsafeBufferPointer { speech.floatChannelData![0].update(from: $0.baseAddress!, count: output.speech.count) }
                    try writer.write(from: speech)
                }
                result.speechSamples += output.speech.count
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    private func finishFile(_ result: FileResult, destination: URL?, source: URL) {
        isDecodingFile = false
        for (callsign, snr) in result.callsigns {
            addHeard(callsign, snrDB: snr, fromFile: true)
        }
        if let error = result.error {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            errorMessage = String(localized: "freeDVReceiver.couldntRead \(source.lastPathComponent) \(error)", bundle: .module)
        } else if result.speechSamples == 0 {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            errorMessage = String(localized: "freeDVReceiver.noFreeDVIn \(source.lastPathComponent)", bundle: .module)
        } else {
            lastDecodedFile = destination
        }
    }
}

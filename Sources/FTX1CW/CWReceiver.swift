import Combine
import CWKit
import Foundation
import FTX1Core
import os

/// Which audio the CW decoder listens to. MAIN/SUB are roles, not L/R
/// channels: every audio path already swaps the channels to follow a
/// Main/Sub swap (the Mac's `HubService.audioChannelsSwapped`, the relay
/// the hub sends the iPad, `PiDirectViewModel.audioChannelsSwapped`), so
/// `.main` is always the Main VFO's audio. `.webSDR` is whatever the Mac's
/// WebSDR window is playing (the Mac's `CWWebSDRSource`); the iPad doesn't
/// offer it.
public enum CWAudioChannel: String, CaseIterable, Sendable {
    case main
    case sub
    case webSDR

    public var title: String {
        switch self {
        case .main: "MAIN"
        case .sub: "SUB"
        case .webSDR: "WebSDR"
        }
    }
}

/// The receive side of CW: decodes rig audio (or an audio file) to text
/// with CWKit (`captobie/cwdecode`), the same decoders as the standalone
/// CWDecode app. Shared by the Mac's Tools → CW window and the iPad's CW
/// pane.
///
/// The app feeds it every receive chunk, MAIN and SUB, unconditionally
/// (`ingest(samples:sampleRate:channel:)`, or `ingest(pcm:...)` for the
/// iPad's 8 kHz Int16 audio); it drops the channel that isn't selected and
/// everything between `stop()` and `start()` — decoding runs only while
/// the window or pane is open. Decoding itself runs on `PipelineRunner`'s
/// own serial queue, never the main actor.
///
/// Its own `ObservableObject`, never part of a hub or view model's state,
/// so text updates don't re-render the main screen. The per-chunk meters go
/// to a second object, `meters`, observed only by the status bar and the
/// tone slider, so they don't re-render the decoded text either.
///
/// Receive only. Sending is a sibling object (the Mac's `CWSender`), not
/// more state here; it pauses decoding through `setSenderActive(_:)`.
@MainActor
public final class CWReceiver: ObservableObject {
    @Published public private(set) var decodedText = ""
    /// Neural decoder: the newest text, not final yet; replaced on every update.
    @Published public private(set) var tentativeText = ""
    @Published public private(set) var isDecodingFile = false
    /// Whether Sub-channel audio is arriving at all. A mono input device (or
    /// a Pi stream from before stereo capture) never delivers any.
    @Published public private(set) var isSubAudioAvailable = false
    @Published public var errorMessage: String?

    @Published public var channel: CWAudioChannel {
        didSet {
            guard channel != oldValue else { return }
            SettingsStore.defaults.set(channel.rawValue, forKey: DefaultsKey.channel)
            // Flush what the old channel's decoder still holds; the next
            // audio starts a fresh one on the new channel.
            if isRunning, !isDecodingFile {
                flush()
                startNewLine()
            }
            onSourceChanged?()
            updateModeHint()
        }
    }
    @Published public var toneFrequency: Double { didSet { settingsChanged() } }
    @Published public var autoTune: Bool {
        didSet {
            // Keep listening on the tone we found rather than jumping back
            // to the old manual setting (same as the CWDecode app).
            if !autoTune { toneFrequency = meters.detectedFrequency }
            settingsChanged()
        }
    }
    @Published public var squelchDB: Double { didSet { settingsChanged() } }
    @Published public var decoder: DecoderKind { didSet { settingsChanged() } }

    /// Why the neural decoder can't be used, or nil when it can (or hasn't
    /// been loaded yet — the model loads on the first `start()`).
    @Published public private(set) var neuralUnavailableReason: String?

    public let meters = CWMeterStore()

    /// The decoder skips audio while the rig transmits (user decision, v2):
    /// otherwise it decodes the operator's own sidetone, which the send pane
    /// already shows. Either the rig reports TX, or the sender is running
    /// (which covers the lag before the poll sees PTT).
    @Published public private(set) var isPausedForTransmit = false
    /// The rig's CW pitch (`KP`), for the tone slider's "Rig Pitch" button.
    @Published public private(set) var rigPitchHz: Int?
    /// The selected receiver's mode isn't CW (MAIN/SUB sources only).
    @Published public private(set) var sourceModeIfNotCW: RigMode?

    /// Whether decoding is on (between `start()` and `stop()`).
    public private(set) var isRunning = false
    /// Called whenever `isRunning` or `channel` changes — the Mac's
    /// WebSDR source starts or stops its tap from here.
    public var onSourceChanged: (() -> Void)?

    private var senderActive = false
    private var rigInfo = CWRigInfo()
    private var runner: PipelineRunner?
    /// `.finished` events still to come from `flush()` calls, as opposed to
    /// the one that ends a file decode. Events arrive in order, so counting
    /// is enough to tell them apart.
    private var pendingFlushes = 0
    private var lastSubSampleAt: Date?
    private let logger: Logger

    private static let maxTextLength = 100_000
    /// No Sub audio for this long (while Main audio keeps arriving) means
    /// there's no Sub channel.
    private static let subAudioTimeout: TimeInterval = 2

    private enum DefaultsKey {
        static let channel = "cw.channel"
        static let toneFrequency = "cw.toneFrequency"
        static let autoTune = "cw.autoTune"
        static let squelchDB = "cw.squelchDB"
        static let decoder = "cw.decoder"
    }

    /// - Parameters:
    ///   - logSubsystem: the app's `os.Logger` subsystem; category "cw-decoder".
    ///   - channels: the sources this app offers; a saved choice outside
    ///     them falls back to MAIN.
    public init(logSubsystem: String, channels: [CWAudioChannel] = CWAudioChannel.allCases) {
        logger = Logger(subsystem: logSubsystem, category: "cw-decoder")
        let defaults = SettingsStore.defaults
        let fallback = PipelineSettings()
        defaults.register(defaults: [
            DefaultsKey.toneFrequency: fallback.toneFrequency,
            DefaultsKey.autoTune: fallback.autoTune,
            DefaultsKey.squelchDB: fallback.squelchDB,
            DefaultsKey.decoder: DecoderKind.neural.rawValue,
        ])
        let saved = CWAudioChannel(rawValue: defaults.string(forKey: DefaultsKey.channel) ?? "")
        channel = saved.flatMap { channels.contains($0) ? $0 : nil } ?? .main
        toneFrequency = defaults.double(forKey: DefaultsKey.toneFrequency)
        autoTune = defaults.bool(forKey: DefaultsKey.autoTune)
        squelchDB = defaults.double(forKey: DefaultsKey.squelchDB)
        decoder = DecoderKind(rawValue: defaults.string(forKey: DefaultsKey.decoder) ?? "") ?? .neural
        meters.detectedFrequency = toneFrequency
    }

    private var settings: PipelineSettings {
        PipelineSettings(
            toneFrequency: toneFrequency,
            autoTune: autoTune,
            squelchDB: squelchDB,
            decoder: neuralUnavailableReason == nil ? decoder : .classic
        )
    }

    // MARK: - Lifecycle (the window's or pane's appear/disappear)

    public func start() {
        guard !isRunning else { return }
        makeRunnerIfNeeded()
        isRunning = true
        onSourceChanged?()
    }

    /// Called when the window or pane closes, and as a safety net when the
    /// app stops. A file decode already under way runs to the end.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if !isDecodingFile {
            flush()
        }
        onSourceChanged?()
    }

    // MARK: - Audio

    /// Every receive chunk, on the main actor, whether or not decoding is
    /// on — cheap when it isn't.
    public func ingest(samples: [Float], sampleRate: Double, channel source: CWAudioChannel) {
        trackSubAvailability(source)
        guard accepts(source) else { return }
        runner?.submit(samples, sampleRate: sampleRate)
    }

    /// The same for 16-bit little-endian mono PCM — the 8 kHz audio the
    /// iPad gets from the hub's relay or downsamples from the Pi
    /// (`AudioStreamFormat`). 8 kHz is the neural model's own rate, and far
    /// above a CW tone.
    public func ingest(pcm: Data, sampleRate: Double, channel source: CWAudioChannel) {
        trackSubAvailability(source)
        guard accepts(source) else { return }
        let samples = pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        runner?.submit(samples, sampleRate: sampleRate)
    }

    private func accepts(_ source: CWAudioChannel) -> Bool {
        isRunning && !isDecodingFile && !isPausedForTransmit && source == channel
    }

    private func trackSubAvailability(_ source: CWAudioChannel) {
        let now = Date()
        switch source {
        case .sub:
            lastSubSampleAt = now
            if !isSubAudioAvailable { isSubAudioAvailable = true }
        case .main:
            guard isSubAudioAvailable else { return }
            if let lastSubSampleAt, now.timeIntervalSince(lastSubSampleAt) < Self.subAudioTimeout { return }
            isSubAudioAvailable = false
        case .webSDR:
            break
        }
    }

    // MARK: - Rig

    public func setSenderActive(_ active: Bool) {
        senderActive = active
        updateTransmitPause()
    }

    /// Whenever TX, the CW pitch or a receiver's mode changes.
    public func rigInfoChanged(_ info: CWRigInfo) {
        rigInfo = info
        if rigPitchHz != info.pitchHz { rigPitchHz = info.pitchHz }
        updateTransmitPause()
        updateModeHint()
    }

    private func updateTransmitPause() {
        let paused = senderActive || rigInfo.transmitting
        guard paused != isPausedForTransmit else { return }
        isPausedForTransmit = paused
        // End the character in progress cleanly rather than leave it to
        // be finished by the first audio after TX.
        if paused, isRunning, !isDecodingFile {
            flush()
            startNewLine()
        }
    }

    private func updateModeHint() {
        let mode: RigMode? = switch channel {
        case .main: rigInfo.mainMode
        case .sub: rigInfo.subMode
        case .webSDR: nil
        }
        let hint = mode.flatMap { $0 == .cw || $0 == .unknown ? nil : $0 }
        if sourceModeIfNotCW != hint { sourceModeIfNotCW = hint }
    }

    /// Sets the manual tone to the rig's CW pitch: a signal tuned to
    /// zero beat on the rig sounds at exactly that pitch.
    public func useRigPitch() {
        guard let rigPitchHz else { return }
        if autoTune { autoTune = false }
        toneFrequency = Double(rigPitchHz)
    }

    // MARK: - Files

    /// Pauses live decoding, decodes the file into the same text under a
    /// header line, then live decoding resumes (if still running).
    public func decodeFile(at url: URL) {
        guard !isDecodingFile else { return }
        makeRunnerIfNeeded()
        guard let runner else { return }
        if isRunning {
            // Flush the live decoder before the file's audio reaches it.
            flush()
        }
        isDecodingFile = true
        startNewLine()
        append("— \(url.lastPathComponent) —\n")

        Task.detached(priority: .userInitiated) { [weak self] in
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                try AudioFileReader.read(url) { samples, sampleRate in
                    runner.submitAndWait(samples, sampleRate: sampleRate)
                }
            } catch {
                await self?.reportFileError(error, url: url)
            }
            // `.finished` clears `isDecodingFile` and ends the file's text.
            runner.finish()
        }
    }

    private func reportFileError(_ error: any Error, url: URL) {
        errorMessage = "Couldn't read “\(url.lastPathComponent)”: \(error.localizedDescription)"
    }

    // MARK: - Text

    public func clearText() {
        decodedText = ""
        tentativeText = ""
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        decodedText += text
        if decodedText.count > Self.maxTextLength {
            decodedText = String(decodedText.suffix(Self.maxTextLength))
        }
    }

    private func startNewLine() {
        if !decodedText.isEmpty, !decodedText.hasSuffix("\n") {
            append("\n")
        }
    }

    // MARK: - Pipeline

    /// Loads the Core ML model and starts the event loop on first use, so
    /// an app session that never decodes CW never pays for either.
    private func makeRunnerIfNeeded() {
        guard runner == nil else { return }
        let model: CWNetModel?
        do {
            model = try CWNetModel()
        } catch {
            model = nil
            neuralUnavailableReason = error.localizedDescription
            logger.error("Neural CW decoder unavailable: \(error.localizedDescription, privacy: .public)")
        }
        // The stream preserves the order of pipeline output, which matters
        // for the text.
        let (events, continuation) = AsyncStream.makeStream(of: PipelineRunner.Event.self)
        runner = PipelineRunner(settings: settings, neuralModel: model) { continuation.yield($0) }
        Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    /// Ends whatever the decoder is in the middle of; the next audio starts
    /// a fresh one.
    private func flush() {
        guard let runner else { return }
        pendingFlushes += 1
        runner.finish()
    }

    private func handle(_ event: PipelineRunner.Event) {
        switch event {
        case .output(let output):
            apply(output)
        case .finished(let output):
            apply(output)
            if !tentativeText.isEmpty { tentativeText = "" }
            meters.reset()
            if pendingFlushes > 0 {
                pendingFlushes -= 1
            } else if isDecodingFile {
                isDecodingFile = false
                startNewLine()
            }
        }
    }

    private func apply(_ output: PipelineOutput) {
        append(output.text)
        if output.tentativeText != tentativeText {
            tentativeText = output.tentativeText
        }
        meters.apply(output)
    }

    private func settingsChanged() {
        let defaults = SettingsStore.defaults
        defaults.set(toneFrequency, forKey: DefaultsKey.toneFrequency)
        defaults.set(autoTune, forKey: DefaultsKey.autoTune)
        defaults.set(squelchDB, forKey: DefaultsKey.squelchDB)
        defaults.set(decoder.rawValue, forKey: DefaultsKey.decoder)
        if !autoTune { meters.detectedFrequency = toneFrequency }
        runner?.update(settings)
    }
}

/// The CW decoder's live readouts — key state, level, SNR, WPM, tone and
/// the character being received. A pipeline output arrives per audio chunk
/// (~21 a second on the Mac), so these are published at most every
/// `interval` (key state changes immediately) and observed only by the
/// status bar and the tone slider, never the decoded text.
@MainActor
public final class CWMeterStore: ObservableObject {
    @Published public private(set) var keyDown = false
    @Published public private(set) var signalLevel = 0.0
    @Published public private(set) var snrDB = 0.0
    @Published public private(set) var wpm = 0.0
    @Published public var detectedFrequency = 0.0
    /// Classic decoder: dits and dahs of the character being received.
    @Published public private(set) var pendingSymbols = ""

    private var lastPublish = Date.distantPast
    private static let interval: TimeInterval = 0.1

    fileprivate func apply(_ output: PipelineOutput) {
        let now = Date()
        guard output.keyDown != keyDown || output.pendingSymbols != pendingSymbols
                || now.timeIntervalSince(lastPublish) >= Self.interval else { return }
        lastPublish = now
        keyDown = output.keyDown
        pendingSymbols = output.pendingSymbols
        signalLevel = output.signalLevel
        snrDB = output.snrDB
        wpm = output.wpm
        detectedFrequency = output.toneFrequency
    }

    fileprivate func reset() {
        keyDown = false
        signalLevel = 0
        pendingSymbols = ""
    }
}

/// What `CWReceiver` needs from `RigState`, so the app only forwards
/// changes to these (not every poll).
public struct CWRigInfo: Equatable, Sendable {
    public var transmitting = false
    public var pitchHz: Int?
    public var mainMode: RigMode = .unknown
    public var subMode: RigMode?

    public init(transmitting: Bool = false, pitchHz: Int? = nil, mainMode: RigMode = .unknown, subMode: RigMode? = nil) {
        self.transmitting = transmitting
        self.pitchHz = pitchHz
        self.mainMode = mainMode
        self.subMode = subMode
    }

    /// From a rig state. Modes only while connected: before the first
    /// read, `RigState` holds placeholder values (`mode` is USB).
    /// `transmitting` adds TX the state doesn't show yet (the iPad's own
    /// PTT press, before the next poll).
    public init(state: RigState, connected: Bool, transmitting: Bool = false) {
        self.init(
            transmitting: state.ptt || transmitting,
            pitchHz: state.cwPitchHz,
            mainMode: connected ? state.mode : .unknown,
            subMode: connected ? state.secondaryMode : nil
        )
    }
}

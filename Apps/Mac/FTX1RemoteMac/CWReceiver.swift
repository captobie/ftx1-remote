import AppKit
import Combine
import CWKit
import Foundation
import FTX1Core
import os

/// Which audio the CW decoder listens to. MAIN/SUB are roles, not L/R
/// channels: `AudioCaptureEngine` already swaps the channels to follow a
/// Main/Sub swap (`HubService.audioChannelsSwapped`), so `.main` is always
/// the Main VFO's audio. `.webSDR` is whatever the WebSDR window is playing
/// (`WebSDRAudioTap`).
enum CWAudioChannel: String, CaseIterable {
    case main
    case sub
    case webSDR

    var title: String {
        switch self {
        case .main: "MAIN"
        case .sub: "SUB"
        case .webSDR: "WebSDR"
        }
    }
}

/// The receive side of the Tools → CW window: decodes rig audio (or an
/// audio file) to text with CWKit (`captobie/cwdecode`), the same decoders
/// as the standalone CWDecode app.
///
/// `HubService` feeds it both audio taps unconditionally
/// (`ingest(samples:sampleRate:channel:)`); it drops the channel that isn't
/// selected and everything while the window is closed, the same "decode
/// only while the window is open" shape as `FT8DecodeCoordinator`. Decoding
/// itself runs on `PipelineRunner`'s own serial queue, never the main actor.
/// The third source, `.webSDR`, comes from `WebSDRAudioTap` (what the
/// WebSDR window is playing), started only while it's selected.
///
/// Its own `ObservableObject`, a plain `let` on `HubService` (like
/// `ft8Store`), so text updates never re-render the main window. The
/// per-chunk meters go to a second object, `meters`, observed only by the
/// pane's status bar, so they don't re-render the decoded text either.
///
/// Receive only. CW sending (v2) is meant to be a sibling object with its
/// own pane in the same window, not more state here.
final class CWReceiver: ObservableObject {
    @Published private(set) var decodedText = ""
    /// Neural decoder: the newest text, not final yet; replaced on every update.
    @Published private(set) var tentativeText = ""
    @Published private(set) var isDecodingFile = false
    /// Whether Sub-channel audio is arriving at all. A mono input device (or
    /// a Pi stream from before stereo capture) never delivers any.
    @Published private(set) var isSubAudioAvailable = false
    @Published var errorMessage: String?
    /// The WebSDR tap's state while `.webSDR` is the source and the window
    /// is open; `.stopped` otherwise.
    @Published private(set) var webSDRStatus = WebSDRAudioTap.Status.stopped

    @Published var channel: CWAudioChannel {
        didSet {
            guard channel != oldValue else { return }
            UserDefaults.standard.set(channel.rawValue, forKey: DefaultsKey.channel)
            // Flush what the old channel's decoder still holds; the next
            // audio starts a fresh one on the new channel.
            if isRunning, !isDecodingFile {
                flush()
                startNewLine()
            }
            updateWebSDRTap()
            updateModeHint()
        }
    }
    @Published var toneFrequency: Double { didSet { settingsChanged() } }
    @Published var autoTune: Bool {
        didSet {
            // Keep listening on the tone we found rather than jumping back
            // to the old manual setting (same as the CWDecode app).
            if !autoTune { toneFrequency = meters.detectedFrequency }
            settingsChanged()
        }
    }
    @Published var squelchDB: Double { didSet { settingsChanged() } }
    @Published var decoder: DecoderKind { didSet { settingsChanged() } }

    /// Why the neural decoder can't be used, or nil when it can (or hasn't
    /// been loaded yet — the model loads on the first `start()`).
    @Published private(set) var neuralUnavailableReason: String?

    let meters = CWMeterStore()

    /// The decoder skips audio while the rig transmits (user decision, v2):
    /// otherwise it decodes the operator's own sidetone, which the send pane
    /// already shows. Either the rig reports TX, or the send pane is running
    /// (which covers the lag before the poll sees PTT).
    @Published private(set) var isPausedForTransmit = false
    /// The rig's CW pitch (`KP`), for the tone slider's "Rig pitch" button.
    @Published private(set) var rigPitchHz: Int?
    /// The selected receiver's mode isn't CW (MAIN/SUB sources only).
    @Published private(set) var sourceModeIfNotCW: RigMode?
    private var senderActive = false
    private var rigInfo = CWRigInfo()
    private let webSDRAudioRouting: WebSDRAudioRouting
    private var muteCancellable: AnyCancellable?

    private var runner: PipelineRunner?
    /// Created on first use: the tap's permission prompt should only ever
    /// appear once someone picks the WebSDR source.
    private var webSDRTap: WebSDRAudioTap?
    private var isRunning = false
    /// `.finished` events still to come from `flush()` calls, as opposed to
    /// the one that ends a file decode. Events arrive in order, so counting
    /// is enough to tell them apart.
    private var pendingFlushes = 0
    private var lastSubSampleAt: Date?

    private static let maxTextLength = 100_000
    /// No Sub audio for this long (while Main audio keeps arriving) means
    /// there's no Sub channel.
    private static let subAudioTimeout: TimeInterval = 2
    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "cw-decoder")

    private enum DefaultsKey {
        static let channel = "cw.channel"
        static let toneFrequency = "cw.toneFrequency"
        static let autoTune = "cw.autoTune"
        static let squelchDB = "cw.squelchDB"
        static let decoder = "cw.decoder"
    }

    init(webSDRAudioRouting: WebSDRAudioRouting) {
        self.webSDRAudioRouting = webSDRAudioRouting
        let defaults = UserDefaults.standard
        let fallback = PipelineSettings()
        defaults.register(defaults: [
            DefaultsKey.toneFrequency: fallback.toneFrequency,
            DefaultsKey.autoTune: fallback.autoTune,
            DefaultsKey.squelchDB: fallback.squelchDB,
            DefaultsKey.decoder: DecoderKind.neural.rawValue,
        ])
        channel = CWAudioChannel(rawValue: defaults.string(forKey: DefaultsKey.channel) ?? "") ?? .main
        toneFrequency = defaults.double(forKey: DefaultsKey.toneFrequency)
        autoTune = defaults.bool(forKey: DefaultsKey.autoTune)
        squelchDB = defaults.double(forKey: DefaultsKey.squelchDB)
        decoder = DecoderKind(rawValue: defaults.string(forKey: DefaultsKey.decoder) ?? "") ?? .neural
        meters.detectedFrequency = toneFrequency
        // The WebSDR window's Mute, applied to the tap while it runs.
        muteCancellable = webSDRAudioRouting.$muteRequested
            .removeDuplicates()
            .sink { [weak self] muted in self?.webSDRTap?.setMuted(muted) }
    }

    private var settings: PipelineSettings {
        PipelineSettings(
            toneFrequency: toneFrequency,
            autoTune: autoTune,
            squelchDB: squelchDB,
            decoder: neuralUnavailableReason == nil ? decoder : .classic
        )
    }

    // MARK: - Lifecycle (the CW window's onAppear/onDisappear)

    func start() {
        guard !isRunning else { return }
        makeRunnerIfNeeded()
        isRunning = true
        updateWebSDRTap()
    }

    /// Called when the CW window closes, and from `HubService.stop()` as a
    /// safety net. A file decode already under way runs to the end.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        if !isDecodingFile {
            flush()
        }
        updateWebSDRTap()
    }

    /// The tap runs only while the window is open with WebSDR selected.
    private func updateWebSDRTap() {
        if isRunning, channel == .webSDR {
            if webSDRTap == nil {
                webSDRTap = WebSDRAudioTap(
                    onSamples: { [weak self] samples, sampleRate in
                        self?.ingest(samples: samples, sampleRate: sampleRate, channel: .webSDR)
                    },
                    onStatus: { [weak self] status in
                        self?.webSDRStatusChanged(status)
                    }
                )
            }
            // Before `start()`, so a tap built while muted starts muted.
            webSDRTap?.setMuted(webSDRAudioRouting.muteRequested)
            webSDRTap?.start()
            // A quick switch away and back can restart a tap whose status
            // never changed, so recompute rather than wait for a callback.
            webSDRStatusChanged(webSDRStatus)
        } else {
            // The page mutes itself again right away; the tap holds its
            // own mute a moment longer (see `WebSDRAudioTap.stop()`).
            webSDRAudioRouting.captureActive = false
            webSDRTap?.stop()
        }
    }

    private func webSDRStatusChanged(_ status: WebSDRAudioTap.Status) {
        webSDRStatus = status
        // Only once the tap is attached (and so muted, if asked) does the
        // page unmute: no gap where both are open or both are muted.
        let attached = status == .capturing || status == .silent
        let active = attached && isRunning && channel == .webSDR
        if webSDRAudioRouting.captureActive != active {
            webSDRAudioRouting.captureActive = active
        }
    }

    // MARK: - Audio

    /// Both of `HubService`'s audio taps call this on the main actor for
    /// every chunk, whether or not the window is open — cheap when it isn't.
    func ingest(samples: [Float], sampleRate: Double, channel source: CWAudioChannel) {
        trackSubAvailability(source)
        guard isRunning, !isDecodingFile, !isPausedForTransmit, source == channel else { return }
        runner?.submit(samples, sampleRate: sampleRate)
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

    func setSenderActive(_ active: Bool) {
        senderActive = active
        updateTransmitPause()
    }

    /// From `HubService`, whenever TX, the CW pitch or a receiver's mode
    /// changes.
    func rigInfoChanged(_ info: CWRigInfo) {
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
    func useRigPitch() {
        guard let rigPitchHz else { return }
        if autoTune { autoTune = false }
        toneFrequency = Double(rigPitchHz)
    }

    // MARK: - Files

    /// Pauses live decoding, decodes the file into the same text under a
    /// header line, then live decoding resumes (if the window is still open).
    func decodeFile(at url: URL) {
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

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(decodedText, forType: .string)
    }

    func clearText() {
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
    /// an app session that never opens the CW window never pays for either.
    private func makeRunnerIfNeeded() {
        guard runner == nil else { return }
        let model: CWNetModel?
        do {
            model = try CWNetModel()
        } catch {
            model = nil
            neuralUnavailableReason = error.localizedDescription
            Self.logger.error("Neural CW decoder unavailable: \(error.localizedDescription, privacy: .public)")
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
        let defaults = UserDefaults.standard
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
/// (~21 a second), so these are published at most every `interval` (key
/// state changes immediately) and observed only by the status bar and the
/// tone slider, never the decoded text.
final class CWMeterStore: ObservableObject {
    @Published private(set) var keyDown = false
    @Published private(set) var signalLevel = 0.0
    @Published private(set) var snrDB = 0.0
    @Published private(set) var wpm = 0.0
    @Published var detectedFrequency = 0.0
    /// Classic decoder: dits and dahs of the character being received.
    @Published private(set) var pendingSymbols = ""

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

/// What `CWReceiver` needs from `RigState`, so `HubService` only forwards
/// changes to these (not every poll).
struct CWRigInfo: Equatable {
    var transmitting = false
    var pitchHz: Int?
    var mainMode: RigMode = .unknown
    var subMode: RigMode?
}

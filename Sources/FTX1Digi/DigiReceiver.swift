import AVFoundation
import Combine
import Foundation
import FTX1Core
import os

/// What the decoder needs to know about the rig.
public struct DigiRigInfo: Equatable, Sendable {
    public var transmitting = false
    public var mainMode: RigMode = .unknown
    public var subMode: RigMode?

    public init(transmitting: Bool = false, mainMode: RigMode = .unknown, subMode: RigMode? = nil) {
        self.transmitting = transmitting
        self.mainMode = mainMode
        self.subMode = subMode
    }

    /// Modes only while connected: before the first read, `RigState`
    /// holds placeholder values (`mode` is USB).
    public init(state: RigState, connected: Bool) {
        self.init(
            transmitting: state.ptt,
            mainMode: connected ? state.mode : .unknown,
            subMode: connected ? state.secondaryMode : nil
        )
    }
}

/// The tuning strip's rows and the live readings, published apart from the
/// decoded text so ~10 updates a second re-render only the strip and the
/// status line.
@MainActor
public final class DigiMeterStore: ObservableObject {
    /// The newest spectrum row (0…1 over 0…`DigiDecoder.stripSpanHz`).
    @Published public private(set) var row: [Float] = []
    /// Counts rows, so the strip can tell a new row from a re-render.
    public private(set) var rowSerial = 0
    /// Where the decoder is listening now (after AFC).
    @Published public private(set) var trackedHz: Double = 0
    @Published public private(set) var quality: Float = 0

    nonisolated init() {}

    func update(_ output: DigiDecoderOutput) {
        if let row = output.spectrumRow {
            rowSerial += 1
            self.row = row
        }
        if abs(trackedHz - output.centerHz) >= 0.5 { trackedHz = output.centerHz }
        if abs(quality - output.quality) >= 0.02 { quality = output.quality }
    }

    func reset(centerHz: Double) {
        trackedHz = centerHz
        quality = 0
    }
}

/// Tools → RTTY/PSK's receiver: RTTY, BPSK31 or BPSK63 from the rig's MAIN
/// or SUB audio, the WebSDR window's audio, or an audio file.
///
/// The app feeds it every receive chunk unconditionally; it keeps only the
/// selected channel, and only between `start()` and `stop()` (the window's
/// appear/disappear). Demodulation runs on its own serial queue. Its own
/// object, like `CWReceiver`, so decoded text never re-renders the main
/// window; the per-row readings are in `meters`.
@MainActor
public final class DigiReceiver: ObservableObject {
    /// Received and (echoed) transmitted text, in order.
    @Published public private(set) var runs: [DigiTextRun] = []
    @Published public private(set) var isDecodingFile = false
    @Published public private(set) var isSubAudioAvailable = false
    @Published public private(set) var isPausedForTransmit = false
    /// The selected receiver's mode when it isn't one this decoder works in.
    @Published public private(set) var unsuitableSourceMode: RigMode?
    @Published public var errorMessage: String?

    @Published public var mode: DigiMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Key.mode)
            centerHz = savedCenter(for: mode)
            rebuildDecoder()
            updateModeHint()
        }
    }
    @Published public var channel: ReceiveAudioChannel {
        didSet {
            guard channel != oldValue else { return }
            defaults.set(channel.rawValue, forKey: Key.channel)
            resetDecoder()
            onSourceChanged?()
            updateModeHint()
        }
    }
    /// Where the operator put the decoder (a click on the strip); AFC
    /// works around it. Saved per mode.
    @Published public private(set) var centerHz: Double
    @Published public var rttyShiftHz: Double { didSet { rttyChanged(oldValue != rttyShiftHz) } }
    @Published public var rttyBaud: Double { didSet { rttyChanged(oldValue != rttyBaud) } }
    @Published public var rttyReverse: Bool { didSet { rttyChanged(oldValue != rttyReverse) } }
    @Published public var rttyUnshiftOnSpace: Bool { didSet { rttyChanged(oldValue != rttyUnshiftOnSpace) } }
    @Published public var afcEnabled: Bool {
        didSet {
            defaults.set(afcEnabled, forKey: Key.afc)
            let on = afcEnabled
            queue.async { [box] in box.decoder?.setAFC(on) }
        }
    }
    /// 0…1; characters print only while the signal quality is above it.
    @Published public var squelch: Double {
        didSet {
            defaults.set(squelch, forKey: Key.squelch)
            let value = Float(squelch)
            queue.async { [box] in box.decoder?.setSquelch(value) }
        }
    }

    public let meters = DigiMeterStore()
    public private(set) var isRunning = false
    /// Called whenever `isRunning` or `channel` changes — the Mac's WebSDR
    /// source starts or stops its tap from here.
    public var onSourceChanged: (() -> Void)?

    /// The settings as the operator set them: `reverse` means "this
    /// station sends upside down", whatever the sideband.
    public var rttySettings: RTTYSettings {
        RTTYSettings(shiftHz: rttyShiftHz, baud: rttyBaud, reverse: rttyReverse, unshiftOnSpace: rttyUnshiftOnSpace)
    }

    /// What the decoder gets: Reverse flipped when the selected receiver
    /// is on an upper sideband, where a normal RTTY signal's mark (the
    /// higher RF tone) comes out as the higher audio tone.
    var decoderRTTYSettings: RTTYSettings {
        var settings = rttySettings
        settings.reverse = rttySettings.effectiveReverse(upperSideband: sourceMode?.isUpperSidebandAudio ?? false)
        return settings
    }

    /// The selected source's mode: the rig's for MAIN/SUB (nil before the
    /// first read), the Kiwi's demodulation for MyKiwiSDR (nil while it
    /// isn't connected), nil for WebSDR.
    private var sourceMode: RigMode? {
        switch channel {
        case .main: rigInfo.mainMode == .unknown ? nil : rigInfo.mainMode
        case .sub: rigInfo.subMode
        case .webSDR: nil
        case .myKiwiSDR: myKiwiSDRMode
        }
    }

    /// The decoder lives on `queue` only.
    private final class DecoderBox: @unchecked Sendable {
        var decoder: DigiDecoder?
    }

    private let box = DecoderBox()
    private let queue = DispatchQueue(label: "com.ftx1remote.digi-decoder", qos: .userInitiated)
    private let defaults = SettingsStore.defaults
    private var rigInfo = DigiRigInfo()
    private var lastSubSampleAt: Date?
    private let logger: Logger
    /// Bumped on every rebuild/reset, so output from the old decoder that
    /// was already on its way to the main actor is dropped.
    private var generation = 0

    private static let maxTextLength = 100_000
    private static let subAudioTimeout: TimeInterval = 2

    private enum Key {
        static let mode = "digi.mode"
        static let channel = "digi.channel"
        static let rttyCenter = "digi.rtty.centerHz"
        static let pskCenter = "digi.psk.centerHz"
        static let rttyShift = "digi.rtty.shiftHz"
        static let rttyBaud = "digi.rtty.baud"
        static let rttyReverse = "digi.rtty.reverse"
        static let rttyUnshiftOnSpace = "digi.rtty.unshiftOnSpace"
        static let afc = "digi.afc"
        static let squelch = "digi.squelch"
    }

    /// Defaults: RTTY centred for the usual 2125/2295 Hz tones, PSK at
    /// 1000 Hz (the rig's default PSK TONE).
    public static let defaultRTTYCenterHz = 2210.0
    public static let defaultPSKCenterHz = 1000.0

    /// - Parameter channels: the sources this app offers; a saved choice
    ///   outside them falls back to MAIN.
    public init(logSubsystem: String, channels: [ReceiveAudioChannel] = ReceiveAudioChannel.allCases) {
        logger = Logger(subsystem: logSubsystem, category: "digi-decoder")
        let defaults = SettingsStore.defaults
        defaults.register(defaults: [
            Key.rttyCenter: Self.defaultRTTYCenterHz,
            Key.pskCenter: Self.defaultPSKCenterHz,
            Key.rttyShift: 170.0,
            Key.rttyBaud: 45.45,
            Key.rttyReverse: false,
            Key.rttyUnshiftOnSpace: true,
            Key.afc: true,
            Key.squelch: 0.3,
        ])
        let mode = DigiMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .rtty
        self.mode = mode
        channel = ReceiveAudioChannel.restored(rawValue: defaults.string(forKey: Key.channel), offered: channels)
        centerHz = defaults.double(forKey: mode.isPSK ? Key.pskCenter : Key.rttyCenter)
        rttyShiftHz = defaults.double(forKey: Key.rttyShift)
        rttyBaud = defaults.double(forKey: Key.rttyBaud)
        rttyReverse = defaults.bool(forKey: Key.rttyReverse)
        rttyUnshiftOnSpace = defaults.bool(forKey: Key.rttyUnshiftOnSpace)
        afcEnabled = defaults.bool(forKey: Key.afc)
        squelch = defaults.double(forKey: Key.squelch)
        meters.reset(centerHz: centerHz)
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        rebuildDecoder()
        onSourceChanged?()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        startNewLine()
        onSourceChanged?()
    }

    // MARK: - Tuning

    /// A click on the strip, or Rig Tones.
    public func setCenter(_ hz: Double) {
        let clamped = min(DigiDecoder.stripSpanHz - 50, max(50, hz))
        centerHz = clamped
        defaults.set(clamped, forKey: mode.isPSK ? Key.pskCenter : Key.rttyCenter)
        meters.reset(centerHz: clamped)
        queue.async { [box] in box.decoder?.setCenter(clamped) }
    }

    private func savedCenter(for mode: DigiMode) -> Double {
        defaults.double(forKey: mode.isPSK ? Key.pskCenter : Key.rttyCenter)
    }

    private func rttyChanged(_ changed: Bool) {
        guard changed else { return }
        defaults.set(rttyShiftHz, forKey: Key.rttyShift)
        defaults.set(rttyBaud, forKey: Key.rttyBaud)
        defaults.set(rttyReverse, forKey: Key.rttyReverse)
        defaults.set(rttyUnshiftOnSpace, forKey: Key.rttyUnshiftOnSpace)
        if mode == .rtty { rebuildDecoder() }
    }

    private func rebuildDecoder() {
        generation += 1
        let decoder = DigiDecoder(
            mode: mode, rttySettings: decoderRTTYSettings, centerHz: centerHz,
            afc: afcEnabled, squelch: Float(squelch)
        )
        meters.reset(centerHz: centerHz)
        queue.async { [box] in box.decoder = decoder }
    }

    private func resetDecoder() {
        generation += 1
        meters.reset(centerHz: centerHz)
        queue.async { [box] in box.decoder?.reset() }
        startNewLine()
    }

    // MARK: - Audio

    /// Every receive chunk, on the main actor, whether or not decoding is
    /// on — cheap when it isn't.
    public func ingest(samples: [Float], sampleRate: Double, channel source: ReceiveAudioChannel) {
        trackSubAvailability(source)
        guard isRunning, !isDecodingFile, !isPausedForTransmit, source == channel else { return }
        submit(samples, sampleRate: sampleRate)
    }

    private func submit(_ samples: [Float], sampleRate: Double) {
        let generation = generation
        queue.async { [box, weak self] in
            guard let output = box.decoder?.process(samples: samples, sampleRate: sampleRate) else { return }
            Task { @MainActor [weak self] in
                self?.handle(output, generation: generation)
            }
        }
    }

    private func handle(_ output: DigiDecoderOutput, generation: Int) {
        guard generation == self.generation else { return }
        meters.update(output)
        append(output.text)
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

    public func rigInfoChanged(_ info: DigiRigInfo) {
        let oldReverse = decoderRTTYSettings.reverse
        rigInfo = info
        // A sideband change flips the tones: rebuild the RTTY decoder.
        if mode == .rtty, isRunning, decoderRTTYSettings.reverse != oldReverse { rebuildDecoder() }
        updateTransmitPause()
        updateModeHint()
    }

    /// The MyKiwiSDR window's demodulation while it's connected (nil
    /// otherwise): the sideband RTTY's polarity follows, and the "not a
    /// data mode" note, when that's the source.
    public func setMyKiwiSDRMode(_ mode: RigMode?) {
        guard mode != myKiwiSDRMode else { return }
        let oldReverse = decoderRTTYSettings.reverse
        myKiwiSDRMode = mode
        if self.mode == .rtty, isRunning, decoderRTTYSettings.reverse != oldReverse { rebuildDecoder() }
        updateModeHint()
    }

    private var myKiwiSDRMode: RigMode?

    /// The RTTY/PSK sender is transmitting (covers the lag before the poll
    /// sees PTT, as with the CW sender).
    public func setSenderActive(_ active: Bool) {
        senderActive = active
        updateTransmitPause()
    }

    private var senderActive = false

    private func updateTransmitPause() {
        let paused = senderActive || rigInfo.transmitting
        guard paused != isPausedForTransmit else { return }
        isPausedForTransmit = paused
        // Don't let the first audio after TX finish a half-framed
        // character from before it.
        if paused, isRunning { resetDecoder() }
    }

    private func updateModeHint() {
        var hint: RigMode?
        if let sourceMode, sourceMode != .unknown, !Self.suitableModes(for: mode).contains(sourceMode) {
            hint = sourceMode
        }
        if unsuitableSourceMode != hint { unsuitableSourceMode = hint }
    }

    /// RTTY is usually received in the rig's RTTY mode, PSK in DATA-U;
    /// either works in plain SSB too.
    static func suitableModes(for mode: DigiMode) -> Set<RigMode> {
        mode == .rtty ? [.rtty, .lsb, .usb, .dataUSB] : [.dataUSB, .usb, .lsb]
    }

    // MARK: - Files

    /// Pauses live decoding, decodes the file into the same text under a
    /// header line (with the current mode and centre), then live resumes.
    public func decodeFile(at url: URL) {
        guard !isDecodingFile else { return }
        isDecodingFile = true
        startNewLine()
        append("— \(url.lastPathComponent) —\n")
        // A fresh decoder of its own, so the live one keeps its state.
        let decoder = DigiDecoder(
            mode: mode, rttySettings: decoderRTTYSettings, centerHz: centerHz,
            afc: afcEnabled, squelch: Float(squelch)
        )
        let fileBox = DecoderBox()
        fileBox.decoder = decoder
        let queue = queue
        Task.detached(priority: .userInitiated) { [weak self] in
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let frames: AVAudioFrameCount = 8192
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                while file.framePosition < file.length {
                    try file.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
                    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
                    let text = queue.sync { fileBox.decoder?.process(samples: samples, sampleRate: format.sampleRate).text ?? "" }
                    if !text.isEmpty {
                        await self?.append(text)
                    }
                }
            } catch {
                await self?.reportFileError(error, url: url)
            }
            await self?.finishFile()
        }
    }

    private func reportFileError(_ error: any Error, url: URL) {
        errorMessage = String(localized: "digiReceiver.couldntRead \(url.lastPathComponent) \(error.localizedDescription)", bundle: .module)
    }

    private func finishFile() {
        startNewLine()
        isDecodingFile = false
    }

    // MARK: - Text

    /// All the text, received and sent (for Copy).
    public var decodedText: String {
        runs.map(\.text).joined()
    }

    public func clearText() {
        runs = []
    }

    /// The sender's echo: transmitted characters, shown in their own colour.
    public func appendTransmitted(_ text: String) {
        if runs.last?.isTransmit != true { startNewLine() }
        append(text, transmit: true)
    }

    private func append(_ text: String, transmit: Bool = false) {
        guard !text.isEmpty else { return }
        if let last = runs.indices.last, runs[last].isTransmit == transmit {
            runs[last].text += text
        } else {
            runs.append(DigiTextRun(text: text, isTransmit: transmit))
        }
        trim()
    }

    private func trim() {
        var total = runs.reduce(0) { $0 + $1.text.count }
        while total > Self.maxTextLength, !runs.isEmpty {
            let excess = total - Self.maxTextLength
            if runs[0].text.count <= excess {
                total -= runs[0].text.count
                runs.removeFirst()
            } else {
                runs[0].text = String(runs[0].text.dropFirst(excess))
                total -= excess
            }
        }
    }

    private func startNewLine() {
        if let last = runs.last?.text, !last.isEmpty, !last.hasSuffix("\n") {
            append("\n", transmit: runs.last?.isTransmit ?? false)
        }
    }
}

/// A stretch of the window's text: received, or sent by this station.
public struct DigiTextRun: Equatable, Sendable {
    public var text: String
    public var isTransmit: Bool
}

extension RigMode {
    /// Audio from this mode has the RF spectrum the right way up (USB,
    /// DATA-U), as opposed to inverted (LSB, the rig's RTTY mode — assumed
    /// lower sideband, see CLAUDE.md "Digital modes — RTTY/PSK").
    public var isUpperSidebandAudio: Bool {
        self == .usb || self == .dataUSB
    }
}

import Combine
import Foundation
import FTX1Core
import os

/// What the RTTY/PSK sender needs from the app: the transmit gate, keying,
/// and somewhere to send 8 kHz audio. The Mac's `HubService` implements it
/// (`HubService+DigiTransmitLink.swift`).
@MainActor
public protocol DigiTransmitLink: AnyObject {
    /// Why a transmission can't start (or must stop) now, nil when it may:
    /// the transmit gate, no rig, no transmit audio path, the rig keyed by
    /// something else (`keyedBySender` false).
    func digiTransmitBlock(keyedBySender: Bool) -> String?
    /// The transmitting side's mode, nil before it's known.
    var digiTransmitMode: RigMode? { get }
    /// What the rig reports (PTT).
    var digiRigIsKeyed: Bool { get }
    func digiSetKeyed(_ keyed: Bool)
    /// 16-bit little-endian mono PCM at 8 kHz (`AudioStreamFormat`).
    func digiSendAudio(_ pcm: Data)
}

/// Time for `DigiSender`'s pacing loop; replaced in tests.
public protocol DigiSenderClock: Sendable {
    /// Seconds on a monotonic clock.
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async
}

public struct SystemDigiSenderClock: DigiSenderClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Live-typeahead RTTY/PSK sending, as in fldigi: TX keys the rig and
/// sends what's in the box as it's typed (idling when the box is empty),
/// RX sends what's left plus the closing tail and unkeys, Stop unkeys at
/// once. Audio is generated just ahead of real time (`lead`), so typing
/// reaches the air quickly and Stop is near-instant.
///
/// Mode, centre frequency and RTTY settings come from the receiver at TX:
/// the signal goes out where the decoder is listening (after AFC), so an
/// answer lands on the station being decoded.
@MainActor
public final class DigiSender: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case transmitting
        /// RX pressed: sending the rest, then the tail.
        case finishing
    }

    @Published public private(set) var state = State.idle
    /// The typeahead box. The first `sentCount` characters have gone out.
    @Published public private(set) var text = ""
    @Published public private(set) var sentCount = 0
    /// Why the last transmission ended early, or why one couldn't start.
    @Published public private(set) var message: String?
    @Published public private(set) var transmitStartedAt: TimeInterval?
    @Published public var theirCall = ""
    /// dBFS peak of the generated audio.
    @Published public var levelDb: Double {
        didSet { SettingsStore.defaults.set(levelDb, forKey: Self.levelKey) }
    }
    @Published public var macros: [DigiMacro] {
        didSet { DigiMacro.save(macros) }
    }

    /// Each character as it starts going out, for the transmit echo.
    public var onEcho: ((String) -> Void)?
    /// Called on every state change (the receiver pauses while sending).
    public var onStateChanged: ((State) -> Void)?

    public static let transmitLimit: TimeInterval = 180
    static let lead: TimeInterval = 0.25
    static let tick: TimeInterval = 0.02
    static let chunk = 160
    /// After the last sample: the lead still to play plus the output's own buffer.
    static let unkeyDelay: TimeInterval = lead + 0.3
    /// How long the rig may read "not keyed" before the sender gives up.
    static let keyLossLimit: TimeInterval = 1.0
    /// No key-loss check this soon after keying (the first PTT read lags).
    static let keyLossGrace: TimeInterval = 2.0
    public static let levelRange: ClosedRange<Double> = -30 ... 0
    private static let levelKey = "digi.txLevelDb"

    private weak var link: DigiTransmitLink?
    private let receiver: DigiReceiver
    private let clock: DigiSenderClock
    private let logger: Logger
    private var characters: [Character] = []
    private var modulator: DigiModulator?
    private var loop: Task<Void, Never>?
    private var keyLostAt: TimeInterval?

    public init(link: DigiTransmitLink, receiver: DigiReceiver, logSubsystem: String,
                clock: DigiSenderClock = SystemDigiSenderClock()) {
        self.link = link
        self.receiver = receiver
        self.clock = clock
        logger = Logger(subsystem: logSubsystem, category: "digi-sender")
        SettingsStore.defaults.register(defaults: [Self.levelKey: -6.0])
        levelDb = SettingsStore.defaults.double(forKey: Self.levelKey)
        macros = DigiMacro.load()
    }

    public var isTransmitting: Bool { state != .idle }

    /// Why TX would be refused right now, nil when it would start.
    public var blockReason: String? {
        guard let link else { return nil }
        if let reason = link.digiTransmitBlock(keyedBySender: isTransmitting) { return reason }
        if let mode = link.digiTransmitMode, !Self.transmitModes.contains(mode) {
            return String(localized: "digiSender.wrongMode \(mode.displayName)", bundle: .module)
        }
        return nil
    }

    /// AFSK and PSK are audio: the rig must pass audio through on SSB.
    static let transmitModes: Set<RigMode> = [.dataUSB, .usb, .lsb]

    public var unsentCount: Int { characters.count - sentCount }

    // MARK: - The box

    /// The box after an edit. Edits that would change text already sent
    /// are refused (the box keeps its old text).
    @discardableResult
    public func edit(to newText: String) -> String {
        let new = Array(newText)
        guard new.count >= sentCount, Array(new.prefix(sentCount)) == Array(characters.prefix(sentCount)) else {
            return text
        }
        characters = new
        text = newText
        return text
    }

    public func append(_ addition: String) {
        edit(to: text + addition)
    }

    /// Empties the unsent part (the sent part goes when the transmission ends).
    public func clearUnsent() {
        edit(to: String(characters.prefix(sentCount)))
    }

    // MARK: - TX / RX / Stop

    public func transmit() {
        guard state == .idle else {
            // RX pressed, then TX again before the tail: keep going.
            if state == .finishing, !(modulator?.isFinished ?? true) { setState(.transmitting) }
            return
        }
        if let reason = blockReason {
            message = reason
            return
        }
        guard let modulator = makeModulator() else { return }
        message = nil
        self.modulator = modulator
        modulator.onCharacterStarted = { [weak self] character in
            self?.onEcho?(String(character))
        }
        keyLostAt = nil
        link?.digiSetKeyed(true)
        setState(.transmitting)
        logger.notice("TX \(self.receiver.mode.title, privacy: .public) at \(Int(self.receiver.meters.trackedHz)) Hz")
        loop = Task { [weak self] in await self?.run() }
    }

    /// Send what's left, the tail, then unkey.
    public func finish() {
        guard state == .transmitting else { return }
        setState(.finishing)
    }

    /// Unkey now; unsent text is dropped.
    public func stop(reason: String? = nil) {
        loop?.cancel()
        loop = nil
        let wasTransmitting = state != .idle
        modulator = nil
        if wasTransmitting {
            link?.digiSetKeyed(false)
            logger.notice("TX stopped\(reason.map { ": " + $0 } ?? "", privacy: .public)")
        }
        message = reason
        endTransmission(keepUnsent: false)
    }

    private func endTransmission(keepUnsent: Bool) {
        let unsent = keepUnsent ? String(characters.dropFirst(sentCount)) : ""
        characters = Array(unsent)
        text = unsent
        sentCount = 0
        transmitStartedAt = nil
        if state != .idle { onEcho?("\n") }
        setState(.idle)
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChanged?(new)
    }

    private func makeModulator() -> DigiModulator? {
        let level = Float(pow(10, levelDb / 20))
        let center = (receiver.meters.trackedHz > 0 ? receiver.meters.trackedHz : receiver.centerHz).rounded()
        switch receiver.mode {
        case .rtty:
            let upper = link?.digiTransmitMode?.isUpperSidebandAudio ?? false
            let tones = receiver.rttySettings.tones(centerHz: center, upperSideband: upper)
            return RTTYModulator(markHz: tones.markHz, spaceHz: tones.spaceHz, baud: receiver.rttyBaud, level: level)
        case .bpsk31, .bpsk63:
            return PSKModulator(carrierHz: center, baud: receiver.mode.pskBaud, level: level)
        }
    }

    // MARK: - Pacing

    private func run() async {
        let start = clock.now()
        transmitStartedAt = start
        var samplesSent = 0
        while !Task.isCancelled, let modulator {
            let now = clock.now()
            let elapsed = now - start

            if elapsed >= Self.transmitLimit {
                stop(reason: String(localized: "digiSender.limitReached", bundle: .module))
                return
            }
            if let reason = link?.digiTransmitBlock(keyedBySender: true) {
                stop(reason: reason)
                return
            }
            if elapsed > Self.keyLossGrace, let link, !link.digiRigIsKeyed {
                if let lostAt = keyLostAt {
                    if now - lostAt > Self.keyLossLimit {
                        stop(reason: String(localized: "digiSender.keyingEnded", bundle: .module))
                        return
                    }
                } else {
                    keyLostAt = now
                }
            } else {
                keyLostAt = nil
            }

            let target = Int(((elapsed + Self.lead) * DigiDecoder.sampleRate).rounded())
            while samplesSent < target, !modulator.isFinished {
                if state == .finishing, sentCount >= characters.count { modulator.beginTail() }
                let samples = modulator.render(Self.chunk) { [weak self] in self?.nextCharacter() }
                link?.digiSendAudio(Self.pcm(samples))
                samplesSent += samples.count
            }

            if modulator.isFinished {
                // Let the audio already sent play out, then unkey.
                let playedOut = start + Double(samplesSent) / DigiDecoder.sampleRate + Self.unkeyDelay - Self.lead
                let wait = max(0, playedOut - clock.now())
                await clock.sleep(seconds: wait)
                guard !Task.isCancelled else { return }
                link?.digiSetKeyed(false)
                loop = nil
                self.modulator = nil
                logger.notice("TX done")
                endTransmission(keepUnsent: true)
                return
            }
            await clock.sleep(seconds: Self.tick)
        }
    }

    /// The next unsent character, or nil to idle. Once RX is pressed,
    /// nothing typed after the tail has started goes out.
    private func nextCharacter() -> Character? {
        guard sentCount < characters.count else { return nil }
        let character = characters[sentCount]
        sentCount += 1
        return character
    }

    static func pcm(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - Macros

    /// Appends the macro's text; `{TX}` at the start also keys, `{RX}` at
    /// the end returns to receive once the box has gone out.
    public func run(_ macro: DigiMacro) {
        switch macro.expanded(myCall: StationSettings.callsign, myGrid: StationSettings.gridSquare, theirCall: theirCall) {
        case .failure(let problem):
            message = problem.message
        case .success(let expansion):
            message = nil
            append(expansion.text)
            if expansion.startsTransmit, state == .idle { transmit() }
            if expansion.endsTransmit { finish() }
        }
    }
}

/// A send-pane macro: text with `{MYCALL}`, `{MYGRID}`, `{CALL}`, and
/// optional `{TX}` at the start / `{RX}` at the end.
public struct DigiMacro: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var label: String
    public var text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }

    public struct Expansion: Equatable, Sendable {
        public var text: String
        public var startsTransmit: Bool
        public var endsTransmit: Bool
    }

    public enum Problem: Error {
        case missing(String)

        public var message: String {
            switch self {
            case .missing(let what): String(localized: "digiSender.isEmpty \(what)", bundle: .module)
            }
        }
    }

    public func expanded(myCall: String, myGrid: String, theirCall: String) -> Result<Expansion, Problem> {
        var body = text.trimmingCharacters(in: .whitespaces)
        var startsTransmit = false
        var endsTransmit = false
        if body.uppercased().hasPrefix("{TX}") {
            startsTransmit = true
            body = String(body.dropFirst(4))
        }
        if body.uppercased().hasSuffix("{RX}") {
            endsTransmit = true
            body = String(body.dropLast(4))
        }
        let stationSettings = String(localized: "digiSender.settingsStation", bundle: .module)
        let values: [(String, String, String)] = [
            ("{MYCALL}", myCall, String(localized: "digiSender.yourCallsign \(stationSettings)", bundle: .module)),
            ("{MYGRID}", myGrid, String(localized: "digiSender.yourGridSquare \(stationSettings)", bundle: .module)),
            ("{CALL}", theirCall, String(localized: "digiSender.theirCall", bundle: .module)),
        ]
        for (placeholder, value, name) in values where body.uppercased().contains(placeholder) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return .failure(.missing(name)) }
            body = body.replacingOccurrences(of: placeholder, with: trimmed, options: .caseInsensitive)
        }
        return .success(Expansion(text: body, startsTransmit: startsTransmit, endsTransmit: endsTransmit))
    }

    /// Each sent as its own transmission: a space before and a line break
    /// after keep it apart from the other station's text.
    public static let defaults: [DigiMacro] = [
        DigiMacro(label: "CQ", text: "{TX}\nCQ CQ CQ de {MYCALL} {MYCALL} {MYCALL}\nCQ CQ CQ de {MYCALL} {MYCALL} {MYCALL} pse k\n{RX}"),
        DigiMacro(label: "Answer", text: "{TX}\n{CALL} {CALL} de {MYCALL} {MYCALL} {MYCALL} k\n{RX}"),
        DigiMacro(label: "Report", text: "{TX}\n{CALL} de {MYCALL} - tnx for the call, ur rst 599 599 - grid {MYGRID} - btu {CALL} de {MYCALL} k\n{RX}"),
        DigiMacro(label: "73", text: "{TX}\n{CALL} de {MYCALL} - tnx for the qso, 73 - {CALL} de {MYCALL} sk\n{RX}"),
        DigiMacro(label: "QRZ?", text: "{TX}\nQRZ? de {MYCALL} k\n{RX}"),
    ]

    private static let defaultsKey = "digi.macros"

    public static func load() -> [DigiMacro] {
        guard let data = SettingsStore.defaults.data(forKey: defaultsKey),
              let macros = try? JSONDecoder().decode([DigiMacro].self, from: data) else { return defaults }
        return macros
    }

    public static func save(_ macros: [DigiMacro]) {
        if let data = try? JSONEncoder().encode(macros) {
            SettingsStore.defaults.set(data, forKey: defaultsKey)
        }
    }
}

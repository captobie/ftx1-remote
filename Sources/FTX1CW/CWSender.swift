import Combine
import Foundation
import FTX1Core
import os

/// What `CWSender` needs from a route to the rig: the Mac's `HubService`,
/// or the iPad's Pi-direct `PiDirectViewModel`. Each route checks its own
/// transmit gate (`cwSendBlock`) and plays the memory through its own
/// transmit-gated `RigCommand.playCWTextMemory`.
@MainActor
public protocol CWKeyerLink: AnyObject {
    var cwRigState: RigState { get }
    var cwRigStatePublisher: AnyPublisher<RigState, Never> { get }
    /// Why the rig can't send right now, or nil. Checked before every
    /// chunk; the queue waits (rather than failing) while there's a reason.
    var cwSendBlock: CWSendBlock? { get }
    /// Makes sure keyer memory `slot` is a TEXT memory (a MESSAGE slot
    /// would play recorded audio instead).
    func ensureCWTextMemory(slot: Int) async throws
    /// Writes CW TEXT keyer memory `slot`; returns what the rig stored.
    func writeCWKeyerMemory(slot: Int, text: String) async throws -> String
    /// "KY0<slot>": plays the memory, or stops keying with slot 0.
    func playCWTextMemory(slot: Int)
    /// The keyer lease (the hub's CW keyer coordinator, so the Mac's CW
    /// window and the iPad's don't overwrite or restart each other): nil
    /// when it's ours (granted or refreshed), otherwise who has it, e.g.
    /// "the Mac's CW window". Taken before every chunk.
    func acquireCWKeyer() async throws -> String?
    /// Gives the lease back — after each line, and on Stop.
    func releaseCWKeyer()
}

/// The send side of CW (the Mac's Tools → CW window, the iPad's CW pane on
/// Pi direct): typed lines and macros are keyed by the rig's own keyer,
/// through one dedicated CW TEXT keyer memory (`slot`, default 1): write up
/// to 50 characters there (`KM`, via `CWKeyerLink.writeCWKeyerMemory`),
/// play it (`KY0<slot>`, the transmit-gated `RigCommand.
/// playCWTextMemory`), wait for the rig to finish, repeat. The rig does the
/// timing, so network lag can't distort the CW. What that costs: about 2 s
/// per write (see `RigctldClient.writeKeyerMemory`) plus finish detection,
/// so a line longer than 50 characters has a pause of a few seconds
/// between chunks.
///
/// Everything here was probed on the real rig, 2026-10-02 (dummy load):
/// the rig keys only with break-in on; it appends the "}" end marker
/// itself; it keeps exactly 50 characters and rejects more; it keyed every
/// character in `CWText.allowed`; PTT reads 3 while keying, with the odd
/// spurious 0; a second play while one runs restarts the message (so
/// chunks go strictly one after another); "KY00" stops it.
@MainActor
public final class CWSender: ObservableObject {
    @Published public private(set) var items: [CWSendItem] = []
    /// What the rig is doing for the send pane right now, e.g. "Writing
    /// keyer memory…" — nil when idle.
    @Published public private(set) var activity: String?
    /// The station being worked (the Mac's Log QSO pane, the iPad's send
    /// section), for `{CALL}` in macros; on the Mac also filled by clicking
    /// a callsign in the decoded text.
    @Published public var theirCall = ""
    @Published public var slot: Int {
        didSet { SettingsStore.defaults.set(slot, forKey: DefaultsKey.slot) }
    }
    @Published public var macros: [CWMacro] {
        didSet { CWMacro.save(macros) }
    }

    /// Set by the app: true from the first write of a run until the queue
    /// is done, so the decoder can pause (see `CWReceiver.setSenderActive`).
    public var onActiveChanged: ((Bool) -> Void)?

    private weak var link: (any CWKeyerLink)?
    private var runTask: Task<Void, Never>?
    /// Which run `runTask` is, so a cancelled run finishing late can't
    /// clear a newer one's state.
    private var runGeneration = 0
    private var pttCancellable: AnyCancellable?
    private var lastPTTOnAt = Date.distantPast
    private var slotCheckedAsText: Int?
    /// This sender holds the keyer lease: between the first chunk of a line
    /// and its release. Stop only sends "KY00" then — a sender that's still
    /// waiting for the keyer mustn't cut off whoever is keying.
    private var holdsKeyer = false
    private let logger: Logger

    private static let maxItems = 200

    private enum DefaultsKey {
        static let slot = "cw.keyerSlot"
    }

    /// - Parameter logSubsystem: the app's `os.Logger` subsystem; category
    ///   "cw-sender".
    public init(link: any CWKeyerLink, logSubsystem: String) {
        self.link = link
        logger = Logger(subsystem: logSubsystem, category: "cw-sender")
        let stored = SettingsStore.defaults.integer(forKey: DefaultsKey.slot)
        slot = (1...5).contains(stored) ? stored : 1
        macros = CWMacro.load()
        watchPTT(of: link)
    }

    /// Switches to another route to the rig (the iPad: Mac hub or Pi
    /// direct). Stops anything running on the old one first; the new
    /// route's slot is checked again before its first write.
    public func use(_ link: any CWKeyerLink) {
        guard self.link !== link else { return }
        stop()
        self.link = link
        slotCheckedAsText = nil
        lastPTTOnAt = .distantPast
        watchPTT(of: link)
    }

    /// Whether `link` is the route in use — so a route that isn't can't
    /// stop the sender (e.g. its lock or link changing in the background).
    public func isUsing(_ link: any CWKeyerLink) -> Bool {
        self.link === link
    }

    private func watchPTT(of link: any CWKeyerLink) {
        pttCancellable = link.cwRigStatePublisher
            .map(\.ptt)
            .removeDuplicates()
            .sink { [weak self] ptt in
                if ptt { self?.lastPTTOnAt = Date() }
            }
    }

    public var isSending: Bool { runTask != nil }

    /// Something can be stopped: a run, or lines still queued.
    public var canStop: Bool { isSending || items.contains(where: \.isWaiting) }

    /// Why the rig can't send right now, or nil — for the pane's status line.
    public var block: CWSendBlock? { link?.cwSendBlock }

    // MARK: - Queueing

    /// Queues a typed line. Returns why nothing was queued, if so.
    @discardableResult
    public func enqueue(_ line: String) -> String? {
        let prepared = CWText.prepare(line)
        guard !prepared.text.isEmpty else {
            return prepared.dropped.isEmpty ? nil : "Nothing the keyer can send in that line"
        }
        items.append(CWSendItem(text: prepared.text, chunks: CWText.chunks(prepared.text), dropped: prepared.dropped))
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        startIfNeeded()
        return nil
    }

    /// A macro with its placeholders filled in, for the pane to put in the
    /// send line (macros don't send directly — user decision 2026-10-03, so
    /// the text can be edited first). `stationSettings` says where the
    /// user sets their own call and grid, for the message when one is empty.
    public func text(for macro: CWMacro, stationSettings: String = "Settings → Station") -> Result<String, CWMacro.Problem> {
        macro.expanded(myCall: StationSettings.callsign, myGrid: StationSettings.gridSquare, theirCall: theirCall,
                       stationSettings: stationSettings)
    }

    /// Stops keying at once and drops everything not yet sent.
    public func stop() {
        guard canStop else { return }
        runTask?.cancel()
        runTask = nil
        if holdsKeyer {
            link?.playCWTextMemory(slot: 0)
        }
        releaseKeyer()
        for index in items.indices where items[index].isWaiting {
            items[index].state = .stopped
        }
        activity = nil
        onActiveChanged?(false)
        logger.info("stopped")
    }

    public func clearLog() {
        items.removeAll { !$0.isWaiting }
    }

    // MARK: - The send loop

    private func startIfNeeded() {
        guard runTask == nil, items.contains(where: \.isWaiting) else { return }
        onActiveChanged?(true)
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.run(generation: generation)
        }
    }

    private func run(generation: Int) async {
        defer {
            if generation == runGeneration {
                runTask = nil
                activity = nil
                onActiveChanged?(false)
            }
        }
        while !Task.isCancelled, let index = items.firstIndex(where: \.isWaiting) {
            let id = items[index].id
            do {
                try await send(itemID: id)
                // Between lines, someone else may take the keyer.
                releaseKeyer()
            } catch is CancellationError {
                return
            } catch {
                releaseKeyer()
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].state = .failed(error.localizedDescription)
                logger.error("send failed: \(error.localizedDescription, privacy: .public)")
                // Don't carry on with later lines out of order.
                for later in items.indices where items[later].isWaiting {
                    items[later].state = .stopped
                }
                return
            }
        }
    }

    private func send(itemID id: UUID) async throws {
        while let index = items.firstIndex(where: { $0.id == id }), items[index].sentChunks < items[index].chunks.count {
            let chunk = items[index].chunks[items[index].sentChunks]
            try await waitUntilSendable()
            try await waitForKeyer()
            guard let link else { throw CancellationError() }
            items[index].state = .sending

            if slotCheckedAsText != slot {
                activity = "Checking keyer memory \(slot)…"
                try await link.ensureCWTextMemory(slot: slot)
                slotCheckedAsText = slot
            }
            activity = "Writing keyer memory \(slot)…"
            let stored = try await link.writeCWKeyerMemory(slot: slot, text: chunk)
            try Task.checkCancellation()
            if stored != chunk {
                logger.notice("keyer memory holds \"\(stored, privacy: .public)\", sent \"\(chunk, privacy: .public)\"")
            }

            // The rig may have changed (TX disabled, band, BK-IN) during
            // the ~2 s write.
            if let block = link.cwSendBlock {
                throw CWSendError.blocked(block.message)
            }
            let wpm = max(link.cwRigState.cwSpeedWpm ?? 20, 4)
            let expected = CWText.duration(of: chunk, wpm: wpm)
            activity = "Sending at \(wpm) WPM…"
            let startedAt = Date()
            link.playCWTextMemory(slot: slot)
            try await waitUntilKeyed(startedAt: startedAt, expected: expected)
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].sentChunks += 1
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = .sent
        }
    }

    /// Waits while something blocks sending (showing it in the pane).
    private func waitUntilSendable() async throws {
        while let link, let block = link.cwSendBlock {
            activity = "Waiting: \(block.message)"
            try await Task.sleep(for: .milliseconds(500))
        }
        guard link != nil else { throw CancellationError() }
    }

    /// Takes (or refreshes) the keyer lease, waiting while another sender
    /// has it — the Mac's CW window and the iPad's take turns line by line.
    private func waitForKeyer() async throws {
        while true {
            guard let link else { throw CancellationError() }
            guard let holder = try await link.acquireCWKeyer() else {
                holdsKeyer = true
                return
            }
            activity = "Waiting: \(holder) is sending"
            try await Task.sleep(for: .seconds(1))
            // Whatever blocked before may have changed while waiting.
            try await waitUntilSendable()
        }
    }

    private func releaseKeyer() {
        guard holdsKeyer else { return }
        holdsKeyer = false
        link?.releaseCWKeyer()
    }

    /// The rig keys the memory on its own; there's no "done" readback. Done
    /// means: most of the expected keying time has passed and PTT has read
    /// off for a second (one spurious 0 mid-message was seen, so a single
    /// 0 isn't trusted). Capped, in case PTT never shows TX at all.
    private func waitUntilKeyed(startedAt: Date, expected: TimeInterval) async throws {
        while true {
            try await Task.sleep(for: .milliseconds(250))
            guard let link else { throw CancellationError() }
            let elapsed = Date().timeIntervalSince(startedAt)
            let pttOn = link.cwRigState.ptt
            if elapsed >= expected * 0.9, !pttOn, Date().timeIntervalSince(lastPTTOnAt) >= 1 {
                if lastPTTOnAt < startedAt {
                    logger.notice("no TX seen while the keyer memory played (break-in off?)")
                }
                return
            }
            if elapsed > expected * 1.5 + 5 {
                logger.notice("keying still not finished after \(elapsed, format: .fixed(precision: 1)) s (expected \(expected, format: .fixed(precision: 1)) s); moving on")
                return
            }
        }
    }
}

// MARK: - Items

public struct CWSendItem: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case queued
        case sending
        case sent
        case stopped
        case failed(String)
    }

    public let id = UUID()
    /// What will be keyed, after `CWText.prepare`.
    public let text: String
    /// `text` with prosigns written the way they're typed (`<BT>`, not
    /// `=`), for the log.
    public var displayText: String { CWText.display(text) }
    public let chunks: [String]
    /// Characters left out because the keyer can't send them.
    public let dropped: String
    public internal(set) var sentChunks = 0
    public internal(set) var state = State.queued

    public var isWaiting: Bool { state == .queued || state == .sending }
}

public enum CWSendBlock: Equatable, Sendable {
    case notConnected
    case transmitDisabled
    /// A route's own transmit gate said no (the iPad's Pi direct:
    /// `PiDirectViewModel.transmitBlockReason`), with its reason.
    case transmitBlocked(String)
    case notCW(RigMode)
    case outsideBand
    case breakInOff

    public var message: String {
        switch self {
        case .notConnected: "the rig isn't connected"
        case .transmitDisabled: "transmit is turned off (Settings → rigctld → Enable Transmit)"
        case .transmitBlocked(let reason): reason.prefix(1).lowercased() + reason.dropFirst()
        case .notCW(let mode): "the rig is in \(mode.displayName), not CW"
        case .outsideBand: "the rig is outside the amateur bands"
        case .breakInOff: "break-in is off — the rig only keys its memory with BK-IN on"
        }
    }
}

public enum CWSendError: LocalizedError {
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let reason): "Not sent: \(reason)"
        }
    }
}

// MARK: - Text

/// Turning typed text into what the FTX-1's keyer memory takes.
public enum CWText {
    /// Every character here was keyed correctly by the rig (2026-10-02).
    /// ";" can never be allowed: it ends the CAT command.
    public static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /?,.=+-()@:")

    /// Prosigns in angle brackets, sent as the punctuation the keyer keys
    /// for them. Others (e.g. <SK>) have no single character the keyer is
    /// known to take, so their letters are sent as a word.
    public static let prosigns: [String: String] = ["<BT>": "=", "<AR>": "+", "<KN>": "("]

    public static let memoryLength = 50

    /// Keyed text with the prosign characters written back in angle
    /// brackets, for display. A typed "=" also shows as <BT> — it's the
    /// same character on the air.
    public static func display(_ keyed: String) -> String {
        var text = ""
        for character in keyed {
            if let prosign = prosigns.first(where: { $0.value == String(character) })?.key {
                text += prosign
            } else {
                text.append(character)
            }
        }
        return text
    }

    /// Uppercased, prosigns mapped, other characters dropped, whitespace
    /// collapsed. `dropped` lists what was removed, for the pane to show.
    public static func prepare(_ line: String) -> (text: String, dropped: String) {
        var text = line.uppercased()
        for (prosign, character) in prosigns {
            text = text.replacingOccurrences(of: prosign, with: character)
        }
        text = text.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        var kept = ""
        var dropped = ""
        for character in text {
            if character.isWhitespace {
                kept.append(" ")
            } else if allowed.contains(character) {
                kept.append(character)
            } else if !dropped.contains(character) {
                dropped.append(character)
            }
        }
        let words = kept.split(separator: " ")
        return (words.joined(separator: " "), dropped)
    }

    /// Splits at word boundaries into pieces of at most `memoryLength`
    /// characters (a longer word is cut).
    public static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            var word = word
            while word.count > memoryLength {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(String(word.prefix(memoryLength)))
                word = String(word.dropFirst(memoryLength))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= memoryLength {
                current += " " + word
            } else {
                chunks.append(current)
                current = word
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Keying time at `wpm` (PARIS timing: a dit is 1.2/wpm s; elements are
    /// 1 or 3 units with 1-unit gaps, 3 units between characters, 7 between
    /// words). The rig may weight or space differently; this only sets
    /// when finish detection starts looking.
    public static func duration(of text: String, wpm: Int) -> TimeInterval {
        var units = 0
        for (index, word) in text.split(separator: " ").enumerated() {
            if index > 0 { units += 7 }
            for (position, character) in word.enumerated() {
                if position > 0 { units += 3 }
                let pattern = morse[character] ?? "...."
                units += pattern.reduce(0) { $0 + ($1 == "-" ? 3 : 1) } + pattern.count - 1
            }
        }
        return Double(units) * 1.2 / Double(wpm)
    }

    private static let morse: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.",
        "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.",
        "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-",
        "V": "...-", "W": ".--", "X": "-..-", "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        "/": "-..-.", "?": "..--..", ",": "--..--", ".": ".-.-.-", "=": "-...-",
        "+": ".-.-.", "-": "-....-", "(": "-.--.", ")": "-.--.-", "@": ".--.-.", ":": "---...",
    ]
}

// MARK: - Macros

public struct CWMacro: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var label: String
    public var text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }

    public enum Problem: Error {
        case missing(String)

        public var message: String {
            switch self {
            case .missing(let what): "\(what) is empty"
            }
        }
    }

    /// `{MYCALL}`/`{MYGRID}` from `StationSettings` (set under
    /// `stationSettings`), `{CALL}` from the
    /// pane's Their call field.
    public func expanded(myCall: String, myGrid: String, theirCall: String,
                         stationSettings: String = "Settings → Station") -> Result<String, Problem> {
        let values: [(String, String, String)] = [
            ("{MYCALL}", myCall, "Your callsign (\(stationSettings))"),
            ("{MYGRID}", myGrid, "Your grid square (\(stationSettings))"),
            ("{CALL}", theirCall, "Their call"),
        ]
        var result = text
        for (placeholder, value, name) in values where result.uppercased().contains(placeholder) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return .failure(.missing(name)) }
            result = result.replacingOccurrences(of: placeholder, with: trimmed, options: .caseInsensitive)
        }
        return .success(result)
    }

    public static let defaults: [CWMacro] = [
        CWMacro(label: "CQ", text: "CQ CQ CQ DE {MYCALL} {MYCALL} K"),
        CWMacro(label: "Answer", text: "{CALL} DE {MYCALL} {MYCALL} K"),
        CWMacro(label: "Report", text: "{CALL} DE {MYCALL} TNX FER CALL <BT> UR RST 599 599 <BT> BK"),
        CWMacro(label: "73", text: "{CALL} DE {MYCALL} TNX FER QSO 73 E E"),
        CWMacro(label: "QRZ?", text: "QRZ? DE {MYCALL} K"),
        CWMacro(label: "AGN?", text: "AGN? AGN?"),
    ]

    private static let defaultsKey = "cw.macros"

    public static func load() -> [CWMacro] {
        guard let data = SettingsStore.defaults.data(forKey: defaultsKey),
              let macros = try? JSONDecoder().decode([CWMacro].self, from: data) else { return defaults }
        return macros
    }

    public static func save(_ macros: [CWMacro]) {
        if let data = try? JSONEncoder().encode(macros) {
            SettingsStore.defaults.set(data, forKey: defaultsKey)
        }
    }
}

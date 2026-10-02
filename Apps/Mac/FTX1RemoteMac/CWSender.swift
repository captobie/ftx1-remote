import Combine
import Foundation
import FTX1Core
import os

/// The send side of the Tools → CW window (v2): typed lines and macros are
/// keyed by the rig's own keyer, through one dedicated CW TEXT keyer memory
/// (`slot`, default 1): write up to 50 characters there (`KM`, via
/// `HubService.writeCWKeyerMemory`), play it (`KY0<slot>`, the
/// transmit-gated `RigCommand.playCWTextMemory`), wait for the rig to
/// finish, repeat. The rig does the timing, so network lag can't distort
/// the CW. What that costs: about 2 s per write (see `RigctldClient.
/// writeKeyerMemory`) plus finish detection, so a line longer than 50
/// characters has a pause of a few seconds between chunks.
///
/// Everything here was probed on the real rig, 2026-10-02 (dummy load):
/// the rig keys only with break-in on; it appends the "}" end marker
/// itself; it keeps exactly 50 characters and rejects more; it keyed every
/// character in `CWText.allowed`; PTT reads 3 while keying, with the odd
/// spurious 0; a second play while one runs restarts the message (so
/// chunks go strictly one after another); "KY00" stops it.
final class CWSender: ObservableObject {
    @Published private(set) var items: [CWSendItem] = []
    /// What the rig is doing for the send pane right now, e.g. "Writing
    /// keyer memory…" — nil when idle.
    @Published private(set) var activity: String?
    /// The station being worked ("Their call" in the pane), for `{CALL}` in
    /// macros; also filled by clicking a callsign in the decoded text.
    @Published var theirCall = ""
    @Published var slot: Int {
        didSet { UserDefaults.standard.set(slot, forKey: DefaultsKey.slot) }
    }
    @Published var macros: [CWMacro] {
        didSet { CWMacro.save(macros) }
    }

    /// Set by `CWReceiver`'s owner: true from the first write of a run until
    /// the queue is done, so the decoder can pause (see `CWReceiver.
    /// setSenderActive`).
    var onActiveChanged: ((Bool) -> Void)?

    private weak var hub: HubService?
    private var runTask: Task<Void, Never>?
    /// Which run `runTask` is, so a cancelled run finishing late can't
    /// clear a newer one's state.
    private var runGeneration = 0
    private var pttCancellable: AnyCancellable?
    private var lastPTTOnAt = Date.distantPast
    private var slotCheckedAsText: Int?

    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "cw-sender")
    private static let maxItems = 200

    private enum DefaultsKey {
        static let slot = "cw.keyerSlot"
    }

    init(hub: HubService) {
        self.hub = hub
        let stored = UserDefaults.standard.integer(forKey: DefaultsKey.slot)
        slot = (1...5).contains(stored) ? stored : 1
        macros = CWMacro.load()
        pttCancellable = hub.$rigState
            .map(\.ptt)
            .removeDuplicates()
            .sink { [weak self] ptt in
                if ptt { self?.lastPTTOnAt = Date() }
            }
    }

    var isSending: Bool { runTask != nil }

    // MARK: - Queueing

    /// Queues a typed line. Returns why nothing was queued, if so.
    @discardableResult
    func enqueue(_ line: String) -> String? {
        let prepared = CWText.prepare(line)
        guard !prepared.text.isEmpty else {
            return prepared.dropped.isEmpty ? nil : "Nothing the keyer can send in that line"
        }
        items.append(CWSendItem(text: prepared.text, chunks: CWText.chunks(prepared.text), dropped: prepared.dropped))
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        startIfNeeded()
        return nil
    }

    /// Expands a macro's placeholders and queues it. Returns why not, if so.
    @discardableResult
    func send(_ macro: CWMacro) -> String? {
        switch macro.expanded(myCall: StationSettings.callsign, myGrid: StationSettings.gridSquare, theirCall: theirCall) {
        case .success(let text): return enqueue(text)
        case .failure(let problem): return problem.message
        }
    }

    /// Stops keying at once and drops everything not yet sent.
    func stop() {
        guard runTask != nil || items.contains(where: \.isWaiting) else { return }
        runTask?.cancel()
        runTask = nil
        hub?.send(.playCWTextMemory(slot: 0))
        for index in items.indices where items[index].isWaiting {
            items[index].state = .stopped
        }
        activity = nil
        onActiveChanged?(false)
        Self.logger.info("stopped")
    }

    func clearLog() {
        items.removeAll { !$0.isWaiting }
    }

    // MARK: - Why sending can't happen

    /// Why the rig can't send right now, or nil. Checked before every
    /// chunk; the queue waits (rather than failing) while there's a reason.
    static func blockReason(hub: HubService) -> CWSendBlock? {
        let rig = hub.rigState
        if hub.connectionState != .connected { return .notConnected }
        if !hub.transmitEnabled { return .transmitDisabled }
        if rig.mode != .cw { return .notCW(rig.mode) }
        if BandPlan.band(containing: rig.frequencyHz) == nil { return .outsideBand }
        if rig.breakIn == false { return .breakInOff }
        return nil
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
            } catch is CancellationError {
                return
            } catch {
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].state = .failed(error.localizedDescription)
                Self.logger.error("send failed: \(error.localizedDescription, privacy: .public)")
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
            guard let hub else { throw CancellationError() }
            items[index].state = .sending

            if slotCheckedAsText != slot {
                activity = "Checking keyer memory \(slot)…"
                try await hub.ensureCWTextMemory(slot: slot)
                slotCheckedAsText = slot
            }
            activity = "Writing keyer memory \(slot)…"
            let stored = try await hub.writeCWKeyerMemory(slot: slot, text: chunk)
            try Task.checkCancellation()
            if stored != chunk {
                Self.logger.notice("keyer memory holds \"\(stored, privacy: .public)\", sent \"\(chunk, privacy: .public)\"")
            }

            // The rig may have changed (TX disabled, band, BK-IN) during
            // the ~2 s write.
            if let block = Self.blockReason(hub: hub) {
                throw CWSendError.blocked(block.message)
            }
            let wpm = max(hub.rigState.cwSpeedWpm ?? 20, 4)
            let expected = CWText.duration(of: chunk, wpm: wpm)
            activity = "Sending at \(wpm) WPM…"
            let startedAt = Date()
            hub.send(.playCWTextMemory(slot: slot))
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
        while let hub, let block = Self.blockReason(hub: hub) {
            activity = "Waiting: \(block.message)"
            try await Task.sleep(for: .milliseconds(500))
        }
        guard hub != nil else { throw CancellationError() }
    }

    /// The rig keys the memory on its own; there's no "done" readback. Done
    /// means: most of the expected keying time has passed and PTT has read
    /// off for a second (one spurious 0 mid-message was seen, so a single
    /// 0 isn't trusted). Capped, in case PTT never shows TX at all.
    private func waitUntilKeyed(startedAt: Date, expected: TimeInterval) async throws {
        while true {
            try await Task.sleep(for: .milliseconds(250))
            guard let hub else { throw CancellationError() }
            let elapsed = Date().timeIntervalSince(startedAt)
            let pttOn = hub.rigState.ptt
            if elapsed >= expected * 0.9, !pttOn, Date().timeIntervalSince(lastPTTOnAt) >= 1 {
                if lastPTTOnAt < startedAt {
                    Self.logger.notice("no TX seen while the keyer memory played (break-in off?)")
                }
                return
            }
            if elapsed > expected * 1.5 + 5 {
                Self.logger.notice("keying still not finished after \(elapsed, format: .fixed(precision: 1)) s (expected \(expected, format: .fixed(precision: 1)) s); moving on")
                return
            }
        }
    }
}

// MARK: - Items

struct CWSendItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case sending
        case sent
        case stopped
        case failed(String)
    }

    let id = UUID()
    /// What will be keyed, after `CWText.prepare`.
    let text: String
    let chunks: [String]
    /// Characters left out because the keyer can't send them.
    let dropped: String
    var sentChunks = 0
    var state = State.queued

    var isWaiting: Bool { state == .queued || state == .sending }
}

enum CWSendBlock: Equatable {
    case notConnected
    case transmitDisabled
    case notCW(RigMode)
    case outsideBand
    case breakInOff

    var message: String {
        switch self {
        case .notConnected: "the rig isn't connected"
        case .transmitDisabled: "transmit is turned off (Settings → rigctld → Enable Transmit)"
        case .notCW(let mode): "the rig is in \(mode.displayName), not CW"
        case .outsideBand: "the rig is outside the amateur bands"
        case .breakInOff: "break-in is off — the rig only keys its memory with BK-IN on"
        }
    }
}

enum CWSendError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let reason): "Not sent: \(reason)"
        }
    }
}

// MARK: - Text

/// Turning typed text into what the FTX-1's keyer memory takes.
enum CWText {
    /// Every character here was keyed correctly by the rig (2026-10-02).
    /// ";" can never be allowed: it ends the CAT command.
    static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /?,.=+-()@:")

    /// Prosigns in angle brackets, sent as the punctuation the keyer keys
    /// for them. Others (e.g. <SK>) have no single character the keyer is
    /// known to take, so their letters are sent as a word.
    static let prosigns: [String: String] = ["<BT>": "=", "<AR>": "+", "<KN>": "("]

    static let memoryLength = 50

    /// Uppercased, prosigns mapped, other characters dropped, whitespace
    /// collapsed. `dropped` lists what was removed, for the pane to show.
    static func prepare(_ line: String) -> (text: String, dropped: String) {
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
    static func chunks(_ text: String) -> [String] {
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
    static func duration(of text: String, wpm: Int) -> TimeInterval {
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

struct CWMacro: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var text: String

    enum Problem: Error {
        case missing(String)

        var message: String {
            switch self {
            case .missing(let what): "\(what) is empty"
            }
        }
    }

    /// `{MYCALL}`/`{MYGRID}` from Settings → Station, `{CALL}` from the
    /// pane's Their call field.
    func expanded(myCall: String, myGrid: String, theirCall: String) -> Result<String, Problem> {
        let values: [(String, String, String)] = [
            ("{MYCALL}", myCall, "Your callsign (Settings → Station)"),
            ("{MYGRID}", myGrid, "Your grid square (Settings → Station)"),
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

    static let defaults: [CWMacro] = [
        CWMacro(label: "CQ", text: "CQ CQ CQ DE {MYCALL} {MYCALL} K"),
        CWMacro(label: "Answer", text: "{CALL} DE {MYCALL} {MYCALL} K"),
        CWMacro(label: "Report", text: "{CALL} DE {MYCALL} TNX FER CALL <BT> UR RST 599 599 <BT> BK"),
        CWMacro(label: "73", text: "{CALL} DE {MYCALL} TNX FER QSO 73 E E"),
        CWMacro(label: "QRZ?", text: "QRZ? DE {MYCALL} K"),
        CWMacro(label: "AGN?", text: "AGN? AGN?"),
    ]

    private static let defaultsKey = "cw.macros"

    static func load() -> [CWMacro] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let macros = try? JSONDecoder().decode([CWMacro].self, from: data) else { return defaults }
        return macros
    }

    static func save(_ macros: [CWMacro]) {
        if let data = try? JSONEncoder().encode(macros) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

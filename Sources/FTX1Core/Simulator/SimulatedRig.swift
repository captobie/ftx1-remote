import Foundation

/// The Demo Mode rig: an FTX-1 as rigctld (`-m 1051 -o`) presents it, for
/// `SimulatedRigctldServer` to serve on loopback so the app's real
/// `RigctldClient`/`CommandQueue`/poll code runs against it unchanged.
///
/// Reply shapes follow what the app sends and parses (`RigctldClient`,
/// `MemoryChannelEntry`, `RadioInformation`, `FilterStateReads`, the MENU
/// reads) and what was probed on the real rig, not other Yaesu rigs:
///  - hamlib verbs with a VFO argument (`f currVFO`, `F Sub 145500000`,
///    `l currVFO STRENGTH`), answered with `\n`-terminated lines; sets
///    answer "RPRT 0".
///  - raw CAT reads `W <cmd>; ;` answer the CAT reply up to its ";" plus
///    rigctld's `\0` (see `RigctldClient.sendRawCommand`); unknown or
///    unanswerable ones "?;".
///  - raw CAT sets `W <cmd>; 0` answer a bare `\0`, applied or not.
///  - `w KM<n><text>;` (the keyer-memory write, `RigctldClient.
///    writeKeyerMemory`) answers nothing after a pause when accepted, "?;"
///    at once when not.
///
/// Rig behaviour mirrored from CLAUDE.md: "VS" and "FT" are one setting and
/// `currVFO` follows it; "SV" swaps the two sides' contents while each
/// receiver's L/R audio stays put (`audioSwapped`) — except in single-
/// receive display; "VM000" leaves MAIN parked on the channel's values;
/// a memory scan moves VS/FT to the scanning side, any stop stops both
/// sides, "RI0" P7 is the whole radio's scan state, "SC;" reads back the
/// last scan command; the keyer only transmits with BK-IN on, a second
/// "KY0n" restarts and "KY00" stops at once.
///
/// Thread-safe (one lock): the rigctld server's connections, the audio
/// server and tests all call in. Time comes from `clock` (seconds,
/// monotonic) so tests can drive it.
public final class SimulatedRig: @unchecked Sendable {
    /// What to write back for one request line, and how long to wait first.
    public struct Reply: Equatable, Sendable {
        public var bytes: [UInt8]
        public var delay: TimeInterval

        init(_ text: String, delay: TimeInterval = 0) {
            bytes = Array(text.utf8)
            self.delay = delay
        }

        static let rawEmpty = Reply("\0")
        static func raw(_ answer: String) -> Reply { Reply(answer + "\0") }
        static func lines(_ lines: String...) -> Reply { Reply(lines.map { $0 + "\n" }.joined()) }
        static let ok = lines("RPRT 0")
    }

    struct Channel: Equatable {
        var hz: Int
        var modeCode: Character
        var toneMode: Int
        var shift: Int
        var tag: String
    }

    struct Receiver {
        var vfoHz: Int
        var vfoMode: Character
        var memory: Bool
        var channel: Int
    }

    /// One receiver as the audio synthesizer needs it.
    public struct ReceiverAudio: Equatable, Sendable {
        public var hz: Int
        /// The "MD" P2 code.
        public var modeCode: Character
        public var cwPitchHz: Int
        /// False in single-receive display for SUB's receiver.
        public var receiving: Bool
    }

    /// Both physical receivers — L and R of the USB audio — plus TX.
    public struct AudioSnapshot: Equatable, Sendable {
        public var elapsed: TimeInterval
        public var left: ReceiverAudio
        public var right: ReceiverAudio
        public var transmitting: Bool
    }

    let world = SimulatedWorld()
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let startTime: TimeInterval

    /// [0] MAIN, [1] SUB — the sides as the rig names them now.
    private var receivers: [Receiver]
    private var channels: [Int: Channel]
    /// "VS"/"FT": 0 MAIN, 1 SUB. Also what `currVFO` means.
    private var activeSide = 0
    /// Whether L carries SUB's signal: each "SV" in dual receive flips it.
    private var audioSwapped = false
    /// Fixed-width raw settings: the reply's value after the prefix.
    private var registers: [String: String]
    /// "SH<side>" per side and mode code: the rig remembers widths per mode.
    private var widths: [String: String] = [:]
    /// "EX" items by "P1P2P3" (6 digits).
    private var menu: [String: String]
    private var keyerMemories: [Int: String] = [
        1: "CQ CQ DE DEMO DEMO K",
        2: "TU 5NN BK",
        3: "QRZ? DE DEMO",
        4: "73 DE DEMO SK",
        5: "",
    ]
    /// hamlib RFPOWER, 0...1 of 100 W (the real FTX-1 answers 0.05 at 5 W,
    /// which the MENU grid shows as "5W"). 5 W, as on the user's rig.
    private var rfPower = 0.05
    private var ptt = false
    private var keyerUntil: TimeInterval?
    private var tuneUntil: TimeInterval?
    private var txAudioLevel = 0.0
    private var txAudioAt: TimeInterval = -1

    // Memory scan.
    private var scanSide: Int?
    private var scanDirection = 1
    private var scanState = MemoryScanState.stopped
    private var lastScanStep: TimeInterval = 0
    private var quietSince: TimeInterval?
    /// "SC;" reads back the last scan command's P1/P2.
    private var lastScanCommand = "00"

    public init(clock: (@Sendable () -> TimeInterval)? = nil) {
        let clock = clock ?? { ProcessInfo.processInfo.systemUptime }
        self.clock = clock
        startTime = clock()
        channels = Self.sampleChannels
        // MAIN on the CW beacon, SUB on the APRS frequency: something to
        // hear and decode on both from the start.
        receivers = [
            Receiver(vfoHz: SimulatedWorld.beaconHz, vfoMode: "3", memory: false, channel: 9),
            Receiver(vfoHz: SimulatedWorld.aprsHz, vfoMode: "4", memory: false, channel: 4),
        ]
        registers = Self.defaultRegisters
        menu = Self.defaultMenu()
    }

    /// Seconds since this rig was made — the world's time base.
    public var elapsed: TimeInterval { clock() - startTime }

    // MARK: - Sample memory channels

    /// Local-repeater-style 2 m/70 cm, the APRS frequency, a few HF.
    static let sampleChannels: [Int: Channel] = [
        1: Channel(hz: 146_520_000, modeCode: "4", toneMode: 0, shift: 0, tag: "2M CALL"),
        2: Channel(hz: 146_940_000, modeCode: "4", toneMode: 2, shift: 2, tag: "DEMO RPT"),
        3: Channel(hz: 147_330_000, modeCode: "4", toneMode: 2, shift: 1, tag: "RPT 147.33"),
        4: Channel(hz: 144_390_000, modeCode: "4", toneMode: 0, shift: 0, tag: "APRS"),
        5: Channel(hz: 446_000_000, modeCode: "4", toneMode: 0, shift: 0, tag: "70CM CALL"),
        6: Channel(hz: 442_100_000, modeCode: "4", toneMode: 1, shift: 1, tag: "UHF RPT"),
        7: Channel(hz: 445_925_000, modeCode: "H", toneMode: 0, shift: 0, tag: "C4FM SIMPLX"),
        8: Channel(hz: 162_550_000, modeCode: "4", toneMode: 0, shift: 0, tag: "NOAA WX"),
        9: Channel(hz: 14_047_500, modeCode: "3", toneMode: 0, shift: 0, tag: "CW BEACON"),
        10: Channel(hz: 14_074_000, modeCode: "C", toneMode: 0, shift: 0, tag: "FT8 20M"),
        11: Channel(hz: 7_074_000, modeCode: "C", toneMode: 0, shift: 0, tag: "FT8 40M"),
        12: Channel(hz: 7_200_000, modeCode: "1", toneMode: 0, shift: 0, tag: "40M SSB"),
        13: Channel(hz: 3_885_000, modeCode: "5", toneMode: 0, shift: 0, tag: "75M AM"),
        14: Channel(hz: 28_400_000, modeCode: "2", toneMode: 0, shift: 0, tag: "10M SSB"),
        15: Channel(hz: 50_125_000, modeCode: "2", toneMode: 0, shift: 0, tag: "6M CALL"),
    ]

    // MARK: - Defaults

    /// Every fixed-width raw setting the app reads or writes that isn't
    /// special-cased below, by its full prefix (P1 baked in where the app
    /// bakes it). The value's length is the field width a set must match.
    static let defaultRegisters: [String: String] = [
        "BI": "1", "KR": "1", "KS": "020", "KP": "40", "SD": "05", "CS": "0",
        "ML0": "0", "ML1": "050", "RA0": "0", "PA0": "0", "AC": "100",
        "DA": "00101010", "SS01": "20000", "SS02": "10000", "SS04": "+00.0",
        "MG": "050", "AO": "050", "VX": "0", "VG": "050", "VD": "05", "BC0": "0",
        "GT0": "2", "PR1": "0", "PL": "050", "NL0": "005", "RL0": "05",
        "CT0": "0", "CN00": "008", "CN01": "000", "OS0": "0", "TS": "0",
        "ST": "0", "FR": "00", "MX": "0", "LM0": "1", "LM1": "0",
        // Filters, per side (the width is per mode, in `widths`).
        "IS0": "0+0000", "IS1": "0+0000",
        "BP00": "000", "BP01": String(format: "%03d", IFNotch.code(forHz: 1500)),
        "BP10": "000", "BP11": String(format: "%03d", IFNotch.code(forHz: 1500)),
        "CO00": "0000", "CO01": "1000", "CO02": "0000", "CO03": String(format: "%04d", IFContour.apfCode(forHz: 0)),
        "CO10": "0000", "CO11": "1000", "CO12": "0000", "CO13": String(format: "%04d", IFContour.apfCode(forHz: 0)),
        "NA0": "0", "NA1": "0",
    ]

    /// The Deep Settings catalog's items at a plausible value each, plus
    /// the CW TEXT memories (02 02 06-10 = 0 TEXT).
    static func defaultMenu() -> [String: String] {
        var menu: [String: String] = [:]
        for item in DeepSettingsCatalog.items {
            let key = String(format: "%02d%02d%02d", item.p1, item.p2, item.p3)
            switch item.valueType {
            case .toggle:
                menu[key] = "0"
            case .enumeration(let cases, let digits):
                var index = cases.first?.index ?? 0
                if item.label == "NAR WIDTH" {
                    let wanted = item.tab == "MODE CW" ? "500" : "1800"
                    index = cases.first { $0.label.hasPrefix(wanted) }?.index ?? index
                }
                menu[key] = String(format: "%0\(digits)d", index)
            case .intRange(let range, let digits, _, let step):
                let middle = range.lowerBound + (range.upperBound - range.lowerBound) / 2
                let snapped = range.lowerBound + (middle - range.lowerBound) / max(step, 1) * max(step, 1)
                menu[key] = String(format: "%0\(digits)d", snapped)
            case .signedRange(let range, let digits, _, _):
                let value = range.contains(0) ? 0 : range.lowerBound
                menu[key] = (value < 0 ? "-" : "+") + String(format: "%0\(digits)d", abs(value))
            case .text(let maxLength):
                menu[key] = String("DEMO".prefix(maxLength))
            case .readOnly, .action:
                break
            }
        }
        for slot in 1...5 { menu[String(format: "0202%02d", 5 + slot)] = "0" }
        return menu
    }

    /// The rig's per-mode default width index ("SH" P2+P3).
    private static func defaultWidth(modeCode: Character) -> String {
        switch modeCode {
        case "1", "2": "013"          // 2400 Hz
        case "3", "7", "6", "9": "010" // 500 Hz
        case "8", "C", "E": "017"     // 2400 Hz
        case "5", "D": "002"          // 9000 Hz
        default: "003"                // FM 16000 Hz
        }
    }

    // MARK: - Requests

    /// Answers one request line (without its "\n"); nil for a blank line.
    public func handle(_ line: String) -> Reply? {
        lock.lock()
        defer { lock.unlock() }
        let now = elapsedLocked()
        advanceScan(to: now)
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        if line.hasPrefix("W ") {
            let rest = line.dropFirst(2)
            guard let semicolon = rest.firstIndex(of: ";") else { return .raw("?;") }
            let body = String(rest[rest.startIndex..<semicolon])
            let expectsNothing = rest[rest.index(after: semicolon)...].trimmingCharacters(in: .whitespaces) == "0"
            if expectsNothing {
                // Applied or refused, rigctld answers the same empty reply.
                _ = applySet(body, now: now)
                return .rawEmpty
            }
            if let answer = answer(body, now: now) { return .raw(answer) }
            // A set sent as a read: the rig takes it and says nothing.
            return applySet(body, now: now) ? .rawEmpty : .raw("?;")
        }
        if line.hasPrefix("w ") {
            return keyerWrite(String(line.dropFirst(2)))
        }
        if line.hasPrefix("\\") {
            return extended(line)
        }
        return hamlib(line.split(separator: " ").map(String.init), now: now)
    }

    /// The TX audio server's level report: RMS of the last chunk (0...1).
    public func reportTXAudio(rms: Double) {
        lock.lock()
        defer { lock.unlock() }
        txAudioLevel = rms
        txAudioAt = elapsedLocked()
    }

    /// The two receivers' audio inputs at `elapsed` — L/R as the USB audio
    /// carries them (each receiver's own signal, whichever side it is now).
    public func audioSnapshot() -> AudioSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = elapsedLocked()
        advanceScan(to: now)
        let pitch = cwPitchHz
        let single = registers["FR"] == "01"
        let main = ReceiverAudio(hz: effective(0).hz, modeCode: effective(0).mode, cwPitchHz: pitch, receiving: true)
        let sub = ReceiverAudio(hz: effective(1).hz, modeCode: effective(1).mode, cwPitchHz: pitch, receiving: !single)
        return AudioSnapshot(
            elapsed: now,
            left: audioSwapped ? sub : main,
            right: audioSwapped ? main : sub,
            transmitting: isTransmitting(now)
        )
    }

    private func elapsedLocked() -> TimeInterval { clock() - startTime }

    private var cwPitchHz: Int { 300 + (Int(registers["KP"] ?? "40") ?? 40) * 10 }

    private func effective(_ side: Int) -> (hz: Int, mode: Character) {
        let receiver = receivers[side]
        if receiver.memory, let channel = channels[receiver.channel] {
            return (channel.hz, channel.modeCode)
        }
        return (receiver.vfoHz, receiver.vfoMode)
    }

    private func side(named name: String) -> Int {
        switch name {
        case "Main", "VFOA", "MainA": 0
        case "Sub", "VFOB", "SubA": 1
        default: activeSide
        }
    }

    // MARK: Hamlib verbs

    private func hamlib(_ words: [String], now: TimeInterval) -> Reply {
        guard let verb = words.first else { return .lines("RPRT -1") }
        let vfo = words.count > 1 ? side(named: words[1]) : activeSide
        switch verb {
        case "f":
            return .lines(String(effective(vfo).hz))
        case "F":
            guard words.count >= 3, let hz = Int(words[2]) else { return .lines("RPRT -1") }
            // Like "FA": refused while that side is on a memory channel.
            guard !receivers[vfo].memory else { return .lines("RPRT -9") }
            receivers[vfo].vfoHz = hz
            return .ok
        case "m":
            let code = effective(vfo).mode
            guard let name = Self.hamlibModeName(code) else { return .lines("RPRT -8") }
            let width = widthHz(side: vfo, modeCode: code)
            return .lines(name, String(width))
        case "M":
            guard words.count >= 3, let code = RigMode(rawValue: words[2])?.catModeCode else { return .lines("RPRT -1") }
            setMode(code, side: vfo)
            return .ok
        case "t":
            return .lines(String(pttValue(now)))
        case "T":
            guard words.count >= 3, let value = Int(words[2]) else { return .lines("RPRT -1") }
            ptt = value != 0
            return .ok
        case "l":
            guard words.count >= 3 else { return .lines("RPRT -1") }
            return level(words[2], side: vfo, now: now)
        case "L":
            guard words.count >= 4, words[2] == "RFPOWER", let value = Double(words[3]) else { return .lines("RPRT -11") }
            rfPower = min(max(value, RigState.minimumPowerLevel), 1)
            return .ok
        case "v":
            return .lines(activeSide == 0 ? "Main" : "Sub")
        case "V":
            activeSide = vfo
            registers["FT"] = String(vfo)
            return .ok
        case "q", "Q":
            return Reply("")
        default:
            return .lines("RPRT -11")
        }
    }

    private func extended(_ line: String) -> Reply {
        if line.hasPrefix("\\dump_caps") {
            return .lines(
                "Caps dump for model: 1051",
                "Model name:\tFTX-1",
                "Mfg name:\tYaesu",
                "Hamlib version:\tHamlib 4.7.2 (FTX1Remote Demo Mode simulator)",
                "Backend version:\tdemo",
                "Backend status:\tStable",
                "RPRT 0"
            )
        }
        if line.hasPrefix("\\chk_vfo") { return .lines("1") }
        return .lines("RPRT -11")
    }

    private func level(_ name: String, side: Int, now: TimeInterval) -> Reply {
        switch name {
        case "STRENGTH":
            return .lines(String(Int(strengthDb(side: side, now: now).rounded())))
        case "RFPOWER":
            return .lines(String(format: "%.6f", rfPower))
        case "SWR":
            return .lines(String(format: "%.6f", isTransmitting(now) ? swr : 1.0))
        case "RFPOWER_METER_WATTS":
            return .lines(String(format: "%.6f", outputWatts(now)))
        case "ALC", "COMP":
            return .lines("0.000000")
        default:
            return .lines("RPRT -11")
        }
    }

    static func hamlibModeName(_ code: Character) -> String? {
        if let mode = RigMode(catModeCode: code), mode != .c4fm { return mode.rawValue }
        switch code {
        case "7": return "CWR"
        case "8": return "PKTLSB"
        case "9": return "RTTYR"
        case "B": return "FMN"
        case "D": return "AMN"
        default: return nil
        }
    }

    // MARK: Raw CAT reads

    private func answer(_ body: String, now: TimeInterval) -> String? {
        switch body {
        case "FA": return "FA" + String(format: "%09d", effective(0).hz) + ";"
        case "FB": return "FB" + String(format: "%09d", effective(1).hz) + ";"
        case "MD0": return "MD0\(effective(0).mode);"
        case "MD1": return "MD1\(effective(1).mode);"
        case "FT", "VS": return "\(body)\(activeSide);"
        case "SC": return "SC\(lastScanCommand);"
        case "RI0":
            let tx = isTransmitting(now) ? 1 : 0
            let scan: Int = switch scanState {
            case .stopped: 0
            case .scanning: 1
            case .paused: 2
            }
            let squelch = reception(side: 0, now: now).busy ? 1 : 0
            return "RI00\(0)\(tx)00\(scan)\(squelch);"
        case "VM0", "VM1":
            let side = body == "VM0" ? 0 : 1
            return body + (receivers[side].memory ? "11" : "00") + ";"
        case "MC0", "MC1":
            let side = body == "MC0" ? 0 : 1
            return body + String(format: "%05d", receivers[side].channel) + ";"
        case "TX": return "TX\(isTransmitting(now) ? 1 : 0);"
        case "SH0", "SH1":
            let side = body == "SH0" ? 0 : 1
            return body + width(side: side) + ";"
        default:
            break
        }
        if body.hasPrefix("MR"), body.count == 7, let number = Int(body.dropFirst(2)) {
            guard let channel = channels[number] else { return "?;" }
            return "MR" + String(format: "%05d%09d", number, channel.hz) + "+00000" + "0" + "\(channel.modeCode)" + "1" + "\(channel.toneMode)" + "00" + "\(channel.shift)" + ";"
        }
        if body.hasPrefix("MT"), body.count == 7, let number = Int(body.dropFirst(2)) {
            guard let channel = channels[number] else { return "?;" }
            return body + channel.tag.padding(toLength: 12, withPad: " ", startingAt: 0) + ";"
        }
        if body.hasPrefix("KM"), body.count == 3, let slot = Int(body.dropFirst(2)), let text = keyerMemories[slot] {
            return body + text + "};"
        }
        if body.hasPrefix("RM"), body.count == 3, let meter = Int(body.dropFirst(2)) {
            return body + String(format: "%03d", meterRaw(meter, now: now)) + "000;"
        }
        if body.hasPrefix("EX"), body.count == 8 {
            guard let value = menu[String(body.dropFirst(2))] else { return "?;" }
            return body + value + ";"
        }
        if let value = registers[body] {
            return body + value + ";"
        }
        return nil
    }

    // MARK: Raw CAT sets

    /// False when the rig wouldn't take `body` (it answers "?;").
    private func applySet(_ body: String, now: TimeInterval) -> Bool {
        func digits(after prefix: String) -> Int? {
            body.hasPrefix(prefix) ? Int(body.dropFirst(prefix.count)) : nil
        }
        if body == "SV" {
            swap(now: now)
            return true
        }
        if body.count == 11, body.hasPrefix("FA") || body.hasPrefix("FB"), let hz = Int(body.dropFirst(2)) {
            let side = body.hasPrefix("FA") ? 0 : 1
            if !receivers[side].memory { receivers[side].vfoHz = hz }
            return true
        }
        if body.count == 4, body.hasPrefix("MD0") || body.hasPrefix("MD1"), let code = body.last {
            setMode(code, side: body.hasPrefix("MD0") ? 0 : 1)
            return true
        }
        if body.count == 3, body.hasPrefix("FT") || body.hasPrefix("VS"), let side = Int(body.dropFirst(2)), (0...1).contains(side) {
            activeSide = side
            return true
        }
        if body.count == 4, body.hasPrefix("SC"), let side = Int(String(body.dropFirst(2).prefix(1))), let direction = Int(body.dropFirst(3)) {
            setScan(side: side, direction: direction, now: now)
            return true
        }
        if body.count == 5, body.hasPrefix("VM0") || body.hasPrefix("VM1"), let value = Int(body.dropFirst(3)) {
            setMemoryMode(value == 11, side: body.hasPrefix("VM0") ? 0 : 1)
            return true
        }
        if body.count == 8, body.hasPrefix("MC0") || body.hasPrefix("MC1"), let number = Int(body.dropFirst(3)) {
            // The rig ignores a blank channel.
            if channels[number] != nil { receivers[body.hasPrefix("MC0") ? 0 : 1].channel = number }
            return true
        }
        if body == "CH0" || body == "CH1" {
            // No side selector: follows VS, like `currVFO`.
            receivers[activeSide].channel = nextChannel(after: receivers[activeSide].channel, up: body == "CH0")
            return true
        }
        if body.hasPrefix("KY0"), let slot = digits(after: "KY0") {
            playKeyer(slot: slot, now: now)
            return true
        }
        if body.count == 6, body.hasPrefix("SH0") || body.hasPrefix("SH1") {
            let side = body.hasPrefix("SH0") ? 0 : 1
            widths[widthKey(side: side)] = String(body.dropFirst(3))
            return true
        }
        if body.count == 4, body.hasPrefix("NA0") || body.hasPrefix("NA1") {
            setNarrow(body.last == "1", side: body.hasPrefix("NA0") ? 0 : 1)
            return true
        }
        if body == "AC103" {
            // Tuner start: a short carrier, then the tuner on.
            tuneUntil = now + 2.5
            registers["AC"] = "101"
            return true
        }
        if body.hasPrefix("EX"), body.count > 8 {
            let key = String(body.dropFirst(2).prefix(6))
            if menu[key] != nil { menu[key] = String(body.dropFirst(8)) }
            return true
        }
        if body.hasPrefix("ZI") { return true }
        // A fixed-width register: the longest prefix whose width fits.
        let match = registers.keys
            .filter { body.hasPrefix($0) && body.count == $0.count + (registers[$0]?.count ?? 0) }
            .max { $0.count < $1.count }
        guard let match else { return false }
        registers[match] = String(body.dropFirst(match.count))
        return true
    }

    private func setMode(_ code: Character, side: Int) {
        // In Memory mode the channel's mode stands.
        guard !receivers[side].memory else { return }
        receivers[side].vfoMode = code
    }

    private func setMemoryMode(_ memory: Bool, side: Int) {
        guard memory != receivers[side].memory else { return }
        if memory {
            if channels[receivers[side].channel] == nil, let first = channels.keys.min() {
                receivers[side].channel = first
            }
        } else if let channel = channels[receivers[side].channel] {
            // Driven over CAT, "VM000" leaves the side parked on the
            // channel's values (the app replays its VFO afterwards).
            receivers[side].vfoHz = channel.hz
            receivers[side].vfoMode = channel.modeCode
        }
        receivers[side].memory = memory
    }

    private func swap(now: TimeInterval) {
        receivers.swapAt(0, 1)
        // The audio stays with the physical receiver; in single-receive
        // display "SV" doesn't move it.
        if registers["FR"] != "01" { audioSwapped.toggle() }
    }

    private func setNarrow(_ on: Bool, side: Int) {
        registers["NA\(side)"] = on ? "1" : "0"
        // In AM/FM "SH" follows NARROW (`FilterWidthTable`).
        switch effective(side).mode {
        case "4", "A", "B", "F": widths[widthKey(side: side)] = on ? "002" : "003"
        case "5", "D": widths[widthKey(side: side)] = on ? "001" : "002"
        default: break
        }
    }

    private func widthKey(side: Int) -> String { "\(side)\(effective(side).mode)" }

    private func width(side: Int) -> String {
        widths[widthKey(side: side)] ?? Self.defaultWidth(modeCode: effective(side).mode)
    }

    private func widthHz(side: Int, modeCode: Character) -> Int {
        guard let mode = RigMode(catModeCode: modeCode), let index = Int(width(side: side)) else { return 2400 }
        return FilterWidthTable.hz(forIndex: index, mode: mode) ?? 2400
    }

    private func nextChannel(after current: Int, up: Bool) -> Int {
        let numbers = channels.keys.sorted()
        guard !numbers.isEmpty else { return current }
        if up {
            return numbers.first { $0 > current } ?? numbers[0]
        }
        return numbers.last { $0 < current } ?? numbers[numbers.count - 1]
    }

    // MARK: Keyer memory

    private func keyerWrite(_ line: String) -> Reply {
        var body = line
        if body.hasSuffix(";") { body.removeLast() }
        guard body.hasPrefix("KM"), body.count >= 3, let slot = Int(String(body.dropFirst(2).prefix(1))), (1...5).contains(slot) else {
            return .raw("?;")
        }
        let text = String(body.dropFirst(3))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/?,.=+-()@: ")
        guard text.count <= 50, text.allSatisfy({ allowed.contains($0) }) else { return .raw("?;") }
        keyerMemories[slot] = text
        // An accepted write gets no reply; rigctld waits out its timeout
        // (~2 s on the Pi) before the next command. Shorter here.
        return Reply("", delay: 0.4)
    }

    private func playKeyer(slot: Int, now: TimeInterval) {
        guard slot != 0 else {
            keyerUntil = nil
            return
        }
        guard let text = keyerMemories[slot], !text.isEmpty else { return }
        // Only with BK-IN on, and only in CW on the TX side.
        guard registers["BI"] == "1", "37".contains(effective(activeSide).mode) else { return }
        let wpm = Int(registers["KS"] ?? "20") ?? 20
        keyerUntil = now + SimulatedMorse.duration(of: text, wpm: wpm)
    }

    // MARK: Memory scan

    private func setScan(side: Int, direction: Int, now: TimeInterval) {
        lastScanCommand = "\(side)\(direction)"
        guard direction != 0 else {
            // Any stop stops both sides.
            scanState = .stopped
            scanSide = nil
            return
        }
        guard (0...1).contains(side), receivers[side].memory else { return }
        if scanSide == side, scanState == .paused {
            // A Skip: past the busy channel and on.
            receivers[side].channel = nextChannel(after: receivers[side].channel, up: scanDirection == 1)
        }
        scanSide = side
        scanDirection = direction
        scanState = .scanning
        lastScanStep = now
        quietSince = nil
        // The scan moves VS/FT to the scanning side.
        activeSide = side
    }

    /// Steps the scan to `now`: ~10 channels a second, pausing on a busy
    /// channel and resuming (SCAN RESUME: BUSY) a second after it clears.
    private func advanceScan(to now: TimeInterval) {
        guard let side = scanSide else { return }
        let step = 0.1
        switch scanState {
        case .stopped:
            return
        case .paused:
            let channel = channels[receivers[side].channel]
            let busy = channel.map { world.reception(hz: $0.hz, modeCode: $0.modeCode, at: now).busy } ?? false
            if busy {
                quietSince = nil
            } else if let quietSince {
                if now - quietSince >= 1 {
                    scanState = .scanning
                    lastScanStep = now
                    self.quietSince = nil
                }
            } else {
                quietSince = now
            }
        case .scanning:
            while lastScanStep + step <= now {
                lastScanStep += step
                let next = nextChannel(after: receivers[side].channel, up: scanDirection == 1)
                receivers[side].channel = next
                if let channel = channels[next], world.reception(hz: channel.hz, modeCode: channel.modeCode, at: lastScanStep).busy {
                    scanState = .paused
                    quietSince = nil
                    return
                }
            }
        }
    }

    // MARK: Meters and TX

    private func isTransmitting(_ now: TimeInterval) -> Bool {
        ptt || registers["MX"] == "1" || (keyerUntil.map { now < $0 } ?? false) || (tuneUntil.map { now < $0 } ?? false)
    }

    /// hamlib's PTT: 1 keyed over CAT (and MOX, tune), 3 while the keyer
    /// sends — what the rig reports for its TX2 state.
    private func pttValue(_ now: TimeInterval) -> Int {
        if ptt || registers["MX"] == "1" || (tuneUntil.map { now < $0 } ?? false) { return 1 }
        if let keyerUntil, now < keyerUntil { return 3 }
        return 0
    }

    private func reception(side: Int, now: TimeInterval) -> SimulatedReception {
        let (hz, mode) = effective(side)
        return world.reception(hz: hz, modeCode: mode, at: now)
    }

    private func strengthDb(side: Int, now: TimeInterval) -> Double {
        if isTransmitting(now) && side == activeSide { return -54 }
        if side == 1, registers["FR"] == "01" { return -54 }
        let base = reception(side: side, now: now).strengthDb
        // A little movement on a live signal or band noise; exactly S0 on a
        // quiet V/UHF channel, as the rig reports it.
        guard base > -54 else { return -54 }
        return base + 1.5 * sin(now * 1.7 + Double(side))
    }

    /// Antenna SWR by band — plausible, not measured.
    private var swr: Double {
        let hz = effective(activeSide).hz
        switch hz {
        case ..<4_000_000: return 1.6
        case ..<8_000_000: return 1.4
        case ..<30_000_000: return 1.25
        default: return 1.15
        }
    }

    /// RF out: the power setting (RFPOWER × 100 W, as the real rig reports
    /// it) while keyed; in SSB it follows the TX audio level, as speech
    /// would.
    private func outputWatts(_ now: TimeInterval) -> Double {
        guard isTransmitting(now) else { return 0 }
        let full = rfPower * 100
        switch effective(activeSide).mode {
        case "1", "2", "8", "C", "5", "D":
            guard ptt || registers["MX"] == "1" else { return full }
            let level = now - txAudioAt < 0.5 ? txAudioLevel : 0
            return full * min(1, 0.05 + level * 6)
        default:
            return full
        }
    }

    private func meterRaw(_ meter: Int, now: TimeInterval) -> Int {
        let transmitting = isTransmitting(now)
        switch meter {
        case 1: return Self.raw(forStrengthDb: strengthDb(side: 0, now: now))
        case 2: return Self.raw(forStrengthDb: strengthDb(side: 1, now: now))
        case 3: return transmitting ? 40 : 0
        case 4: return transmitting ? 60 : 0
        case 5: return min(255, Int(outputWatts(now) / 10 * 255))
        case 6: return transmitting ? Int((swr - 1) * 64) : 0
        case 7: return transmitting ? min(255, Int(30 + outputWatts(now) * 14)) : 18
        case 8: return 190
        default: return 0
        }
    }

    /// Inverse of `SMeterScale.strengthDb(forRaw:)` (same anchors).
    static func raw(forStrengthDb db: Double) -> Int {
        let anchors: [(raw: Double, db: Double)] = [
            (0, -54), (12, -48), (27, -42), (40, -36), (55, -30), (65, -24),
            (80, -18), (95, -12), (112, -6), (130, 0), (150, 10), (172, 20),
            (190, 30), (220, 40), (240, 50), (255, 60),
        ]
        guard db > anchors[0].db else { return 0 }
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where db <= upper.db {
            let fraction = (db - lower.db) / (upper.db - lower.db)
            return Int((lower.raw + fraction * (upper.raw - lower.raw)).rounded())
        }
        return 255
    }
}

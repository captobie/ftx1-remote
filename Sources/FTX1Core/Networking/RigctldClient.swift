import Foundation
import Network

/// Talks to rigctld over its plain-text TCP protocol on localhost:4532.
///
/// This is only ever instantiated by the Mac hub app — mobile apps go
/// through `RigWebSocketClient` instead and never see this type in practice
/// (it lives here rather than in a Mac-only target so the Mac app doesn't
/// need a second local package just for this one file).
public actor RigctldClient {
    private var connection: NWConnection?
    private var readBuffer = Data()
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port

    /// Guards every write+read round trip so two of them can never
    /// interleave on the wire. Actor isolation alone doesn't provide this:
    /// `write()`/`readLine()` each suspend at an `await`, and at every
    /// suspension point the actor is free to start running a *different*
    /// queued caller. `HubService`'s poll loop calls this client's get
    /// methods directly (not through `CommandQueue`), so without this lock
    /// a command from `CommandQueue` (e.g. a button's set command) could
    /// write its own request in the middle of a poll-loop request that's
    /// still waiting on its reply — and since both share one `readBuffer`,
    /// either call's `readLine()` can end up consuming the *other* call's
    /// reply. That surfaced as: set commands reaching the radio fine (the
    /// write itself doesn't need the lock to "work"), but get commands
    /// intermittently reading back garbage that fails to parse, making
    /// `RigState.breakIn`/`keyerEnabled` look permanently nil.
    private var roundTripBusy = false
    private var roundTripWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireRoundTrip() async {
        if !roundTripBusy {
            roundTripBusy = true
            return
        }
        await withCheckedContinuation { roundTripWaiters.append($0) }
    }

    private func releaseRoundTrip() {
        if roundTripWaiters.isEmpty {
            roundTripBusy = false
        } else {
            roundTripWaiters.removeFirst().resume()
        }
    }

    public init(host: String = "127.0.0.1", port: UInt16 = 4532) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    public func connect(timeout: Duration = .seconds(5)) async throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let conn = NWConnection(host: host, port: port, using: params)
        self.connection = conn
        readBuffer.removeAll()

        let readyGuard = ContinuationGuard()
        // Without the cancellation handler, cancelling the calling Task
        // (e.g. the user switching rigctld off mid-attempt) wouldn't abort
        // this connection attempt — it'd sit here until `timeout` elapses
        // regardless, since the stateUpdateHandler continuation below
        // doesn't check for cancellation on its own.
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        conn.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                readyGuard.resumeOnce(continuation, with: .success(()))
                            case .failed(let error):
                                readyGuard.resumeOnce(continuation, with: .failure(error))
                            case .cancelled:
                                readyGuard.resumeOnce(continuation, with: .failure(RigctldError.notConnected))
                            default:
                                break
                            }
                        }
                        conn.start(queue: .global(qos: .userInitiated))
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw RigctldError.connectTimedOut
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    // Whichever branch threw, explicitly cancel the
                    // connection so the *other* (losing) branch's
                    // stateUpdateHandler fires `.cancelled` and its
                    // continuation actually resumes — group.cancelAll()
                    // alone only marks it cancelled, it doesn't force a
                    // continuation waiting on an NWConnection callback to
                    // resume, which would otherwise hang this whole call
                    // forever (structured concurrency won't let this
                    // closure return until every child task finishes).
                    conn.cancel()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }

    /// Sends a raw rigctld command (e.g. "F 14250000") and returns the
    /// single-line response (e.g. "RPRT 0"). rigctld's protocol is
    /// request/response — `acquireRoundTrip()`/`releaseRoundTrip()` ensure
    /// this write+read pair completes atomically with respect to every
    /// other round trip on this client, regardless of which caller
    /// (CommandQueue, HubService's poll loop, ...) issued it.
    public func send(_ command: String) async throws -> String {
        await acquireRoundTrip()
        defer { releaseRoundTrip() }
        try await write(command)
        return try await readLine()
    }

    /// Sends a command that returns a known fixed number of lines back
    /// (e.g. "m" for get_mode, which replies with mode + passband on
    /// separate lines).
    public func query(_ command: String, lines: Int) async throws -> [String] {
        await acquireRoundTrip()
        defer { releaseRoundTrip() }
        try await write(command)
        var result: [String] = []
        for _ in 0..<lines {
            result.append(try await readLine())
        }
        return result
    }

    /// Like `query(_:lines:)`, but for commands that are only sometimes
    /// reliable (e.g. `getSecondaryMode()` below, which errors consistently
    /// on this rig today but may not on every rig/backend). rigctld's get
    /// commands never prepend "RPRT" on success — only a failure replaces
    /// the whole expected multi-line reply with a single "RPRT -N" line —
    /// so checking for that prefix on the first line tells us not to block
    /// waiting for lines that will never arrive.
    private func queryOrError(_ command: String, lines: Int) async throws -> [String] {
        await acquireRoundTrip()
        defer { releaseRoundTrip() }
        try await write(command)
        var result: [String] = []
        for _ in 0..<lines {
            let line = try await readLine()
            if line.hasPrefix("RPRT") {
                throw RigctldError.badResponse
            }
            result.append(line)
        }
        return result
    }

    /// rigctld is launched with `-o` (see `RigctldProcessController`), which
    /// makes every get/set command require an explicit VFO argument rather
    /// than silently defaulting to (and, if given an argument anyway,
    /// ignoring it in favor of) the currently active VFO. "currVFO" is
    /// rigctld's own keyword for "whichever VFO is active" — passing it
    /// keeps these calls' behavior the same as before -o was added.
    private static let currentVFOArg = "currVFO"

    public func getFrequency() async throws -> Int {
        let line = try await send("f \(Self.currentVFOArg)")
        guard let hz = Int(line) else { throw RigctldError.badResponse }
        return hz
    }

    // `query()` unconditionally reads 2 lines, but a failure reply is only
    // ever 1 line ("RPRT -N") — this rig's hamlib backend returns exactly
    // that for "get mode" while the active VFO is in C4FM. `query()`'s
    // second `readLine()` would then block forever waiting for a line that
    // rigctld will never send, wedging this actor's round-trip lock (see
    // `roundTripBusy` above) and hanging every subsequent call on this
    // client. `queryOrError` (below) exists for exactly this failure shape.
    public func getMode() async throws -> (mode: String, passband: Int) {
        let lines = try await queryOrError("m \(Self.currentVFOArg)", lines: 2)
        guard lines.count == 2, let passband = Int(lines[1]) else {
            throw RigctldError.badResponse
        }
        return (lines[0], passband)
    }

    /// Fallback for `getMode()`'s known gap, not a replacement for it:
    /// this rig's hamlib backend has no mapping for the raw "MD" mode
    /// codes "H"/"I" (C4FM-DN / C4FM-VW per the CAT manual's OPERATING
    /// MODE table) and returns a protocol error instead of any mode
    /// string — confirmed against real hardware (`W MD0; ;` while the
    /// active VFO is in C4FM answers "MD0H;", which `getMode()` can't
    /// parse into anything). Reads the raw CAT mode directly via
    /// passthrough and reports whether it's one of those two codes;
    /// every other code returns nil rather than guessing, since ordinary
    /// modes already come back fine through `getMode()` — this exists
    /// purely to fill the C4FM gap, not to duplicate that path. `v`
    /// determines whether the currently-active VFO is Main or Sub, same
    /// technique as `getSecondaryFrequency()`/`getSecondaryMode()` above.
    public func isActiveModeC4FM() async throws -> Bool {
        let currentVFO = try await send("v")
        return try await isC4FM(p1: currentVFO == "Sub" ? "1" : "0")
    }

    /// Same gap as `isActiveModeC4FM()`, for whichever VFO isn't currently
    /// active — the fallback counterpart to `getSecondaryMode()`.
    public func isSecondaryModeC4FM() async throws -> Bool {
        let currentVFO = try await send("v")
        return try await isC4FM(p1: currentVFO == "Sub" ? "0" : "1")
    }

    private func isC4FM(p1: String) async throws -> Bool {
        let reply = try await sendRawCommand("MD\(p1)")
        let prefix = "MD\(p1)"
        guard reply.hasPrefix(prefix) else { return false }
        let modeChar = reply.dropFirst(prefix.count).first
        return modeChar == "H" || modeChar == "I"
    }

    public func getPTT() async throws -> Bool {
        let line = try await send("t \(Self.currentVFOArg)")
        return line == "1"
    }

    /// Reads a rigctld level (e.g. "SWR", "RFPOWER_METER_WATTS"). Returns
    /// nil rather than throwing when the rig/backend doesn't support the
    /// requested level — rigctld reports that as an "RPRT -N" line, which
    /// isn't parseable as a number.
    public func getLevel(_ name: String) async throws -> Double? {
        let line = try await send("l \(Self.currentVFOArg) \(name)")
        return Double(line)
    }

    /// Sends a raw CAT command straight to the rig via rigctld's passthrough
    /// (`W`/send_cmd_rx), for settings hamlib doesn't expose as a named
    /// func/level/parm — most of the FTX-1's menu items, per its CAT
    /// Operation Reference Manual, which documents dedicated two/three-
    /// letter commands (e.g. "BI" for break-in, "KR" for the keyer) rather
    /// than routing everything through a generic numbered menu command.
    ///
    /// `cmd` should not include the trailing `;` — this method appends it.
    /// It has to be part of the outgoing command text itself (not left to
    /// rigctld to append): hamlib's `send_cmd` (tests/rigctl_parse.c)
    /// special-cases Kenwood/Yaesu backends to *disable* its own automatic
    /// terminator append (`send_cmd_term = 0`), on the assumption the
    /// caller already writes `;`-terminated command text — verified by
    /// reading that source directly. Skipping it means the bytes hitting
    /// the rig's serial port are e.g. "BI1" with no terminator at all,
    /// which the radio never recognizes as a complete command; testing
    /// against a backend-agnostic dummy rigctld (which isn't Yaesu/Kenwood
    /// and doesn't hit that code path) won't catch this.
    ///
    /// That same source also has a quirk this works around: it picks the
    /// reply's trailing byte based on an internal `cmdcount` that counts
    /// `;` occurrences in the outgoing command text. Because our own
    /// command is itself `;`-terminated, `cmdcount` comes out as 2 (not 1)
    /// for what's really a single command, which makes it terminate the
    /// reply with `\0` instead of the `\n` every other rigctld reply uses —
    /// confirmed by reading the source and reproducing it against a local
    /// dummy rigctld. `readLine(terminators:)` accepts both so this doesn't
    /// hang waiting for a `\n` that will never come.
    /// The manual doesn't promise every command gets an Answer — Set
    /// commands in particular may not. If the real rig simply never
    /// replies, `readLine()` would otherwise wait forever: there's no
    /// timeout anywhere in the read path. Since `acquireRoundTrip()`
    /// serializes every round trip on this client, one hung read would
    /// permanently jam every future call behind it (this is what actually
    /// happened: the very first raw command after a fresh connection
    /// worked, then everything else silently queued forever). `timeout`
    /// bounds the wait, and on expiry — following the same technique
    /// `connect()` above uses — explicitly cancels the connection so the
    /// still-pending `readLine()` continuation is forced to resolve rather
    /// than leak, and lets the poll loop's existing reconnect logic notice
    /// and recover the connection instead of leaving it wedged.
    ///
    /// A genuinely-unanswered command isn't just slow to reply — reading
    /// hamlib's own `send_cmd` (tests/rigctl_parse.c), when its internal
    /// serial read errors out it `break`s out before ever writing *any*
    /// reply back to us, not even an error line, so there's nothing this
    /// client could wait longer to catch. 1s is a generous margin over
    /// rigctld's own per-command timeout (300ms, tuned down from hamlib's
    /// default 1000ms×3 retries in `RigctldProcessController` — that
    /// default meant a single unanswered raw command held rigctld's global
    /// per-client lock for up to ~4s, blocking every other pending
    /// command too, which was most of the multi-second delay users saw
    /// after clicking a menu button).
    public func sendRawCommand(_ cmd: String, timeout: Duration = .seconds(1)) async throws -> String {
        await acquireRoundTrip()
        defer { releaseRoundTrip() }
        try await write("W \(cmd); ;")

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.readLine(terminators: [0, UInt8(ascii: "\n")]) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RigctldError.rawCommandTimedOut
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                // See connect()'s identical comment above: cancelling here,
                // before this closure returns, is what actually unsticks
                // the losing readLine() — group.cancelAll() alone only
                // marks it cancelled, it doesn't force a continuation
                // waiting on an NWConnection callback to resume.
                //
                // A single unanswered raw command isn't always the rare
                // "genuinely wedged" case this was written for — confirmed
                // against real hardware that "GT0" (AGC), which this rig
                // answers fine in SSB/CW, gets no reply at all while the
                // active VFO is in C4FM (AGC doesn't apply to digital
                // voice). That makes it a routine, every-poll-cycle
                // occurrence in C4FM, not a one-off: disconnecting and
                // leaving this actor connectionless made every cycle force
                // a full reconnect (visible disconnect + audio-engine
                // restart) roughly every 5s. Reconnecting immediately here
                // — instead of just disconnecting and letting a later,
                // unrelated call discover `notConnected` — keeps that
                // routine failure confined to this one best-effort field;
                // its caller already treats a thrown error here as
                // optional (see e.g. `getRawInt`/`getRawBool`'s `try?`
                // callers). If the rig is genuinely gone rather than just
                // not answering this one command, this reconnect attempt
                // fails too and the next hard read (e.g. `getFrequency()`)
                // surfaces that normally.
                disconnect()
                try? await connect()
                group.cancelAll()
                throw error
            }
        }
    }

    /// Reads a boolean on/off CAT setting of the form the FTX-1 manual
    /// documents for e.g. "BI" (break-in) and "KR" (keyer): querying
    /// "<CMD>;" answers "<CMD><P1>;" where P1 is "0" or "1". Tolerates the
    /// reply either including or omitting its own trailing ";" — observed
    /// both ways against a local dummy rigctld, and the real rig's exact
    /// behavior here isn't confirmed yet. Returns nil if the reply doesn't
    /// match that shape at all.
    public func getRawBool(_ cmd: String) async throws -> Bool? {
        let reply = try await sendRawCommand(cmd)
        guard reply.hasPrefix(cmd) else { return nil }
        let value = reply.dropFirst(cmd.count)
        if value.hasPrefix("1") { return true }
        if value.hasPrefix("0") { return false }
        return nil
    }

    /// Sets a boolean on/off CAT setting of the form "<CMD><0|1>;" — see
    /// `getRawBool(_:)`.
    public func setRawBool(_ cmd: String, _ on: Bool) async throws {
        try await sendRawCommandFireAndForget("\(cmd)\(on ? 1 : 0)")
    }

    /// Reads a fixed-width numeric CAT setting of the form the FTX-1 manual
    /// documents for e.g. "KS" (keyer speed, 3 digits) and "KP" (key pitch,
    /// 2 digits): querying "<CMD>;" answers "<CMD><digits>;". Takes only the
    /// leading run of digits after the command prefix, tolerating the reply
    /// either including or omitting its own trailing ";" (see
    /// `getRawBool(_:)` for the same reasoning). Returns nil if the reply
    /// doesn't match that shape at all.
    public func getRawInt(_ cmd: String) async throws -> Int? {
        let reply = try await sendRawCommand(cmd)
        guard reply.hasPrefix(cmd) else { return nil }
        let digits = reply.dropFirst(cmd.count).prefix { $0.isNumber }
        return Int(digits)
    }

    /// Sets a fixed-width, zero-padded numeric CAT setting of the form
    /// "<CMD><digits>;" — see `getRawInt(_:)`. `digits` is the field width
    /// (e.g. 3 for "KS004;", 2 for "KP00;"), per the manual.
    public func setRawInt(_ cmd: String, _ value: Int, digits: Int) async throws {
        let padded = String(format: "%0\(digits)d", value)
        try await sendRawCommandFireAndForget("\(cmd)\(padded)")
    }

    /// Reads a single-digit sub-field addressed by a full-width raw CAT
    /// prefix (P1/P2 baked into `cmd`, matching the "PA0"/"RA0"/"ML1"-style
    /// fixed-sub-selector pattern other raw commands use), where the
    /// reply's remaining digits are themselves a multi-field packed value
    /// and only the first one is wanted — e.g. the FTX-1's raw "SS"
    /// (SPECTRUM SCOPE) command answers with P1 P2 P3 P4 P5 P6 P7 packed
    /// together with no separators, so `getRawInt`'s "take the whole
    /// trailing digit run as one number" parsing would misread e.g. PEAK
    /// LV5's "20000" reply as 20000 instead of 2.
    public func getRawDigit(_ cmd: String) async throws -> Int? {
        let reply = try await sendRawCommand(cmd)
        guard reply.hasPrefix(cmd) else { return nil }
        return reply.dropFirst(cmd.count).first?.wholeNumberValue
    }

    /// Sets a single-digit sub-field the same shape `getRawDigit(_:)` reads,
    /// where the manual documents the remaining fields after it as fixed
    /// "0" — e.g. "SS"'s PEAK (P3, followed by P4-P7 all "0") and MARKER
    /// (P3, followed by P4-P7 all "0") sub-functions. Unlike `setRawInt`,
    /// which zero-*pads* a single value to a field width, this writes one
    /// real digit followed by a fixed run of literal zero digits for the
    /// unused trailing fields the manual documents as always "0" — sending
    /// a short command (e.g. just "SS021" instead of the full 7-digit
    /// "SS0210000") doesn't match the command's documented digit width and
    /// hasn't been tested against the real rig.
    public func setRawPackedDigit(_ cmd: String, _ digit: Int, trailingZeros: Int) async throws {
        try await sendRawCommandFireAndForget("\(cmd)\(digit)\(String(repeating: "0", count: trailingZeros))")
    }

    /// Reads the FTX-1's raw "SS" (SPECTRUM SCOPE) command's LEVEL
    /// sub-function (P2=4) — unlike PEAK/MARKER above, LEVEL's P3-P7 aren't
    /// separate fixed/variable fields at all: the manual documents them
    /// together as one 5-character signed decimal ("-30.0" to "+30.0" in
    /// 0.5dB steps, e.g. "+15.0"). Takes only the leading run of
    /// digit/"."/"+"/"-" characters before parsing (same reasoning as
    /// `getRawInt`'s digit-only prefix) rather than handing `Double.init`
    /// the whole remainder: the reply's trailing ";" is the CAT protocol's
    /// own terminator character, part of the payload bytes and not stripped
    /// by `readLine()` (which only strips rigctld's own `\0`/`\n` framing) —
    /// passing that ";" straight into `Double.init` made it fail to parse
    /// every reply, always returning nil regardless of the radio's actual
    /// setting.
    public func getSpectrumScopeLevel() async throws -> Double? {
        let reply = try await sendRawCommand("SS04")
        guard reply.hasPrefix("SS04") else { return nil }
        let value = reply.dropFirst(4).prefix { $0.isNumber || $0 == "." || $0 == "+" || $0 == "-" }
        return Double(value)
    }

    /// Sets "SS"'s LEVEL sub-function — see `getSpectrumScopeLevel()`. `%04.1f`
    /// zero-pads the magnitude to the manual's fixed "XX.X" width (e.g. 8.5
    /// -> "08.5", 15.0 -> "15.0") to match the 5-byte-total shape with the
    /// leading sign character.
    public func setSpectrumScopeLevel(_ dB: Double) async throws {
        let sign = dB < 0 ? "-" : "+"
        let formatted = String(format: "%04.1f", abs(dB))
        try await sendRawCommandFireAndForget("SS04\(sign)\(formatted)")
    }

    /// Reads P3 of the FTX-1's raw "RI" (RADIO INFORMATION) status command —
    /// 0 = stopped, 1 = recording, 2 = playing (CW MESSAGE record/playback
    /// state — see `RigState.cwMessageStatus`). RI's answer packs 8
    /// single-digit fields ("RI" + P1..P8 + ";") rather than one trailing
    /// run of digits, so `getRawInt` isn't usable here — it would
    /// concatenate all 8 into one number instead of isolating P3. RI also
    /// reports several other fields (Hi-SWR, TX state, tuner, scan,
    /// squelch) this app doesn't use yet. Read-only per the manual (no
    /// Set), queried as "RI0" (P1 fixed to 0).
    public func getCWMessageStatus() async throws -> Int? {
        let reply = try await sendRawCommand("RI0")
        guard reply.hasPrefix("RI") else { return nil }
        let fields = Array(reply.dropFirst(2))
        guard fields.count >= 3 else { return nil }
        return fields[2].wholeNumberValue
    }

    /// Reads whether the FTX-1's antenna tuner is engaged — P3 of the raw
    /// "AC" (ANTENNA TUNER CONTROL) command's Answer (see `CommandQueue`'s
    /// `.setTuner` case for the P1/P2 addressing the Set side uses — the
    /// Read side doesn't need to match it, see below). "AC"'s Read command
    /// takes no parameters at all ("AC;", unlike most raw commands this app
    /// wires, which repeat a fixed sub-selector prefix on both Read and
    /// Set), and its Answer packs three single-digit fields ("AC" + P1 + P2
    /// + P3 + ";") reporting whichever tuner is actually active, so neither
    /// `getRawBool` nor `getRawInt` is usable here — same reasoning as
    /// `getCWMessageStatus()` above.
    public func getTunerEnabled() async throws -> Bool? {
        let reply = try await sendRawCommand("AC")
        guard reply.hasPrefix("AC") else { return nil }
        let fields = Array(reply.dropFirst(2))
        guard fields.count >= 3 else { return nil }
        return fields[2] == "1"
    }

    /// Reads the FTX-1's raw "DA" (DIMMER) command — its Answer packs three
    /// independently-adjustable 2-digit fields behind a fixed 2-digit P1
    /// ("DA" + P1(00, fixed) + P2(contrast) + P3(TFT brightness) +
    /// P4(LED brightness) + ";"), so neither `getRawInt` (which assumes one
    /// trailing run of digits is one value) nor `getRawBool` fit — same
    /// reasoning as `getTunerEnabled()`/`getCWMessageStatus()` above, just
    /// with 2-digit fields instead of 1-digit ones.
    public func getDisplaySettings() async throws -> (contrast: Int, brightness: Int, ledBrightness: Int)? {
        let reply = try await sendRawCommand("DA")
        guard reply.hasPrefix("DA") else { return nil }
        let digits = Array(reply.dropFirst(2).prefix { $0.isNumber })
        guard digits.count >= 8,
              let contrast = Int(String(digits[2...3])),
              let brightness = Int(String(digits[4...5])),
              let ledBrightness = Int(String(digits[6...7]))
        else { return nil }
        return (contrast, brightness, ledBrightness)
    }

    /// Sets all three of "DA"'s fields at once — per the manual, Set always
    /// writes P2/P3/P4 together in one command, there's no way to address
    /// just one field. Callers that only want to change one value (e.g. a
    /// D-CONTRAST stepper) must read the current triple via
    /// `getDisplaySettings()` first and pass the other two through
    /// unchanged, the same read-modify-write shape `CommandQueue` already
    /// uses.
    public func setDisplaySettings(contrast: Int, brightness: Int, ledBrightness: Int) async throws {
        let p2 = String(format: "%02d", contrast)
        let p3 = String(format: "%02d", brightness)
        let p4 = String(format: "%02d", ledBrightness)
        try await sendRawCommandFireAndForget("DA00\(p2)\(p3)\(p4)")
    }

    /// Reads one item from the FTX-1's "EX" (MENU) command — the deep
    /// SET-mode settings (Radio/CW/Operation/Display/Extension/APRS
    /// Setting on the real rig, "Table 3" in the CAT manual), addressed by
    /// `P1` (category), `P2` (tab), `P3` (item) rather than each having its
    /// own mnemonic like "BI"/"KR"/etc. Read command is "EX" + 2-digit P1 +
    /// 2-digit P2 + 2-digit P3 + ";"; Answer echoes that same 6-digit
    /// address back before the value (P4), whose width/shape (plain digits,
    /// signed digits, or ASCII text) varies per item — so this returns the
    /// raw P4 substring rather than attempting to parse it, leaving typed
    /// decoding to `DeepSettingItem` (see DeepSettingsCatalog.swift), the
    /// same "raw CAT layer stays dumb" split `getRawInt`/`getRawBool` use.
    public func getMenuItem(p1: Int, p2: Int, p3: Int) async throws -> String? {
        let prefix = "EX" + String(format: "%02d%02d%02d", p1, p2, p3)
        let reply = try await sendRawCommand(prefix)
        guard reply.hasPrefix(prefix) else { return nil }
        var value = String(reply.dropFirst(prefix.count))
        if value.hasSuffix(";") { value.removeLast() }
        return value
    }

    /// Writes one "EX" menu item — see `getMenuItem(p1:p2:p3:)`. `rawValue`
    /// is P4 already encoded to the item's expected shape (caller's
    /// responsibility, via `DeepSettingItem.encode(_:)`). Fire-and-forget
    /// like `setRawBool`/`setRawInt`, since Set commands on this rig don't
    /// get a reply.
    public func setMenuItem(p1: Int, p2: Int, p3: Int, rawValue: String) async throws {
        let prefix = "EX" + String(format: "%02d%02d%02d", p1, p2, p3)
        try await sendRawFireAndForget(prefix + rawValue)
    }

    /// Like `sendRawCommand`, but doesn't wait for or read any reply at
    /// all — for Set-style commands, which this rig (confirmed both by
    /// the CAT manual, which documents an Answer only for Read commands,
    /// and by direct testing) never acknowledges. `sendRawCommand` used to
    /// be used for these too, but waiting out its timeout on *every single
    /// click* (there being no reply to actually catch) is what made menu
    /// buttons take several seconds to visibly update, even after tuning
    /// rigctld's own retry/timeout down in `RigctldProcessController` — the
    /// wait was happening client-side on every call, not just when
    /// something was actually wrong.
    ///
    /// This is safe from the same stale-reply risk `sendRawCommand`'s
    /// timeout path guards against: hamlib's `send_cmd` (tests/
    /// rigctl_parse.c) writes *nothing* back when its internal serial read
    /// fails, so there's no eventual reply sitting around to leak into a
    /// later read — confirmed by reading that source directly. `write(_:)`
    /// clears any stale buffered bytes at the start of the next round trip
    /// as a defensive backstop regardless.
    /// Sends a raw CAT command that isn't shaped like a boolean or
    /// fixed-width-int setting (see `setRawBool`/`setRawInt`) — for
    /// momentary/action commands such as "ZI0" (CW auto zero-in), which
    /// take a fixed literal parameter rather than a value derived from
    /// app state, and (per the manual) get no reply. Not `private` since,
    /// unlike `setRawBool`/`setRawInt`, there's no per-setting wrapper in
    /// this file for `CommandQueue` to call instead.
    func sendRawFireAndForget(_ cmd: String) async throws {
        try await sendRawCommandFireAndForget(cmd)
    }

    private func sendRawCommandFireAndForget(_ cmd: String) async throws {
        await acquireRoundTrip()
        defer { releaseRoundTrip() }
        try await write("W \(cmd); ;")
    }

    /// Reads the frequency of whichever VFO isn't currently active, without
    /// switching the rig to it. Two things were tried and rejected before
    /// this:
    ///  - Physically switching VFOs to read the other one (`V`/`v`) audibly
    ///    clicks a relay on the real rig every ~5s while polling.
    ///  - The extended `\get_freq <VFO>` command *looks* like a targeted
    ///    read but silently ignores the VFO argument and just returns the
    ///    active VFO's frequency unless rigctld is running with `-o` — this
    ///    was the cause of the primary/secondary frequency display showing
    ///    identical values.
    /// With `-o` enabled, the plain short-form `f <VFO>` reliably targets
    /// the requested VFO without switching the rig to it (verified against
    /// real hardware: consistent, distinct values across repeated calls,
    /// `v` unchanged before/after).
    ///
    /// This rig reports its VFOs as "Main"/"Sub" (not the generic
    /// "VFOA"/"VFOB" hamlib aliases some other rigs use), confirmed via `v`
    /// and `\get_vfo_list`.
    public func getSecondaryFrequency() async throws -> Int {
        let currentVFO = try await send("v")
        let otherVFO = currentVFO == "Sub" ? "Main" : "Sub"
        let freqLine = try await send("f \(otherVFO)")
        guard let hz = Int(freqLine) else { throw RigctldError.badResponse }
        return hz
    }

    /// Reads the mode of whichever VFO isn't currently active. Unlike
    /// `getSecondaryFrequency()`, this isn't reliable on every rig/backend —
    /// on the FTX-1's hamlib backend (as of Hamlib 4.7.2), querying the Sub
    /// receiver's mode consistently fails ("RPRT -8", protocol error), even
    /// though `\dump_caps` lists MODE as a targetable feature. Throws in
    /// that case rather than guessing; callers should treat this the same
    /// as `getSecondaryFrequency()` — best-effort, fine to swallow with
    /// `try?`.
    public func getSecondaryMode() async throws -> String {
        let currentVFO = try await send("v")
        let otherVFO = currentVFO == "Sub" ? "Main" : "Sub"
        let lines = try await queryOrError("m \(otherVFO)", lines: 2)
        guard lines.count == 2 else { throw RigctldError.badResponse }
        return lines[0]
    }

    /// Writes the frequency of whichever VFO isn't currently active — the
    /// set-side counterpart to `getSecondaryFrequency()`, same "ask `v` for
    /// the active VFO, target the other one explicitly" shape.
    ///
    /// Unlike the get side, it's *not confirmed against real hardware*
    /// whether the short-form set command (`F <VFO> <hz>`) targets the named
    /// VFO cleanly the way `f <VFO>` does on read, or whether writing a
    /// non-active VFO requires rigctld/hamlib to switch to it internally
    /// first. To not depend on that assumption either way, this checks the
    /// active VFO again after the write and switches back if it moved —
    /// so VFO A stays put and stays active from the app's perspective
    /// regardless of what happened underneath.
    public func setSecondaryFrequency(_ hz: Int) async throws {
        let currentVFO = try await send("v")
        let otherVFO = currentVFO == "Sub" ? "Main" : "Sub"
        _ = try await send("F \(otherVFO) \(hz)")
        let vfoAfterSet = try await send("v")
        if vfoAfterSet != currentVFO {
            _ = try await send("V \(currentVFO)")
        }
    }

    /// Switches which of Main/Sub is the active VFO — the rigctld
    /// counterpart of the rig's own physical A/B swap button. Unlike the
    /// VFO switching `getSecondaryFrequency()`'s doc comment says to avoid,
    /// this is a deliberate user action (not something a background poll
    /// loop does silently), so the relay click that comes with it is
    /// expected, same as pressing the physical button.
    public func swapActiveVFO() async throws {
        let currentVFO = try await send("v")
        let otherVFO = currentVFO == "Sub" ? "Main" : "Sub"
        _ = try await send("V \(otherVFO)")
    }

    private func write(_ command: String) async throws {
        guard let connection else {
            throw RigctldError.notConnected
        }
        // Every ordinary round trip fully drains its own reply via
        // readLine() before releasing acquireRoundTrip()'s lock, so any
        // bytes still sitting here at the start of a *new* round trip can
        // only be stale leftovers — specifically from
        // sendRawCommandFireAndForget below, which deliberately doesn't
        // read a reply at all. Discarding them keeps a late, unsolicited
        // byte from a previous fire-and-forget command from being
        // misread as part of this new exchange.
        readBuffer.removeAll()
        let data = (command + "\n").data(using: .utf8)!
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// `terminators` defaults to just `\n` — every normal rigctld reply
    /// (get/set commands, RPRT lines) ends that way. Raw passthrough
    /// (`sendRawCommand`) needs `\0` accepted too: hamlib's `send_cmd`
    /// (tests/rigctl_parse.c) picks the reply's trailing byte based on an
    /// internal `cmdcount` that counts `;` occurrences in the outgoing
    /// command — since Yaesu/Kenwood raw commands are themselves
    /// `;`-terminated, that count comes out as 2 (not 1) for an ordinary
    /// single command, which selects `\0` instead of `\n`. Confirmed by
    /// reading that source directly and reproducing it against a local
    /// dummy rigctld.
    private func readLine(terminators: Set<UInt8> = [UInt8(ascii: "\n")]) async throws -> String {
        while true {
            if let terminatorIndex = readBuffer.firstIndex(where: { terminators.contains($0) }) {
                let lineData = readBuffer[readBuffer.startIndex..<terminatorIndex]
                let line = String(data: lineData, encoding: .utf8) ?? ""
                readBuffer.removeSubrange(readBuffer.startIndex...terminatorIndex)
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let connection else {
                throw RigctldError.notConnected
            }
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: RigctldError.badResponse)
                    }
                }
            }
            readBuffer.append(chunk)
        }
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        readBuffer.removeAll()
    }
}

/// Guards a `CheckedContinuation` against being resumed more than once —
/// `NWConnection.stateUpdateHandler` can fire `.ready` and then later
/// `.failed` on the same connection, and resuming twice is a crash.
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}

public enum RigctldError: Error {
    case notConnected
    case badResponse
    case connectTimedOut
    case rawCommandTimedOut
}

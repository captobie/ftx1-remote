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
        let conn = NWConnection(host: host, port: port, using: .tcp)
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

    public func getMode() async throws -> (mode: String, passband: Int) {
        let lines = try await query("m \(Self.currentVFOArg)", lines: 2)
        guard lines.count == 2, let passband = Int(lines[1]) else {
            throw RigctldError.badResponse
        }
        return (lines[0], passband)
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
                disconnect()
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

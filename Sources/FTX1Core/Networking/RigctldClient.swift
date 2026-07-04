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
    /// request/response, so callers should serialize access via
    /// CommandQueue rather than firing concurrent requests at this client.
    public func send(_ command: String) async throws -> String {
        try await write(command)
        return try await readLine()
    }

    /// Sends a command that returns a known fixed number of lines back
    /// (e.g. "m" for get_mode, which replies with mode + passband on
    /// separate lines).
    public func query(_ command: String, lines: Int) async throws -> [String] {
        try await write(command)
        var result: [String] = []
        for _ in 0..<lines {
            result.append(try await readLine())
        }
        return result
    }

    public func getFrequency() async throws -> Int {
        let line = try await send("f")
        guard let hz = Int(line) else { throw RigctldError.badResponse }
        return hz
    }

    public func getMode() async throws -> (mode: String, passband: Int) {
        let lines = try await query("m", lines: 2)
        guard lines.count == 2, let passband = Int(lines[1]) else {
            throw RigctldError.badResponse
        }
        return (lines[0], passband)
    }

    public func getPTT() async throws -> Bool {
        let line = try await send("t")
        return line == "1"
    }

    /// Reads a rigctld level (e.g. "SWR", "RFPOWER_METER_WATTS"). Returns
    /// nil rather than throwing when the rig/backend doesn't support the
    /// requested level — rigctld reports that as an "RPRT -N" line, which
    /// isn't parseable as a number.
    public func getLevel(_ name: String) async throws -> Double? {
        let line = try await send("l \(name)")
        return Double(line)
    }

    /// Reads the frequency of whichever VFO isn't currently active — there's
    /// no way to query it without switching the rig to it, so this switches,
    /// reads, and switches back, restoring the original VFO even if the read
    /// itself fails. Callers should poll this far less often than the main
    /// state (`getFrequency`, etc.), since it briefly flips the rig's actual
    /// active VFO twice per call.
    public func getSecondaryFrequency() async throws -> Int {
        let currentVFO = try await send("v")
        let otherVFO = currentVFO == "VFOB" ? "VFOA" : "VFOB"
        _ = try await send("V \(otherVFO)")
        do {
            let freqLine = try await send("f")
            _ = try await send("V \(currentVFO)")
            guard let hz = Int(freqLine) else { throw RigctldError.badResponse }
            return hz
        } catch {
            _ = try? await send("V \(currentVFO)")
            throw error
        }
    }

    private func write(_ command: String) async throws {
        guard let connection else {
            throw RigctldError.notConnected
        }
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

    private func readLine() async throws -> String {
        while true {
            if let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
                let line = String(data: lineData, encoding: .utf8) ?? ""
                readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
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
}

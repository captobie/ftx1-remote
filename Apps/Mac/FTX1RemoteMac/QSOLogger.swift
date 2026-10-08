import FTX1Core
import Foundation
import Network
import os

private let logbookLogger = Logger(subsystem: "com.ftx1remote.mac", category: "logbook")

/// Sends a finished QSO to the logbook chosen in Settings → Logbook. For
/// MacLoggerDX that's WSJT-X's UDP protocol (user decision, over
/// AppleScript): the "QSO Logged" + "Logged ADIF" datagrams WSJT-X sends
/// when its Log QSO dialog is accepted (no Heartbeat — see
/// `WSJTXMessage`), to
/// `LogbookSettings.macLoggerDXUDPHost`/`Port`. UDP gets no answer, so the
/// QSO is then looked for in MacLoggerDX's log file to confirm it arrived.
///
/// Also asks MacLoggerDX to look a callsign up (`lookUp`), the way WSJT-X
/// gets it to: a Status message carrying the call as its DX call.
enum QSOLogger {
    enum Outcome: Equatable {
        /// Found in the logbook's file afterward.
        case logged
        /// Sent, but not (yet) in the log file — MacLoggerDX not running,
        /// not listening for WSJT-X UDP, or the log can't be read here.
        case sentUnconfirmed(String)
        case failed(String)
    }

    /// How long to look for the QSO in the log after sending.
    static let confirmationTimeout: Duration = .seconds(5)

    static func log(_ qso: LoggedQSO) async -> Outcome {
        guard LogbookSettings.logger == .macLoggerDX else {
            return .failed("No logbook is selected in Settings → Logbook")
        }
        if let problem = await sendToMacLoggerDX([WSJTXMessage.qsoLogged(qso), WSJTXMessage.loggedADIF(qso)], what: qso.call) {
            return .failed(problem)
        }
        logbookLogger.notice("Logged \(qso.call, privacy: .public) (\(qso.mode, privacy: .public), \(qso.frequencyHz) Hz)")
        return await confirm(qso)
    }

    /// Has MacLoggerDX look `call` up (its call field, QRZ data, worked-
    /// before line) by sending what WSJT-X sends when its DX Call changes.
    /// MacLoggerDX only acts on a *changed* DX call, so an empty one goes
    /// first — otherwise looking up the same call twice in a row does
    /// nothing. The dial frequency and mode fill its entry panel too, and
    /// must be real: it ignores the whole message at 0 Hz.
    /// Returns nil once sent, or why it couldn't be; there's no answer to
    /// wait for (the lookup itself takes MacLoggerDX a few seconds).
    static func lookUp(call: String, dialFrequencyHz: Int, mode: String) async -> String? {
        guard LogbookSettings.logger == .macLoggerDX else {
            return "No logbook is selected in Settings → Logbook"
        }
        let status = { (dxCall: String) in
            WSJTXMessage.status(
                dialFrequencyHz: dialFrequencyHz,
                mode: mode,
                dxCall: dxCall,
                deCall: StationSettings.callsign,
                deGrid: StationSettings.gridSquare
            )
        }
        if let problem = await sendToMacLoggerDX([status(""), status(call)], what: "lookup of \(call)") {
            return problem
        }
        if !MacLoggerDX.isRunning {
            return "Sent, but MacLoggerDX isn't running"
        }
        return nil
    }

    /// Sends to Settings → Logbook's host/port; nil once sent, otherwise
    /// what went wrong, in words for the pane.
    private static func sendToMacLoggerDX(_ datagrams: [Data], what: String) async -> String? {
        let host = LogbookSettings.macLoggerDXUDPHost
        let port = LogbookSettings.macLoggerDXUDPPort
        do {
            try await send(datagrams, host: host, port: port)
            return nil
        } catch {
            logbookLogger.error("Sending \(what, privacy: .public) to \(host, privacy: .public):\(port) failed: \(error.localizedDescription, privacy: .public)")
            if case NWError.dns = error {
                return "Couldn't find the host \(host)"
            }
            return "Couldn't send to \(host):\(port): \(error.localizedDescription)"
        }
    }

    /// Polls the log file until the QSO shows up or the timeout passes.
    private static func confirm(_ qso: LoggedQSO) async -> Outcome {
        guard let path = LogbookSettings.macLoggerDXLogPath else {
            return .sentUnconfirmed("Sent, but MacLoggerDX's log file wasn't found to check it")
        }
        let deadline = ContinuousClock.now + confirmationTimeout
        var lastError: MacLoggerDX.LogError?
        repeat {
            try? await Task.sleep(for: .milliseconds(500))
            let result = await Task.detached {
                Result { () throws(MacLoggerDX.LogError) in
                    try MacLoggerDX.containsQSO(call: qso.call, start: qso.start, path: path)
                }
            }.value
            switch result {
            case .success(true):
                logbookLogger.notice("\(qso.call, privacy: .public) confirmed in the MacLoggerDX log")
                return .logged
            case .success(false):
                lastError = nil
            case .failure(let error):
                lastError = error
            }
        } while ContinuousClock.now < deadline

        if let lastError {
            return .sentUnconfirmed("Sent, but the log couldn't be checked: \(lastError.description)")
        }
        let reason = !MacLoggerDX.isRunning
            ? "MacLoggerDX isn't running"
            : MacLoggerDX.listensForWSJTXUDP == false
                ? "MacLoggerDX isn't listening for WSJT-X UDP"
                : "it didn't show up in the log within \(confirmationTimeout.components.seconds) s"
        logbookLogger.notice("\(qso.call, privacy: .public) not found in the MacLoggerDX log: \(reason, privacy: .public)")
        return .sentUnconfirmed("Sent, but \(reason)")
    }

    /// One UDP flow per call: wait for it to be ready, send each datagram
    /// in order, then close. Fails after 3 s if the host can't be resolved
    /// or routed to.
    private static func send(_ datagrams: [Data], host: String, port: Int) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw URLError(.badURL)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "com.ftx1remote.mac.qso-logger")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                if once.claim() { continuation.resume(throwing: URLError(.timedOut)) }
            }
        }

        for datagram in datagrams {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: datagram, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
    }

    /// Resumes a continuation exactly once from several callbacks.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}

import Combine
import FTX1Core
import Foundation
import Network
import os

/// Wavelog → rig: clicking a spot in Wavelog's DX cluster, bandmap or DX
/// waterfall tunes the rig (user request, 2026-10-25). Wavelog's page
/// `fetch`es `GET <cat_url>/<Hz>/<mode>` from the browser
/// (`WavelogTuneRequest`); the radio's `cat_url` is
/// `http://127.0.0.1:54321` unless set in Wavelog, so this listens there —
/// WaveLogGate's port, so only one of the two can run. Settings → Logbook
/// → Wavelog → "Tune the rig from Wavelog"; off by default.
///
/// Loopback only, so the browser has to run on this Mac. Any web page
/// could send the same request, so only one whose `Origin` is the Wavelog
/// URL in Settings is obeyed (a browser always sends it on a cross-origin
/// `fetch`; `curl` needs `-H Origin:`). The reply carries CORS headers for
/// that origin, and answers Chrome's private-network preflight
/// (`Access-Control-Allow-Private-Network`). The tuning itself is
/// `HubService.tuneFromWavelog`, with the same rules as the WebSDR
/// window's click-to-tune.
@MainActor
final class WavelogTuneListener: ObservableObject {
    static let maxHeadBytes = 8192

    enum State: Equatable {
        case off
        case listening(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// The last request's outcome, for Settings.
    @Published private(set) var lastEvent: (at: Date, text: String, ok: Bool)?

    private let logger = Logger(subsystem: "com.ftx1remote.mac", category: "wavelog")
    private let tune: (WavelogTuneRequest) -> String?
    private var listener: NWListener?
    private var listeningPort: UInt16?

    /// `tune` tunes the rig, or returns why it didn't.
    init(tune: @escaping (WavelogTuneRequest) -> String?) {
        self.tune = tune
    }

    /// Starts, stops or moves the listener to match Settings.
    func applySettings() {
        let port = LogbookSettings.wavelogTunePort
        guard LogbookSettings.wavelogTuneEnabled else {
            stop()
            return
        }
        if listener != nil, listeningPort == port, case .listening = state { return }
        stop()
        start(port: port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        state = .off
    }

    private func start(port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("Port \(port) isn't valid")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            state = .failed("Couldn't listen on port \(port): \(error.localizedDescription)")
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            MainActor.assumeIsolated {
                // A replaced listener's late updates don't count.
                guard let self, let listener, self.listener === listener else { return }
                self.listenerStateChanged(newState, port: port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listeningPort = port
        listener.start(queue: .main)
    }

    private func listenerStateChanged(_ newState: NWListener.State, port: UInt16) {
        switch newState {
        case .ready:
            state = .listening(port: port)
            logger.notice("tune listener on 127.0.0.1:\(port)")
        case .failed(let error):
            let inUse: Bool
            if case .posix(let code) = error, code == .EADDRINUSE { inUse = true } else { inUse = false }
            state = .failed(inUse
                ? "Port \(port) is in use — is WaveLogGate running?"
                : "Couldn't listen on port \(port): \(error.localizedDescription)")
            logger.error("tune listener failed: \(String(describing: error), privacy: .public)")
            listener?.cancel()
            listener = nil
            listeningPort = nil
        default:
            break
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
        // A client that never finishes its request isn't kept around.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak connection] in
            connection?.cancel()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeadBytes) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(to: buffer[..<end.lowerBound], on: connection)
                } else if error != nil || isComplete || buffer.count >= Self.maxHeadBytes {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to headData: Data, on connection: NWConnection) {
        guard let head = WavelogTuneRequest.parseHead(String(decoding: headData, as: UTF8.self)) else {
            send(400, "Bad request", origin: nil, on: connection)
            return
        }
        let origin = head.headers["origin"]
        let allowed = WavelogTuneRequest.origin(ofWavelogURL: LogbookSettings.wavelogURL)
        let originOK = origin.map { $0.lowercased() == allowed } ?? false

        if head.method == "OPTIONS" {
            send(originOK ? 204 : 403, "", origin: originOK ? origin : nil, on: connection, preflight: true)
            return
        }
        guard head.method == "GET" else {
            send(405, "Method not allowed", origin: nil, on: connection)
            return
        }
        guard let request = WavelogTuneRequest(path: head.path) else {
            send(404, "Not found", origin: originOK ? origin : nil, on: connection)
            return
        }
        guard originOK else {
            let from = origin ?? "a request without an Origin"
            record("Ignored a tune request from \(from) — it isn't the Wavelog URL above", ok: false)
            send(403, "Origin not allowed", origin: nil, on: connection)
            return
        }
        let modeText = request.mode?.displayName ?? "mode unchanged"
        let mhz = String(format: "%.4f MHz", Double(request.frequencyHz) / 1_000_000)
        if let refusal = tune(request) {
            record("Didn't tune to \(mhz): \(refusal)", ok: false)
            send(409, refusal, origin: origin, on: connection)
        } else {
            record("Tuned to \(mhz) \(modeText)", ok: true)
            send(200, "OK", origin: origin, on: connection)
        }
    }

    private func record(_ text: String, ok: Bool) {
        logger.notice("\(text, privacy: .public)")
        lastEvent = (.now, text, ok)
    }

    private func send(_ status: Int, _ body: String, origin: String?, on connection: NWConnection, preflight: Bool = false) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 409: "Conflict"][status] ?? "Error"
        var lines = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(body.utf8.count)",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        if let origin {
            lines += ["Access-Control-Allow-Origin: \(origin)", "Vary: Origin"]
            if preflight {
                lines += [
                    "Access-Control-Allow-Methods: GET, OPTIONS",
                    "Access-Control-Allow-Headers: *",
                    "Access-Control-Allow-Private-Network: true",
                    "Access-Control-Max-Age: 600",
                ]
            }
        }
        let response = Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

import Foundation
import os

/// One KiwiSDR waterfall stream (`/<timestamp>/W/F`), the sound stream's
/// companion: same auth, same `MSG` framing, a keepalive every second, and
/// `SET zoom=… start=…` on the open socket to pan and zoom. Open it with
/// the sound stream's timestamp once that one is ready — the Kiwi pairs
/// them, so this takes no receiver channel of its own.
///
/// Its own actor rather than a mode of `KiwiSDRClient`: the two streams
/// share only the socket plumbing, and keeping them apart leaves the sound
/// path exactly as it was. A failure here ends only this stream; the
/// caller decides what the sound stream does (the Local SDR window keeps
/// playing). One session per instance. Never logs the password.
public actor KiwiWaterfallClient {
    public enum Event: Sendable {
        /// Accepted and set up: the geometry and calibration to read rows by.
        case ready(geometry: KiwiWaterfallGeometry, cal: Int)
        case row(KiwiWaterfallFrame)
        /// nil after `stop()`, else why.
        case closed(KiwiSDRError?)
    }

    public static let silenceTimeout: Duration = .seconds(10)

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let hostPort: String
    private let password: String
    private let identUser: String
    private let timestamp: Date
    private let logger: Logger

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastFrame = ContinuousClock.now
    private var finished = false
    private var accepted = false
    private var setUp = false
    private var announced = false

    // What the Kiwi reports before wf_setup (defaults = KiwiSDR 2 at v1.902).
    private var bandwidthHz = 30_000_000.0
    private var fftSize = 1024
    private var zoomMax = 14
    private var cal = -13
    /// The view to ask for once set up, then the last one sent.
    private var view: (zoom: Int, start: Int)?

    public init(hostPort: String, password: String, identUser: String = "FTX1Remote",
                timestamp: Date, logSubsystem: String) {
        self.hostPort = hostPort
        self.password = password
        self.identUser = identUser
        self.timestamp = timestamp
        self.logger = Logger(subsystem: logSubsystem, category: "kiwisdr")
        // Rows are ~1 KB; keep a second or two if the consumer stalls.
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public func start() {
        guard socket == nil, !finished else { return }
        guard let url = KiwiProtocol.waterfallURL(hostPort: hostPort, timestamp: timestamp) else {
            finish(.invalidHost)
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16 << 20
        self.session = session
        self.socket = socket
        logger.notice("waterfall: connecting to \(url.absoluteString, privacy: .public)")
        socket.resume()
        lastFrame = .now
        send(KiwiProtocol.auth(password: password), shownAs: "SET auth t=kiwi p=…")
        receiveTask = Task { await self.receiveLoop(socket) }
        watchdogTask = Task { await self.watchdog() }
    }

    public func stop() {
        guard !finished else { return }
        logger.notice("waterfall: stop()")
        finish(nil)
    }

    /// Pans/zooms on the open socket. Before setup it only changes what
    /// setup will ask for. Repeats of the last request aren't resent.
    public func setView(zoom: Int, start: Int) {
        if let view, view.zoom == zoom, view.start == start, setUp { return }
        view = (zoom, start)
        if setUp { send(KiwiProtocol.waterfallView(zoom: zoom, start: start)) }
    }

    // MARK: - Receiving

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !finished, !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                guard !finished else { return }
                logger.error("waterfall: receive failed: \(error.localizedDescription, privacy: .public)")
                finish(.unreachable(error.localizedDescription))
                return
            }
            lastFrame = .now
            switch message {
            case .data(let data): handle(data)
            case .string(let text): handle(Data(text.utf8))
            @unknown default: break
            }
        }
    }

    private func handle(_ data: Data) {
        switch KiwiProtocol.parseFrame(data) {
        case .message(let items):
            for item in items { handle(item) }
        case .waterfall(let row):
            guard announced, !row.isCompressed else { return }
            continuation.yield(.row(row))
        case .sound, .other, nil:
            break
        }
    }

    private func handle(_ item: KiwiMessageItem) {
        guard !finished else { return }
        let number = item.value.flatMap { Double($0) }
        switch item.name {
        case "load_cfg", "load_dxcfg", "load_dxcomm_cfg":
            return
        case "badp":
            let code = Int(item.value ?? "") ?? -1
            logger.notice("waterfall: badp=\(code)")
            switch code {
            case 0:
                accepted = true
                announceIfReady()
            case 1:
                // The sound stream already got in with this password, so
                // a refusal here is the channel side, not the password.
                finish(.busy)
            default:
                finish(.refused(code: code))
            }
        case "too_busy":
            finish(.busy)
        case "down":
            finish(.down)
        case "redirect":
            finish(.redirect(item.value ?? ""))
        case "bandwidth":
            if let number, number > 0 { bandwidthHz = number }
        case "wf_fft_size":
            if let number, number >= 64 { fftSize = Int(number) }
        case "zoom_max":
            if let number, number >= 0, number <= 20 { zoomMax = Int(number) }
        case "wf_cal":
            if let number { cal = Int(number) }
        case "wf_setup":
            guard !setUp else { return }
            setUp = true
            logger.notice("waterfall: setup bandwidth=\(self.bandwidthHz, privacy: .public) fft=\(self.fftSize) zoom_max=\(self.zoomMax) cal=\(self.cal)")
            for command in KiwiProtocol.waterfallSetupCommands(identUser: identUser) { send(command) }
            if let view, view.zoom != 0 || view.start != 0 {
                send(KiwiProtocol.waterfallView(zoom: view.zoom, start: view.start))
            } else {
                view = (0, 0)
            }
            send(KiwiProtocol.keepalive, log: false)
            keepaliveTask = Task { await self.keepaliveLoop() }
            announceIfReady()
        default:
            return
        }
    }

    private func announceIfReady() {
        guard !announced, accepted, setUp else { return }
        announced = true
        continuation.yield(.ready(geometry: KiwiWaterfallGeometry(bandwidthHz: bandwidthHz, fftSize: fftSize,
                                                                  zoomMax: zoomMax),
                                  cal: cal))
    }

    // MARK: - Sending

    private func send(_ text: String, log: Bool = true, shownAs: String? = nil) {
        guard let socket, !finished else { return }
        if log { logger.debug("waterfall: send \(shownAs ?? text, privacy: .public)") }
        socket.send(.string(text)) { [logger] error in
            if let error { logger.debug("waterfall: send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func keepaliveLoop() async {
        while !finished, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            send(KiwiProtocol.keepalive, log: false)
        }
    }

    private func watchdog() async {
        while !finished, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !finished, !Task.isCancelled else { return }
            if ContinuousClock.now - lastFrame > Self.silenceTimeout {
                logger.error("waterfall: nothing from the Kiwi for \(Self.silenceTimeout, privacy: .public)")
                finish(.noResponse)
                return
            }
        }
    }

    private func finish(_ error: KiwiSDRError?) {
        guard !finished else { return }
        finished = true
        if let error { logger.notice("waterfall: ended: \(String(describing: error), privacy: .public)") }
        keepaliveTask?.cancel()
        watchdogTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        continuation.yield(.closed(error))
        continuation.finish()
    }
}

import Foundation
import os

/// What a KiwiSDR demodulates: mode, passband (Hz relative to the
/// carrier, negative below it) and the dial frequency.
public struct KiwiTuning: Equatable, Sendable {
    public var dialHz: Int
    public var mode: KiwiSDRMode
    public var lowCut: Int
    public var highCut: Int

    public init(dialHz: Int, mode: KiwiSDRMode, lowCut: Int? = nil, highCut: Int? = nil) {
        self.dialHz = dialHz
        self.mode = mode
        self.lowCut = lowCut ?? mode.defaultPassband.low
        self.highCut = highCut ?? mode.defaultPassband.high
    }

    var command: String {
        KiwiProtocol.tune(carrierHz: mode.carrierHz(forDialHz: dialHz, lowCut: lowCut, highCut: highCut),
                          mode: mode, lowCut: lowCut, highCut: highCut)
    }
}

/// Why a session couldn't start or ended.
public enum KiwiSDRError: Error, Equatable, Sendable {
    /// The host field can't be made into a URL.
    case invalidHost
    /// The Kiwi refused the password (badp=1 with free channels left).
    case badPassword
    /// Every receiver channel is in use (too_busy, or badp=1 with none free).
    case busy
    /// The Kiwi says it's down (its "down" message).
    case down
    /// The Kiwi redirected this client elsewhere; not followed.
    case redirect(String)
    /// Another badp code (kiwiclient's list: 2 still starting, 3/4/7 admin,
    /// 5 no second connection from this address, 6 database update).
    case refused(code: Int)
    /// Couldn't connect, or the connection dropped (the system's text).
    case unreachable(String)
    /// Connected, but no audio arrived for `KiwiSDRClient.silenceTimeout`.
    case noResponse
}

/// One KiwiSDR sound stream (`/<timestamp>/SND`) over
/// `URLSessionWebSocketTask`: auth, the setup sequence kiwiclient and the
/// Kiwi's own page send, a keepalive every second, retuning on the open
/// socket, and a clean close (which frees the Kiwi's channel). One session
/// per instance — make a new one to reconnect. Events come out of `events`
/// in order. Never logs the password.
public actor KiwiSDRClient {
    public enum Event: Sendable {
        /// The Kiwi accepted us and reported its real audio rate
        /// (e.g. 11998.902088 Hz, not 12000 — resample from this).
        case ready(sampleRate: Double)
        case audio(KiwiAudioChunk)
        /// The session ended: nil after `stop()`, else why.
        case closed(KiwiSDRError?)
    }

    public static let silenceTimeout: Duration = .seconds(10)

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let hostPort: String
    private let password: String
    private let identUser: String
    private let compression: Bool
    private let timestamp: Date
    private var tuning: KiwiTuning
    private let logger: Logger

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var sampleRate: Double?
    private var setUp = false
    private var accepted = false
    private var finished = false
    private var lastFrame = ContinuousClock.now
    private var decoder = KiwiSoundDecoder()

    public init(hostPort: String, password: String, identUser: String = "FTX1Remote",
                compression: Bool = false, tuning: KiwiTuning, timestamp: Date = Date(),
                logSubsystem: String) {
        self.hostPort = hostPort
        self.timestamp = timestamp
        self.password = password
        self.identUser = identUser
        self.compression = compression
        self.tuning = tuning
        self.logger = Logger(subsystem: logSubsystem, category: "kiwisdr")
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public func start() {
        guard socket == nil, !finished else { return }
        guard let url = KiwiProtocol.soundURL(hostPort: hostPort, timestamp: timestamp) else {
            finish(.invalidHost)
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16 << 20   // load_cfg is large
        self.session = session
        self.socket = socket
        logger.notice("connecting to \(url.absoluteString, privacy: .public)")
        socket.resume()
        lastFrame = .now
        // Sent at once; URLSession queues it until the socket opens.
        send(KiwiProtocol.auth(password: password), shownAs: "SET auth t=kiwi p=…")
        receiveTask = Task { await self.receiveLoop(socket) }
        watchdogTask = Task { await self.watchdog() }
    }

    /// Closes the socket (the Kiwi frees the channel) and ends `events`.
    public func stop() {
        guard !finished else { return }
        logger.notice("stop()")
        finish(nil)
    }

    /// Retunes on the open socket — no reconnect. Before setup it only
    /// changes what setup will send.
    public func tune(_ newTuning: KiwiTuning) {
        tuning = newTuning
        if setUp { send(newTuning.command) }
    }

    public func tune(frequencyHz: Int, mode: KiwiSDRMode, lowCut: Int? = nil, highCut: Int? = nil) {
        tune(KiwiTuning(dialHz: frequencyHz, mode: mode, lowCut: lowCut, highCut: highCut))
    }

    // MARK: - Receiving

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !finished, !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                guard !finished else { return }
                logger.error("receive failed: \(error.localizedDescription, privacy: .public)")
                // A badp=1 makes the Kiwi close right after; that close
                // isn't the reason.
                finish(.unreachable(error.localizedDescription))
                return
            }
            lastFrame = .now
            switch message {
            case .data(let data):
                await handle(data)
            case .string(let text):
                await handle(Data(text.utf8))
            @unknown default:
                break
            }
        }
    }

    private func handle(_ data: Data) async {
        switch KiwiProtocol.parseFrame(data) {
        case .message(let items):
            for item in items { await handle(item) }
        case .sound(let frame):
            guard let sampleRate else { return }
            let samples = decoder.samples(from: frame)
            guard !samples.isEmpty else { return }
            continuation.yield(.audio(KiwiAudioChunk(samples: samples, sampleRate: sampleRate,
                                                     smeterDBm: frame.smeterDBm, flags: frame.flags,
                                                     sequence: frame.sequence)))
        case .waterfall, .other, nil:
            break
        }
    }

    private func handle(_ item: KiwiMessageItem) async {
        guard !finished else { return }
        switch item.name {
        case "load_cfg", "load_dxcfg", "load_dxcomm_cfg":
            return   // large, unused
        case "badp":
            let code = Int(item.value ?? "") ?? -1
            logger.notice("badp=\(code)")
            switch code {
            case 0:
                accepted = true
                announceIfReady()
            case 1:
                // "Bad password OR all channels busy that don't require a
                // password" — /status tells the two apart.
                finish(await Self.channelsFull(hostPort: hostPort) ? .busy : .badPassword)
            default:
                finish(.refused(code: code))
            }
        case "too_busy":
            logger.notice("too_busy=\(item.value ?? "", privacy: .public)")
            finish(.busy)
        case "down":
            finish(.down)
        case "redirect":
            finish(.redirect(item.value ?? ""))
        case "audio_rate":
            if let rate = Double(item.value ?? "") {
                send(KiwiProtocol.audioRateOK(inRate: Int(rate.rounded())))
            }
        case "sample_rate":
            guard let rate = Double(item.value ?? ""), rate > 0 else { return }
            logger.notice("sample_rate=\(rate, privacy: .public)")
            sampleRate = rate
            if !setUp {
                setUp = true
                for command in KiwiProtocol.setupCommands(identUser: identUser, compression: compression) {
                    send(command)
                }
                send(tuning.command)
                send(KiwiProtocol.keepalive, log: false)
                keepaliveTask = Task { await self.keepaliveLoop() }
            }
            announceIfReady()
        default:
            return
        }
    }

    private var announced = false
    private func announceIfReady() {
        guard !announced, accepted, let sampleRate else { return }
        announced = true
        continuation.yield(.ready(sampleRate: sampleRate))
    }

    // MARK: - Sending

    /// `shownAs` replaces the text in the log (the auth command);
    /// `log: false` skips it (keepalives).
    private func send(_ text: String, log: Bool = true, shownAs: String? = nil) {
        guard let socket, !finished else { return }
        if log { logger.debug("send \(shownAs ?? text, privacy: .public)") }
        socket.send(.string(text)) { [logger] error in
            if let error { logger.debug("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func keepaliveLoop() async {
        while !finished, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            send(KiwiProtocol.keepalive, log: false)
        }
    }

    /// No answer at all (a host that accepts TCP and says nothing), or
    /// audio stopping mid-session.
    private func watchdog() async {
        while !finished, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !finished, !Task.isCancelled else { return }
            if ContinuousClock.now - lastFrame > Self.silenceTimeout {
                logger.error("nothing from the Kiwi for \(Self.silenceTimeout, privacy: .public)")
                finish(.noResponse)
                return
            }
        }
    }

    private func finish(_ error: KiwiSDRError?) {
        guard !finished else { return }
        finished = true
        if let error { logger.notice("session ended: \(String(describing: error), privacy: .public)") }
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

    // MARK: - /status

    /// Whether the Kiwi's /status shows every channel in use. false if it
    /// can't be read.
    static func channelsFull(hostPort: String) async -> Bool {
        guard let sound = KiwiProtocol.soundURL(hostPort: hostPort),
              var components = URLComponents(url: sound, resolvingAgainstBaseURL: false) else { return false }
        components.scheme = "http"
        components.path = "/status"
        guard let url = components.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        let status = KiwiStatus(String(decoding: data, as: UTF8.self))
        guard let users = status.users, let max = status.usersMax else { return false }
        return users >= max
    }
}

public struct KiwiAudioChunk: Sendable {
    /// Mono samples at `sampleRate`.
    public let samples: [Int16]
    public let sampleRate: Double
    public let smeterDBm: Double
    public let flags: KiwiSoundFrame.Flags
    public let sequence: UInt32
}

/// The Kiwi's plain-text /status page ("users=1\nusers_max=4\n…").
public struct KiwiStatus: Equatable, Sendable {
    public let values: [String: String]

    public init(_ text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        self.values = values
    }

    public var users: Int? { values["users"].flatMap { Int($0) } }
    public var usersMax: Int? { values["users_max"].flatMap { Int($0) } }
}

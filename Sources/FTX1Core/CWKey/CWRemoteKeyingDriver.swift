import Foundation
import Network
import os

/// Straight key in Remote mode: the rig's keying port is on the Pi, so
/// the key interface's events are forwarded — device timestamps untouched —
/// to the Pi's `ftx1-cwkey.py` (TCP 8534), which does the clock sync,
/// playout and line toggling there. Network jitter then lands before the
/// playout buffer, not after it.
///
/// This side keeps the hub's own gates: the session with the Pi exists
/// only while armed, the key interface is connected and nothing blocks
/// transmitting (`setBlockReason`). Losing any of them sends `cw_bye` and
/// closes the connection, and the Pi keys up at once. If this app dies or
/// the network goes, the Pi keys up on the closed socket or after its
/// heartbeat timeout. Events that arrive before the Pi has the session
/// (`cw_hello`) are dropped, so a key held while connecting never keys
/// — the Pi waits for a fresh key-down, like the local latch.
public final class CWRemoteKeyingDriver: CWKeyingDriving, @unchecked Sendable {
    public struct Settings: Sendable {
        public var line: CWKeyingLine
        public var invertedPolarity: Bool
        public var playoutDelay: Double
        public var heartbeatTimeout: Double
        public var maxKeyDown: Double

        public init(line: CWKeyingLine, invertedPolarity: Bool, playoutDelay: Double,
                    heartbeatTimeout: Double, maxKeyDown: Double) {
            self.line = line
            self.invertedPolarity = invertedPolarity
            self.playoutDelay = playoutDelay
            self.heartbeatTimeout = heartbeatTimeout
            self.maxKeyDown = maxKeyDown
        }
    }

    public static let defaultPort: UInt16 = 8534
    public var retryInterval: Double = 2.0

    private let queue = DispatchQueue(label: "com.ftx1remote.cw-remote-keying", qos: .userInteractive)
    private let source: CWKeySource
    private let host: String
    private let port: UInt16
    private let clientID: String
    private let onSnapshot: @Sendable (CWKeyingDriver.Snapshot) -> Void
    private let logger: Logger

    // Queue-confined.
    private var settings: Settings
    private var link: CWKeyLinkState = .closed
    private var armed = false
    private var blockReason: String?
    private var operatorKeyDown = false
    private var deviceStatus: CWKeyDeviceStatus?
    private var connection: NWConnection?
    private var connectionReady = false
    private var connectionError: String?
    private var piStatus: CWKeyWire.Status?
    private var seq: UInt32 = 0
    private var receiveBuffer = Data()
    private var retryPending = false
    private var consumer: Task<Void, Never>?
    private var shutDown = false
    private var lastSnapshot: CWKeyingDriver.Snapshot?
    /// RF feedback check on the operator's events (`CWFeedbackDetector`):
    /// a trip disarms, which ends the Pi session (key-up there).
    private var deviceClock = CWDeviceClockUnwrapper()
    private var feedback: CWFeedbackDetector
    private var feedbackMessage: String?

    public init(source: CWKeySource, host: String, port: UInt16 = defaultPort, clientID: String,
                settings: Settings, logSubsystem: String,
                onSnapshot: @escaping @Sendable (CWKeyingDriver.Snapshot) -> Void) {
        self.source = source
        self.host = host
        self.port = port
        self.clientID = clientID
        self.settings = settings
        self.onSnapshot = onSnapshot
        feedback = CWFeedbackDetector(loopDelay: settings.playoutDelay)
        logger = Logger(subsystem: logSubsystem, category: "cw-key")
    }

    public func start() {
        queue.async { [self] in
            guard consumer == nil, !shutDown else { return }
            let events = source.events
            consumer = Task.detached(priority: .high) { [weak self] in
                for await event in events {
                    self?.queue.async { self?.ingest(event) }
                }
            }
            source.start()
            publish()
        }
    }

    public func setArmed(_ armed: Bool) {
        queue.async { [self] in
            self.armed = armed
            if armed {
                feedback.reset()
                feedbackMessage = nil
            }
            logger.notice("\(armed ? "armed" : "disarmed", privacy: .public) (Pi keyer \(self.host, privacy: .public))")
            reconcile()
        }
    }

    public func setBlockReason(_ reason: String?) {
        queue.async { [self] in
            blockReason = reason
            reconcile()
        }
    }

    /// Applies at the next session (the Pi takes them in `cw_hello`).
    public func setSettings(_ settings: Settings) {
        queue.async { [self] in
            self.settings = settings
            feedback.loopDelay = settings.playoutDelay
            if connectionReady { sendHello() }
        }
    }

    public func setPlayoutDelay(_ seconds: Double) {
        queue.async { [self] in
            settings.playoutDelay = seconds
            feedback.loopDelay = seconds
            if connectionReady { sendHello() }
        }
    }

    public func setMaxKeyDown(_ seconds: Double) {
        queue.async { [self] in
            settings.maxKeyDown = seconds
            if connectionReady { sendHello() }
        }
    }

    /// Sends `cw_bye` and waits (up to 0.5 s) for it to go out, so the Pi
    /// keys up at once rather than on its heartbeat timeout.
    public func shutdown() {
        let sent = queue.sync {
            shutDown = true
            armed = false
            let sent = closeSession(reason: "shutting down")
            consumer?.cancel()
            consumer = nil
            source.stop()
            return sent
        }
        _ = sent?.wait(timeout: .now() + 0.5)
    }

    // MARK: - Queue-confined

    private var wanted: Bool {
        !shutDown && armed && blockReason == nil && link.isConnected
    }

    private func reconcile() {
        if wanted, connection == nil, !retryPending {
            connect()
        } else if !wanted, connection != nil {
            closeSession(reason: blockReason ?? (armed ? "key interface not connected" : "disarmed"))
        }
        publish()
    }

    private func connect() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let newConnection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        connection = newConnection
        connectionReady = false
        connectionError = nil
        piStatus = nil
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            self.connectionStateChanged(newConnection, state)
        }
        newConnection.start(queue: queue)
        logger.info("connecting to \(self.host, privacy: .public):\(self.port)")
    }

    private func connectionStateChanged(_ changed: NWConnection, _ state: NWConnection.State) {
        guard changed === connection else { return }
        switch state {
        case .ready:
            connectionReady = true
            logger.notice("connected to the Pi keyer")
            sendHello()
            receive(on: changed)
        case .waiting(let error), .failed(let error):
            dropped("Pi keyer: \(error.localizedDescription)")
        case .cancelled:
            break
        default:
            break
        }
        publish()
    }

    private func dropped(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        connection?.cancel()
        connection = nil
        connectionReady = false
        connectionError = message
        piStatus = nil
        guard wanted else { return }
        retryPending = true
        queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            guard let self else { return }
            self.retryPending = false
            self.reconcile()
        }
    }

    private func receive(on receiving: NWConnection) {
        receiving.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, receiving === self.connection else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.parseStatuses()
            }
            if isComplete || error != nil {
                self.dropped(error.map { "Pi keyer: \($0.localizedDescription)" } ?? "Pi keyer closed the connection")
                self.publish()
                return
            }
            self.receive(on: receiving)
        }
    }

    private func parseStatuses() {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer[receiveBuffer.startIndex..<newline]
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newline)
            guard let status = try? JSONDecoder().decode(CWKeyWire.Status.self, from: Data(line)),
                  status.type == "cw_status" else { continue }
            if status.error != piStatus?.error, let error = status.error {
                logger.error("Pi keyer: \(error, privacy: .public)")
            }
            piStatus = status
            publish()
        }
        if receiveBuffer.count > 4096 { receiveBuffer.removeAll() }
    }

    private func sendHello() {
        seq = 0
        send(CWKeyWire.Hello(
            seq: seq, id: clientID, line: settings.line.rawValue, inverted: settings.invertedPolarity,
            playoutDelayMs: Int((settings.playoutDelay * 1000).rounded()),
            heartbeatTimeoutMs: Int((settings.heartbeatTimeout * 1000).rounded()),
            maxKeyDownMs: Int((settings.maxKeyDown * 1000).rounded())))
    }

    private func nextSeq() -> UInt32 {
        seq &+= 1
        return seq
    }

    private func send<Message: Encodable>(_ message: Message) {
        guard let connection, connectionReady else { return }
        connection.send(content: CWKeyWire.line(message), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            self?.queue.async { self?.dropped("Pi keyer: \(error.localizedDescription)") }
        })
    }

    /// Ends the session: `cw_bye` as the stream's last data (a FIN follows
    /// it — the Pi keys up on either), then the connection is cancelled
    /// once that's out. Returns a semaphore signalled then, nil if there
    /// was nothing to send.
    @discardableResult
    private func closeSession(reason: String) -> DispatchSemaphore? {
        guard let connection else { return nil }
        logger.notice("session closed: \(reason, privacy: .public)")
        self.connection = nil
        piStatus = nil
        guard connectionReady else {
            connection.cancel()
            return nil
        }
        connectionReady = false
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: CWKeyWire.line(CWKeyWire.Bye(seq: nextSeq())), isComplete: true,
                        completion: .contentProcessed { _ in
                            connection.cancel()
                            sent.signal()
                        })
        return sent
    }

    private func ingest(_ event: CWKeySourceEvent) {
        guard !shutDown else { return }
        switch event {
        case .link(let state):
            link = state
            if !state.isConnected { operatorKeyDown = false }
            reconcile()
        case .line(let line, _):
            switch line {
            case .banner:
                operatorKeyDown = false
                deviceClock.reset()
                feedback.clearHistory()
                if connectionReady { sendHello() }   // device restarted: new session on the Pi
            case .keyDown(let ms):
                operatorKeyDown = true
                send(CWKeyWire.Key(seq: nextSeq(), t: ms, down: true))
                checkFeedback(down: true, ms: ms)
            case .keyUp(let ms):
                operatorKeyDown = false
                send(CWKeyWire.Key(seq: nextSeq(), t: ms, down: false))
                checkFeedback(down: false, ms: ms)
            case .heartbeat(let ms):
                _ = deviceClock.unwrap(ms)
                send(CWKeyWire.Heartbeat(seq: nextSeq(), t: ms))
            case .status(let status):
                deviceStatus = status
                feedback.keyerWPM = status.wpm
            }
            publish()
        }
    }

    private func checkFeedback(down: Bool, ms: UInt32) {
        let unwrapped = deviceClock.unwrap(ms)
        if unwrapped.restarted { feedback.clearHistory() }
        guard armed, feedback.operatorChanged(down: down, at: Double(unwrapped.ms) / 1000) else { return }
        logger.error("RF feedback detected: the key input is following the rig's own keying — disarmed")
        feedbackMessage = CWKeyingDriver.feedbackMessage
        armed = false
        reconcile()   // cw_bye: the Pi keys up
    }

    private func publish() {
        var snapshot = CWKeyingDriver.Snapshot()
        snapshot.link = link
        snapshot.armed = armed
        snapshot.operatorKeyDown = operatorKeyDown
        snapshot.deviceStatus = deviceStatus
        snapshot.keyed = connectionReady && (piStatus?.keyed ?? false)
        if !armed {
            snapshot.cutoff = .disarmed
        } else if !link.isConnected {
            snapshot.cutoff = .linkDown
        } else if let blockReason {
            snapshot.cutoff = .blocked(blockReason)
        } else if !connectionReady || piStatus == nil {
            snapshot.cutoff = .remote(connectionError ?? "Connecting to the Pi keyer…")
        } else if let cutoff = piStatus?.cutoff {
            snapshot.cutoff = .remote(cutoff)
        }
        snapshot.latch = piStatus?.latched.map { .remote($0) }
        snapshot.keyerError = feedbackMessage ?? piStatus?.error ?? (armed ? connectionError : nil)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshot(snapshot)
    }
}

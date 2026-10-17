import Network
import XCTest
@testable import FTX1Core

/// `CWRemoteKeyingDriver` against a fake Pi keyer (an `NWListener` that
/// records the JSON lines and answers `cw_hello` with a `cw_status`).
final class CWRemoteKeyingDriverTests: XCTestCase {
    final class FakePi: @unchecked Sendable {
        private let queue = DispatchQueue(label: "fake-pi")
        private let listener: NWListener
        private let lock = NSLock()
        private var _messages: [[String: Any]] = []
        private var _connections = 0
        private var _closed = 0
        private var current: NWConnection?
        var port: UInt16 { listener.port?.rawValue ?? 0 }

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 2)
        }

        deinit { listener.cancel() }

        var messages: [[String: Any]] { lock.withLock { _messages } }
        var types: [String] { messages.compactMap { $0["type"] as? String } }
        var connections: Int { lock.withLock { _connections } }
        var closed: Int { lock.withLock { _closed } }

        func sendStatus(keyed: Bool, cutoff: String? = nil, latched: String? = nil, error: String? = nil) {
            let status: [String: Any?] = ["type": "cw_status", "armed": true, "keyed": keyed, "holder": true,
                                          "cutoff": cutoff, "latched": latched, "error": error, "playoutDelayMs": 300]
            var data = try! JSONSerialization.data(withJSONObject: status.mapValues { $0 ?? NSNull() })
            data.append(0x0A)
            queue.async { self.current?.send(content: data, completion: .idempotent) }
        }

        private func accept(_ connection: NWConnection) {
            lock.withLock { _connections += 1 }
            current = connection
            connection.start(queue: queue)
            read(connection, buffer: Data())
        }

        private func read(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
                guard let self else { return }
                var buffer = buffer + (data ?? Data())
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                        self.lock.withLock { self._messages.append(object) }
                        if object["type"] as? String == "cw_hello" { self.sendStatus(keyed: false) }
                    }
                }
                if done || error != nil {
                    self.lock.withLock { self._closed += 1 }
                    connection.cancel()
                    return
                }
                self.read(connection, buffer: buffer)
            }
        }
    }

    final class FakeSource: CWKeySource, @unchecked Sendable {
        let events: AsyncStream<CWKeySourceEvent>
        let continuation: AsyncStream<CWKeySourceEvent>.Continuation
        init() { (events, continuation) = AsyncStream.makeStream(of: CWKeySourceEvent.self) }
        func start() {}
        func stop() {}
        func send(_ event: CWKeySourceEvent) { continuation.yield(event) }
    }

    final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var _last = CWKeyingDriver.Snapshot()
        var last: CWKeyingDriver.Snapshot { lock.withLock { _last } }
        func set(_ value: CWKeyingDriver.Snapshot) { lock.withLock { _last = value } }
    }

    private func waitUntil(timeout: Double = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    private let settings = CWRemoteKeyingDriver.Settings(
        line: .dtr, invertedPolarity: false, playoutDelay: 0.3, heartbeatTimeout: 1.0, maxKeyDown: 5)

    private func make(_ pi: FakePi) -> (CWRemoteKeyingDriver, FakeSource, Snapshots) {
        let source = FakeSource()
        let snapshots = Snapshots()
        let driver = CWRemoteKeyingDriver(source: source, host: "127.0.0.1", port: pi.port, clientID: "test",
                                          settings: settings, logSubsystem: "com.ftx1remote.tests",
                                          onSnapshot: { snapshots.set($0) })
        driver.retryInterval = 0.2
        driver.start()
        source.send(.link(.connected(deviceID: "FTX1CW", version: 1)))
        return (driver, source, snapshots)
    }

    func testNoSessionUntilArmed() throws {
        let pi = try FakePi()
        let (driver, _, snapshots) = make(pi)
        defer { driver.shutdown() }
        usleep(200_000)
        XCTAssertEqual(pi.connections, 0)
        XCTAssertEqual(snapshots.last.cutoff, .disarmed)
    }

    func testArmSendsHelloWithSettingsThenForwardsDeviceTimes() throws {
        let pi = try FakePi()
        let (driver, source, snapshots) = make(pi)
        defer { driver.shutdown() }
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.types == ["cw_hello"] })
        let hello = pi.messages[0]
        XCTAssertEqual(hello["line"] as? String, "DTR")
        XCTAssertEqual(hello["playoutDelayMs"] as? Int, 300)
        XCTAssertEqual(hello["heartbeatTimeoutMs"] as? Int, 1000)
        XCTAssertEqual(hello["maxKeyDownMs"] as? Int, 5000)
        XCTAssertEqual(hello["version"] as? Int, 1)
        XCTAssertTrue(waitUntil { snapshots.last.cutoff == nil })

        source.send(.line(.heartbeat(deviceMs: UInt32.max - 5), hostReceived: 0))
        source.send(.line(.keyDown(deviceMs: 4), hostReceived: 0))
        source.send(.line(.keyUp(deviceMs: 64), hostReceived: 0))
        XCTAssertTrue(waitUntil { pi.messages.count == 4 })
        let rest = Array(pi.messages.dropFirst())
        XCTAssertEqual(rest.map { $0["type"] as? String }, ["cw_hb", "cw", "cw"])
        XCTAssertEqual(rest.map { $0["seq"] as? Int }, [1, 2, 3])
        XCTAssertEqual(rest.map { ($0["t"] as? NSNumber)?.uint32Value }, [UInt32.max - 5, 4, 64])
        XCTAssertEqual(rest.map { $0["state"] as? String }, [nil, "down", "up"])
    }

    func testShowsThePiLineAndCutoffs() throws {
        let pi = try FakePi()
        let (driver, _, snapshots) = make(pi)
        defer { driver.shutdown() }
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.types == ["cw_hello"] })
        pi.sendStatus(keyed: true)
        XCTAssertTrue(waitUntil { snapshots.last.keyed })
        pi.sendStatus(keyed: false, latched: "Key held too long — release the key")
        XCTAssertTrue(waitUntil { snapshots.last.latch == .remote("Key held too long — release the key") })
        XCTAssertFalse(snapshots.last.keyed)
    }

    func testBlockSendsByeAndClosesThenReopens() throws {
        let pi = try FakePi()
        let (driver, _, snapshots) = make(pi)
        defer { driver.shutdown() }
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.types == ["cw_hello"] })
        driver.setBlockReason("Transmit disabled")
        XCTAssertTrue(waitUntil { pi.types.last == "cw_bye" && pi.closed == 1 })
        XCTAssertEqual(snapshots.last.cutoff, .blocked("Transmit disabled"))
        driver.setBlockReason(nil)
        XCTAssertTrue(waitUntil { pi.connections == 2 && pi.types.last == "cw_hello" })
    }

    func testDisarmAndLinkLossClose() throws {
        let pi = try FakePi()
        let (driver, source, _) = make(pi)
        defer { driver.shutdown() }
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.connections == 1 })
        driver.setArmed(false)
        XCTAssertTrue(waitUntil { pi.closed == 1 })

        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.connections == 2 })
        source.send(.link(.failed("Key interface disconnected")))
        XCTAssertTrue(waitUntil { pi.closed == 2 })
    }

    func testDeviceRestartStartsANewSessionOnThePi() throws {
        let pi = try FakePi()
        let (driver, source, _) = make(pi)
        defer { driver.shutdown() }
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.types == ["cw_hello"] })
        source.send(.line(.heartbeat(deviceMs: 5000), hostReceived: 0))
        source.send(.line(.banner(id: "FTX1CW", version: 1), hostReceived: 0))
        XCTAssertTrue(waitUntil { pi.types == ["cw_hello", "cw_hb", "cw_hello"] })
        XCTAssertEqual(pi.messages[2]["seq"] as? Int, 0)
    }

    func testRetriesWhenThePiIsntThere() throws {
        // Port 1 on loopback: refused.
        let source = FakeSource()
        let snapshots = Snapshots()
        let driver = CWRemoteKeyingDriver(source: source, host: "127.0.0.1", port: 1, clientID: "test",
                                          settings: settings, logSubsystem: "com.ftx1remote.tests",
                                          onSnapshot: { snapshots.set($0) })
        defer { driver.shutdown() }
        driver.start()
        source.send(.link(.connected(deviceID: "FTX1CW", version: 1)))
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { snapshots.last.keyerError != nil })
        if case .remote = snapshots.last.cutoff {} else { XCTFail("cutoff \(String(describing: snapshots.last.cutoff))") }
        XCTAssertFalse(snapshots.last.keyed)
    }

    /// Machine-steady marks at the Remote loop period: the Mac disarms,
    /// which ends the Pi session with a bye.
    func testRFFeedbackDisarmsAndEndsThePiSession() throws {
        let pi = try FakePi()
        let (driver, source, snapshots) = make(pi)
        defer { driver.shutdown() }
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.types == ["cw_hello"] })
        for index in 0..<7 {
            let start = UInt32(10_000 + index * 310)
            source.send(.line(.keyDown(deviceMs: start), hostReceived: 0))
            source.send(.line(.keyUp(deviceMs: start + 190), hostReceived: 0))
        }
        XCTAssertTrue(waitUntil { pi.types.last == "cw_bye" && pi.closed == 1 })
        XCTAssertFalse(snapshots.last.armed)
        XCTAssertEqual(snapshots.last.keyerError, CWKeyingDriver.feedbackMessage)
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.connections == 2 && snapshots.last.keyerError == nil })
    }

    func testShutdownSendsBye() throws {
        let pi = try FakePi()
        let (driver, _, _) = make(pi)
        driver.setArmed(true)
        XCTAssertTrue(waitUntil { pi.types == ["cw_hello"] })
        driver.shutdown()
        XCTAssertTrue(waitUntil { pi.closed == 1 })
        XCTAssertEqual(pi.types.last, "cw_bye")
    }
}

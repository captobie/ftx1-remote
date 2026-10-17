#if os(macOS)
import Darwin
import XCTest
@testable import FTX1Core

/// `SerialCWKeySource` against a pseudo-terminal standing in for the
/// Arduino, and `CWKeyingDriver` in real time with a fake source and
/// keyer.
final class CWKeyingDriverTests: XCTestCase {
    // MARK: - Fakes

    final class FakeSource: CWKeySource, @unchecked Sendable {
        let events: AsyncStream<CWKeySourceEvent>
        let continuation: AsyncStream<CWKeySourceEvent>.Continuation
        init() { (events, continuation) = AsyncStream.makeStream(of: CWKeySourceEvent.self) }
        func start() {}
        func stop() {}
        func send(_ event: CWKeySourceEvent) { continuation.yield(event) }
    }

    final class FakeKeyer: CWKeyer, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(keyed: Bool, at: Double)] = []
        private(set) var opened = false
        private(set) var closed = false
        var failNextSet = false
        let clock = CWMonotonicClock()
        var calls: [(keyed: Bool, at: Double)] { lock.withLock { _calls } }
        var isKeyed: Bool { lock.withLock { _calls.last?.keyed ?? false } }
        func open() throws { lock.withLock { opened = true } }
        func setKeyed(_ keyed: Bool) throws {
            try lock.withLock {
                if failNextSet { failNextSet = false; throw SerialPortError.closed }
                _calls.append((keyed, clock.now()))
            }
        }
        func close() { lock.withLock { closed = true } }
    }

    private func waitUntil(timeout: Double = 2, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(2_000)
        }
        return condition()
    }

    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _last: CWKeyingDriver.Snapshot?
        var last: CWKeyingDriver.Snapshot? { lock.withLock { _last } }
        func set(_ value: CWKeyingDriver.Snapshot) { lock.withLock { _last = value } }
    }

    /// A driver armed with a fake keyer, the fake device connected and
    /// heartbeating. The heartbeat thread runs until `stopHeartbeats`.
    private struct Rig {
        let source: FakeSource
        let keyer: FakeKeyer
        let driver: CWKeyingDriver
        let snapshots: SnapshotBox
        let deviceStart: Double
        let clock = CWMonotonicClock()
        let heartbeats: Thread

        func deviceMs() -> UInt32 { UInt32((clock.now() - deviceStart) * 1000) }
        func key(_ down: Bool) {
            let ms = deviceMs()
            source.send(.line(down ? .keyDown(deviceMs: ms) : .keyUp(deviceMs: ms), hostReceived: clock.now()))
        }
    }

    private func makeRig(playoutDelay: Double = 0.1) -> Rig {
        let source = FakeSource()
        let keyer = FakeKeyer()
        let snapshots = SnapshotBox()
        let driver = CWKeyingDriver(source: source, engine: CWStraightKeyEngine(playoutDelay: playoutDelay),
                                    logSubsystem: "com.ftx1remote.tests", makeKeyer: { keyer },
                                    onSnapshot: { snapshots.set($0) })
        driver.start()
        driver.setArmed(true)
        let clock = CWMonotonicClock()
        let start = clock.now()
        source.send(.link(.connected(deviceID: "FTX1CW", version: 1)))
        source.send(.line(.banner(id: "FTX1CW", version: 1), hostReceived: clock.now()))
        let heartbeats = Thread {
            while !Thread.current.isCancelled {
                source.send(.line(.heartbeat(deviceMs: UInt32((clock.now() - start) * 1000)), hostReceived: clock.now()))
                usleep(250_000)
            }
        }
        heartbeats.start()
        usleep(50_000)
        return Rig(source: source, keyer: keyer, driver: driver, snapshots: snapshots, deviceStart: start, heartbeats: heartbeats)
    }

    // MARK: - Driver

    func testKeysWithTheKeyedTimingAfterThePlayoutDelay() {
        let rig = makeRig(playoutDelay: 0.1)
        defer { rig.heartbeats.cancel(); rig.driver.shutdown() }
        XCTAssertTrue(rig.keyer.opened)
        let pressed = rig.clock.now()
        rig.key(true)
        usleep(60_000)
        rig.key(false)
        XCTAssertTrue(waitUntil { rig.keyer.calls.count >= 2 })
        let calls = rig.keyer.calls
        XCTAssertEqual(calls.map(\.keyed), [true, false])
        XCTAssertEqual(calls[0].at - pressed, 0.1, accuracy: 0.015, "playout delay")
        XCTAssertEqual(calls[1].at - calls[0].at, 0.060, accuracy: 0.008, "element length kept")
    }

    func testLinkLossReleasesAtOnce() {
        let rig = makeRig()
        defer { rig.heartbeats.cancel(); rig.driver.shutdown() }
        rig.key(true)
        XCTAssertTrue(waitUntil { rig.keyer.isKeyed })
        let lost = rig.clock.now()
        rig.source.send(.link(.failed("Key interface disconnected")))
        XCTAssertTrue(waitUntil { !rig.keyer.isKeyed })
        XCTAssertLessThan(rig.keyer.calls.last!.at - lost, 0.02)
    }

    func testMissedHeartbeatsRelease() {
        let rig = makeRig()
        defer { rig.driver.shutdown() }
        rig.key(true)
        XCTAssertTrue(waitUntil { rig.keyer.isKeyed })
        rig.heartbeats.cancel()
        let stopped = rig.clock.now()
        XCTAssertTrue(waitUntil { !rig.keyer.isKeyed })
        // The last line was heard ≤ 250 ms before; cut off 500 ms after it.
        XCTAssertLessThan(rig.keyer.calls.last!.at - stopped, 0.55)
        XCTAssertTrue(waitUntil { rig.snapshots.last?.latch == .heartbeatTimeout })
    }

    func testDisarmReleasesAndClosesThePort() {
        let rig = makeRig()
        defer { rig.heartbeats.cancel(); rig.driver.shutdown() }
        rig.key(true)
        XCTAssertTrue(waitUntil { rig.keyer.isKeyed })
        rig.driver.setArmed(false)
        XCTAssertTrue(waitUntil { rig.keyer.closed })
        XCTAssertFalse(rig.keyer.isKeyed)
    }

    func testTransmitBlockReleases() {
        let rig = makeRig()
        defer { rig.heartbeats.cancel(); rig.driver.shutdown() }
        rig.key(true)
        XCTAssertTrue(waitUntil { rig.keyer.isKeyed })
        rig.driver.setBlockReason("Transmit disabled")
        XCTAssertTrue(waitUntil { !rig.keyer.isKeyed })
    }

    func testMaxKeyDownReleases() {
        let rig = makeRig()
        defer { rig.heartbeats.cancel(); rig.driver.shutdown() }
        rig.driver.setMaxKeyDown(0.3)
        rig.key(true)
        XCTAssertTrue(waitUntil { rig.keyer.isKeyed })
        let keyedAt = rig.keyer.calls.last!.at
        XCTAssertTrue(waitUntil { !rig.keyer.isKeyed })
        XCTAssertEqual(rig.keyer.calls.last!.at - keyedAt, 0.3, accuracy: 0.02)
        XCTAssertTrue(waitUntil { rig.snapshots.last?.latch == .maxKeyDown })
    }

    func testKeyerFailureStopsKeyingUntilRearmed() {
        let rig = makeRig()
        defer { rig.heartbeats.cancel(); rig.driver.shutdown() }
        rig.keyer.failNextSet = true
        rig.key(true)
        XCTAssertTrue(waitUntil { rig.keyer.closed })
        XCTAssertTrue(waitUntil { rig.snapshots.last?.keyerError != nil })
        XCTAssertEqual(rig.snapshots.last?.cutoff, .keyerUnavailable)
    }

    func testShutdownReleases() {
        let rig = makeRig()
        defer { rig.heartbeats.cancel() }
        rig.key(true)
        XCTAssertTrue(waitUntil { rig.keyer.isKeyed })
        rig.driver.shutdown()
        XCTAssertFalse(rig.keyer.isKeyed)
        XCTAssertTrue(rig.keyer.closed)
    }

    // MARK: - Serial source on a pseudo-terminal

    func testSerialSourceReadsLinesAndNoticesUnplug() async throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        let path = String(cString: ttyname(slave))
        let source = SerialCWKeySource(path: path, logSubsystem: "com.ftx1remote.tests")
        source.retryInterval = 0.2
        source.start()
        var iterator = source.events.makeAsyncIterator()
        let opening = await iterator.next()
        XCTAssertEqual(opening, .link(.opening))
        Darwin.close(slave)

        let bytes = Array("Z,1\r\n\u{1}\u{2}\r\nI,FTX1CW,1\r\nD,10\r\nU,7".utf8)
        _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
        usleep(20_000)
        _ = Array("0\r\n".utf8).withUnsafeBytes { write(master, $0.baseAddress, $0.count) }

        var got: [CWKeySourceEvent] = []
        while got.count < 4, let event = await iterator.next() { got.append(event) }
        XCTAssertEqual(got[0], .link(.connected(deviceID: "FTX1CW", version: 1)))
        guard case .line(.banner, _) = got[1], case .line(.keyDown(10), _) = got[2], case .line(.keyUp(70), _) = got[3] else {
            return XCTFail("unexpected events \(got)")
        }

        // Unplugged: the pty's master side goes away.
        Darwin.close(master)
        let failed = await iterator.next()
        XCTAssertEqual(failed, .link(.failed("Key interface disconnected")))
        source.stop()
    }
}
#endif

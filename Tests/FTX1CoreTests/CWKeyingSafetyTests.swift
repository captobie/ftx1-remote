import XCTest
@testable import FTX1Core

/// Every cutoff of `CWKeyingSafety`, and the whole `CWStraightKeyEngine`
/// path with a fake clock.
final class CWKeyingSafetyTests: XCTestCase {
    /// Armed, port open, linked and just heard from, nothing blocking.
    private func ready(at now: Double = 0) -> CWKeyingSafety {
        var safety = CWKeyingSafety()
        safety.setArmed(true, now: now)
        safety.setKeyerReady(true, now: now)
        safety.setLinkUp(true, now: now)
        safety.heard(at: now, now: now)
        return safety
    }

    func testKeysWhenEverythingHolds() {
        var safety = ready()
        safety.request(down: true, now: 0.1)
        XCTAssertTrue(safety.keyed)
        safety.request(down: false, now: 0.2)
        XCTAssertFalse(safety.keyed)
        XCTAssertNil(safety.latch)
    }

    func testStartsDisarmed() {
        var safety = CWKeyingSafety()
        XCTAssertFalse(safety.armed)
        safety.setKeyerReady(true, now: 0)
        safety.setLinkUp(true, now: 0)
        safety.heard(at: 0, now: 0)
        safety.request(down: true, now: 0.1)
        XCTAssertFalse(safety.keyed)
        XCTAssertEqual(safety.latch, .disarmed)
    }

    // MARK: Each cutoff forces key-up mid-hold and latches

    private func assertCutsOff(_ expected: CWKeyingSafety.Cutoff, file: StaticString = #filePath, line: UInt = #line,
                               _ cut: (inout CWKeyingSafety) -> Void, restore: (inout CWKeyingSafety) -> Void) {
        var safety = ready()
        safety.request(down: true, now: 0.1)
        XCTAssertTrue(safety.keyed, file: file, line: line)
        cut(&safety)
        XCTAssertFalse(safety.keyed, "key-up forced", file: file, line: line)
        XCTAssertEqual(safety.latch, expected, file: file, line: line)
        // The condition comes back while the operator still holds the key:
        // the line stays up.
        restore(&safety)
        XCTAssertFalse(safety.keyed, "latched until a fresh key-up", file: file, line: line)
        // A fresh key-up then key-down keys again.
        safety.request(down: false, now: 0.35)
        safety.request(down: true, now: 0.36)
        XCTAssertTrue(safety.keyed, file: file, line: line)
    }

    func testDisarmCutsOff() {
        assertCutsOff(.disarmed, { $0.setArmed(false, now: 0.2) },
                      restore: { $0.setArmed(true, now: 0.3); $0.heard(at: 0.3, now: 0.3) })
    }

    func testLinkLossCutsOff() {
        assertCutsOff(.linkDown, { $0.setLinkUp(false, now: 0.2) },
                      restore: { $0.setLinkUp(true, now: 0.3); $0.heard(at: 0.3, now: 0.3) })
    }

    func testPortErrorCutsOff() {
        assertCutsOff(.keyerUnavailable, { $0.setKeyerReady(false, now: 0.2) },
                      restore: { $0.setKeyerReady(true, now: 0.3); $0.heard(at: 0.3, now: 0.3) })
    }

    func testTransmitBlockCutsOff() {
        assertCutsOff(.blocked("Transmit disabled"), { $0.setBlockReason("Transmit disabled", now: 0.2) },
                      restore: { $0.setBlockReason(nil, now: 0.3); $0.heard(at: 0.3, now: 0.3) })
    }

    func testMissedHeartbeatsCutOff() {
        var safety = ready(at: 0)
        safety.request(down: true, now: 0.1)
        XCTAssertEqual(safety.nextDeadline!, 0.5, accuracy: 1e-9)
        safety.tick(now: 0.49)
        XCTAssertTrue(safety.keyed)
        safety.tick(now: 0.5)
        XCTAssertFalse(safety.keyed)
        XCTAssertEqual(safety.latch, .heartbeatTimeout)
        XCTAssertNil(safety.nextDeadline, "no deadline left to fire once expired")
        // Heartbeats resume while still held: stays up.
        safety.heard(at: 0.6, now: 0.6)
        XCTAssertFalse(safety.keyed)
        safety.request(down: false, now: 0.7)
        safety.request(down: true, now: 0.8)
        XCTAssertTrue(safety.keyed)
    }

    func testHeartbeatsKeepALongHoldAlive() {
        var safety = ready(at: 0)
        safety.request(down: true, now: 0)
        for tick in 1...12 {   // 3 s of heartbeats
            let t = Double(tick) * 0.25
            safety.heard(at: t, now: t)
        }
        XCTAssertTrue(safety.keyed)
    }

    func testMaxKeyDownCutsOffAndLatches() {
        var safety = CWKeyingSafety(maxKeyDown: 5)
        safety.setArmed(true, now: 0)
        safety.setKeyerReady(true, now: 0)
        safety.setLinkUp(true, now: 0)
        safety.request(down: true, now: 0)    // refused: never heard from yet
        XCTAssertFalse(safety.keyed)
        safety.request(down: false, now: 0)
        safety.heard(at: 1, now: 1)
        safety.request(down: true, now: 1)
        XCTAssertTrue(safety.keyed)
        var t = 1.0
        while t < 5.7 {
            t += 0.25
            safety.heard(at: t, now: t)
        }
        // Last heard 5.75 (deadline 6.25); the key-down limit at 6.0 is first.
        XCTAssertEqual(safety.nextDeadline!, 6.0, accuracy: 1e-9)
        safety.tick(now: 6.0)
        XCTAssertFalse(safety.keyed)
        XCTAssertEqual(safety.latch, .maxKeyDown)
        safety.heard(at: 6.1, now: 6.1)
        XCTAssertFalse(safety.keyed)
        safety.request(down: false, now: 6.2)
        XCTAssertNil(safety.latch)
        safety.request(down: true, now: 6.3)
        XCTAssertTrue(safety.keyed)
    }

    /// Arming while the operator already holds the key doesn't key.
    func testArmingMidHoldDoesNotKey() {
        var safety = CWKeyingSafety()
        safety.setKeyerReady(true, now: 0)
        safety.setLinkUp(true, now: 0)
        safety.heard(at: 0, now: 0)
        safety.request(down: true, now: 0)
        safety.setArmed(true, now: 0.1)
        XCTAssertFalse(safety.keyed)
    }

    func testUnkeyAlwaysGoesThrough() {
        var safety = ready()
        safety.request(down: true, now: 0)
        safety.setBlockReason("Transmit disabled", now: 0.1)
        safety.request(down: false, now: 0.2)
        XCTAssertFalse(safety.keyed)
        XCTAssertNil(safety.latch)
    }

    // MARK: - Engine

    private func line(_ l: CWKeyLine, _ received: Double) -> CWKeySourceEvent {
        .line(l, hostReceived: received)
    }

    /// Device clock 1000 s behind the host; the engine armed and linked.
    private func connectedEngine() -> CWStraightKeyEngine {
        var engine = CWStraightKeyEngine(playoutDelay: 0.150)
        engine.setArmed(true, now: 0)
        engine.setKeyerReady(true, now: 0)
        engine.ingest(.link(.connected(deviceID: "FTX1CW", version: 1)), now: 1000.000)
        engine.ingest(line(.banner(id: "FTX1CW", version: 1), 1000.000), now: 1000.000)
        engine.ingest(line(.heartbeat(deviceMs: 0), 1000.002), now: 1000.002)
        return engine
    }

    func testEnginePlaysAKeyedDitAtItsSpacing() {
        var engine = connectedEngine()
        engine.ingest(line(.keyDown(deviceMs: 100), 1000.110), now: 1000.110)
        engine.ingest(line(.keyUp(deviceMs: 160), 1000.163), now: 1000.163)
        XCTAssertFalse(engine.keyed)
        // offset = 1000.002 - 0 = 1000.002 (the smallest sample)
        XCTAssertEqual(engine.nextDeadline!, 1000.002 + 0.100 + 0.150, accuracy: 1e-9)
        engine.tick(now: engine.nextDeadline!)
        XCTAssertTrue(engine.keyed)
        XCTAssertEqual(engine.nextDeadline!, 1000.002 + 0.160 + 0.150, accuracy: 1e-9)
        engine.tick(now: engine.nextDeadline!)
        XCTAssertFalse(engine.keyed)
    }

    func testEngineReleasesOnLinkLoss() {
        var engine = connectedEngine()
        engine.ingest(line(.keyDown(deviceMs: 100), 1000.101), now: 1000.101)
        engine.tick(now: 1000.260)
        XCTAssertTrue(engine.keyed)
        engine.ingest(.link(.failed("unplugged")), now: 1000.300)
        XCTAssertFalse(engine.keyed)
        XCTAssertNil(engine.nextDeadline)
    }

    func testEngineReleasesWhenHeartbeatsStop() {
        var engine = connectedEngine()
        engine.ingest(line(.keyDown(deviceMs: 100), 1000.101), now: 1000.101)
        engine.tick(now: 1000.260)
        XCTAssertTrue(engine.keyed)
        // Last heard at 1000.101 → cut off at 1000.601.
        XCTAssertEqual(engine.nextDeadline!, 1000.601, accuracy: 1e-9)
        engine.tick(now: 1000.601)
        XCTAssertFalse(engine.keyed)
    }

    /// A banner mid-hold (the device reset) drops the hold and the buffer.
    func testEngineDeviceRestartReleases() {
        var engine = connectedEngine()
        engine.ingest(line(.keyDown(deviceMs: 100), 1000.101), now: 1000.101)
        engine.tick(now: 1000.260)
        XCTAssertTrue(engine.keyed)
        engine.ingest(line(.keyUp(deviceMs: 900), 1000.901), now: 1000.901)   // pending
        engine.ingest(line(.banner(id: "FTX1CW", version: 1), 1000.950), now: 1000.950)
        XCTAssertFalse(engine.keyed)
        XCTAssertEqual(engine.restartCount, 1)
        XCTAssertTrue(engine.buffer.isEmpty)
    }

    func testEngineRefusesWhileDisarmed() {
        var engine = connectedEngine()
        engine.setArmed(false, now: 1000.05)
        engine.ingest(line(.keyDown(deviceMs: 100), 1000.101), now: 1000.101)
        engine.tick(now: 1000.3)
        XCTAssertFalse(engine.keyed)
        XCTAssertTrue(engine.operatorKeyDown)
    }

    func testEngineDisarmMidHoldReleases() {
        var engine = connectedEngine()
        engine.ingest(line(.keyDown(deviceMs: 100), 1000.101), now: 1000.101)
        engine.tick(now: 1000.260)
        XCTAssertTrue(engine.keyed)
        engine.setArmed(false, now: 1000.27)
        XCTAssertFalse(engine.keyed)
    }
}

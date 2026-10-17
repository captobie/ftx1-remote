import XCTest
@testable import FTX1Core

/// `CWFeedbackDetector` against the real RF loop (Pi log, 2026-10-17) and
/// real straight-key keying (two Arduino captures the same day), then the
/// whole engine with a simulated loop.
final class CWFeedbackDetectorTests: XCTestCase {
    /// The loop as the Pi keyed it after one tap at 300 ms delay
    /// (journalctl, 08:21:35-37), seconds.
    static let loopDowns = [35.4648, 35.7917, 36.0999, 36.4099, 36.7188, 37.0292, 37.3389]
    static let loopUps = [35.6572, 35.9722, 36.2883, 36.6042, 36.9225, 37.2394, 37.5566]

    /// The user's straight key, v0.1 (with contact chatter) and v0.2 —
    /// (down, device ms).
    static let humanV01: [(Bool, Int)] = [(true, 7948), (false, 8101), (true, 8956), (false, 9111), (true, 9963), (false, 10094), (true, 11567), (false, 11905), (true, 12029), (false, 12446), (true, 14120), (false, 14230), (true, 14340), (false, 14344), (true, 14347), (false, 14350), (true, 14355), (false, 14452), (true, 14610), (false, 14990), (true, 15092), (false, 15209), (true, 16834), (false, 16941), (true, 17074), (false, 17169), (true, 17302), (false, 17690), (true, 17849), (false, 18034), (true, 19376), (false, 19470), (true, 19629), (false, 19744), (true, 19873), (false, 19973), (true, 21497), (false, 21500), (true, 21504), (false, 21592), (true, 21743), (false, 21804), (true, 21933), (false, 21936), (true, 21940), (false, 22094), (true, 23734), (false, 24009), (true, 24213), (false, 24493)]
    static let humanV02: [(Bool, Int)] = [(true, 9196), (false, 9352), (true, 10084), (false, 10178), (true, 11133), (false, 11223), (true, 11327), (false, 11425), (true, 11533), (false, 11672), (true, 12466), (false, 12773), (true, 12930), (false, 13252), (true, 13382), (false, 13648), (true, 15031), (false, 15130), (true, 15222), (false, 15347), (true, 15497), (false, 15912), (true, 16033), (false, 16122), (true, 16940), (false, 17284), (true, 18688), (false, 18794), (true, 18890), (false, 18993), (true, 19108), (false, 19229), (true, 19691), (false, 20050), (true, 20187), (false, 20485), (true, 20725), (false, 21023), (true, 21710), (false, 21805), (true, 21900), (false, 22005), (true, 22123), (false, 22434), (true, 22607), (false, 22747), (true, 23455), (false, 23857), (true, 25495), (false, 25809), (true, 25923), (false, 26033), (true, 26127), (false, 26466)]

    func testTripsOnTheRealLoop() {
        var detector = CWFeedbackDetector(loopDelay: 0.3)
        var trippedAt: Int?
        for (index, (down, up)) in zip(Self.loopDowns, Self.loopUps).enumerated() {
            detector.operatorChanged(down: true, at: down)
            if detector.operatorChanged(down: false, at: up), trippedAt == nil { trippedAt = index }
        }
        // The tap plus its first echo has an irregular period; four steady
        // periods after that: tripped on the 6th mark.
        XCTAssertEqual(trippedAt, 5)
    }

    func testNeverTripsOnRealHandKeying() {
        for delay in [0.15, 0.2, 0.3, 0.4] {
            for capture in [Self.humanV01, Self.humanV02] {
                var detector = CWFeedbackDetector(loopDelay: delay)
                for (down, ms) in capture {
                    XCTAssertFalse(detector.operatorChanged(down: down, at: Double(ms) / 1000), "delay \(delay)")
                }
            }
        }
    }

    /// A hand-sent dit run right at the loop period, with ordinary ±5 ms
    /// timing jitter, isn't steady enough.
    func testHandDitRunAtTheLoopPeriodDoesNotTrip() {
        var detector = CWFeedbackDetector(loopDelay: 0.15)
        let jitter = [0.0, 0.004, -0.005, 0.003, -0.002, 0.005, -0.004, 0.002]
        for (index, j) in jitter.enumerated() {
            let start = Double(index) * 0.155 + j
            detector.operatorChanged(down: true, at: start)
            XCTAssertFalse(detector.operatorChanged(down: false, at: start + 0.075 - j / 2))
        }
    }

    /// Steady, but at a period the loop can't have (shorter than the delay).
    func testSteadyPeriodOutsideTheLoopBandDoesNotTrip() {
        var detector = CWFeedbackDetector(loopDelay: 0.3)
        for index in 0..<10 {
            let start = Double(index) * 0.2
            detector.operatorChanged(down: true, at: start)
            XCTAssertFalse(detector.operatorChanged(down: false, at: start + 0.1))
        }
    }

    func testResetClearsATripButClearHistoryDoesNot() {
        var detector = CWFeedbackDetector(loopDelay: 0.3)
        for (down, up) in zip(Self.loopDowns, Self.loopUps) {
            detector.operatorChanged(down: true, at: down)
            detector.operatorChanged(down: false, at: up)
        }
        XCTAssertTrue(detector.tripped)
        detector.clearHistory()
        XCTAssertTrue(detector.tripped)
        detector.reset()
        XCTAssertFalse(detector.tripped)
    }

    // MARK: - Engine, with a simulated loop

    /// One tap, then every time the engine's line goes down/up the key
    /// input "presses"/"releases" 3 ms later (RF in the key lead). The
    /// engine must disarm itself within a few loops.
    func testEngineStopsASimulatedLoop() {
        var engine = CWStraightKeyEngine(playoutDelay: 0.15)
        let offset = 1000.0      // host = device + offset
        engine.setArmed(true, now: offset)
        engine.setKeyerReady(true, now: offset)
        engine.ingest(.link(.connected(deviceID: "FTX1CW", version: 1)), now: offset)
        func line(_ l: CWKeyLine, _ host: Double) { engine.ingest(.line(l, hostReceived: host), now: host) }
        func ms(_ host: Double) -> UInt32 { UInt32(((host - offset) * 1000).rounded()) }

        line(.banner(id: "FTX1CW", version: 1), offset + 0.001)
        line(.heartbeat(deviceMs: 1), offset + 0.001)
        line(.keyDown(deviceMs: 100), offset + 0.101)   // the tap
        line(.keyUp(deviceMs: 160), offset + 0.161)

        var pending: [(host: Double, down: Bool)] = []
        var lastKeyed = false
        var nextHeartbeat = offset + 0.25
        var keyedCount = 0
        var host = offset + 0.162
        while host < offset + 5 {
            engine.tick(now: host)
            if engine.keyed != lastKeyed {
                lastKeyed = engine.keyed
                if lastKeyed { keyedCount += 1 }
                pending.append((host + 0.003, lastKeyed))   // RF echo into the key input
            }
            while let first = pending.first, first.host <= host {
                pending.removeFirst()
                line(first.down ? .keyDown(deviceMs: ms(first.host)) : .keyUp(deviceMs: ms(first.host)), first.host)
            }
            if host >= nextHeartbeat {
                line(.heartbeat(deviceMs: ms(host)), host)
                nextHeartbeat += 0.25
            }
            host += 0.001
        }
        XCTAssertTrue(engine.feedbackDetected)
        XCTAssertFalse(engine.safety.armed)
        XCTAssertFalse(engine.keyed)
        XCTAssertLessThanOrEqual(keyedCount, 7, "stopped within a few loops")

        engine.setArmed(true, now: host)
        XCTAssertFalse(engine.feedbackDetected, "re-arming clears it")
    }
}

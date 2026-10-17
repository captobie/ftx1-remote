import XCTest
@testable import FTX1Core

/// `CWClockSync` (device → host offset) and `CWJitterBuffer` (playout at
/// the keyed spacing), driven with made-up host times.
final class CWJitterBufferTests: XCTestCase {
    // MARK: - Clock sync

    func testOffsetIsTheSmallestSample() {
        var sync = CWClockSync()
        XCTAssertNil(sync.offset)
        // True offset 100 s; the transport adds 1-9 ms.
        sync.add(deviceMs: 1_000, hostReceived: 101.004)
        sync.add(deviceMs: 1_250, hostReceived: 101.251)
        sync.add(deviceMs: 1_500, hostReceived: 101.509)
        XCTAssertEqual(sync.offset!, 100.001, accuracy: 1e-9)
    }

    func testOldSamplesAgeOut() {
        var sync = CWClockSync(window: 2.0)
        sync.add(deviceMs: 0, hostReceived: 100.000)          // offset 100.000
        sync.add(deviceMs: 1_000, hostReceived: 101.010)      // 100.010
        XCTAssertEqual(sync.offset!, 100.000, accuracy: 1e-9)
        sync.add(deviceMs: 2_500, hostReceived: 102.512)      // 100.012; the first is now > 2 s old
        XCTAssertEqual(sync.offset!, 100.010, accuracy: 1e-9)
    }

    /// A device clock running 0.5% slow: the estimate follows it within the
    /// window's worth of drift.
    func testFollowsDrift() {
        var sync = CWClockSync(window: 2.0)
        var host = 0.0
        for tick in 0..<200 {   // 50 s of heartbeats
            host = Double(tick) * 0.25
            let device = Int64((host * 0.995 * 1000).rounded(.down))
            sync.add(deviceMs: device, hostReceived: host + 0.002)
        }
        let trueOffset = host - (host * 0.995)
        XCTAssertEqual(sync.offset!, trueOffset, accuracy: 0.012)
    }

    func testResetForgetsSamples() {
        var sync = CWClockSync()
        sync.add(deviceMs: 5, hostReceived: 1)
        sync.reset()
        XCTAssertNil(sync.offset)
    }

    // MARK: - Jitter buffer

    /// Keyed "dit, space, dah" with every line delayed a different random-
    /// looking amount (≤ 40 ms): the output keeps the exact keyed spacing,
    /// 150 ms after the keyed times.
    func testRestoresKeyedSpacingUnderJitter() {
        var buffer = CWJitterBuffer(playoutDelay: 0.150)
        let offset = 50.0
        let keyed: [(down: Bool, ms: Int64)] = [(true, 10_000), (false, 10_060), (true, 10_120), (false, 10_300)]
        let delays = [0.031, 0.002, 0.040, 0.011]
        var output: [CWJitterBuffer.Transition] = []
        var now = 0.0
        for (index, event) in keyed.enumerated() {
            let arrival = Double(event.ms) / 1000 + offset + delays[index]
            // Play out whatever was due before this arrival.
            output += buffer.popDue(now: arrival)
            now = arrival
            buffer.enqueue(down: event.down, deviceMs: event.ms, offset: offset, now: now)
        }
        while let deadline = buffer.nextDeadline {
            output += buffer.popDue(now: deadline)
        }
        XCTAssertEqual(output.map(\.down), [true, false, true, false])
        for (transition, event) in zip(output, keyed) {
            XCTAssertEqual(transition.playAt, Double(event.ms) / 1000 + offset + 0.150, accuracy: 1e-9)
        }
    }

    func testPopDueReturnsOnlyWhatIsDueInOrder() {
        var buffer = CWJitterBuffer(playoutDelay: 0.1)
        buffer.enqueue(down: true, deviceMs: 1_000, offset: 0, now: 1.0)
        buffer.enqueue(down: false, deviceMs: 1_050, offset: 0, now: 1.05)
        XCTAssertEqual(buffer.nextDeadline!, 1.1, accuracy: 1e-9)
        XCTAssertEqual(buffer.popDue(now: 1.09), [])
        XCTAssertEqual(buffer.popDue(now: 1.1).map(\.down), [true])
        XCTAssertEqual(buffer.nextDeadline!, 1.15, accuracy: 1e-9)
        XCTAssertEqual(buffer.popDue(now: 2).map(\.down), [false])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.nextDeadline)
    }

    /// A 300 ms stall (longer than the playout delay) delivers a dit's down
    /// and up together: they still come out a dit apart.
    func testLateBurstKeepsSpacing() {
        var buffer = CWJitterBuffer(playoutDelay: 0.150)
        buffer.enqueue(down: true, deviceMs: 1_000, offset: 0, now: 1.300)
        buffer.enqueue(down: false, deviceMs: 1_060, offset: 0, now: 1.300)
        let first = buffer.popDue(now: 1.300)
        XCTAssertEqual(first.map(\.down), [true])
        XCTAssertEqual(first[0].playAt, 1.300, accuracy: 1e-9)
        XCTAssertEqual(buffer.nextDeadline!, 1.360, accuracy: 1e-9)
    }

    /// After a late element, a word-length space lets playout fall back to
    /// the normal delay instead of staying late.
    func testCatchesUpAfterASpace() {
        var buffer = CWJitterBuffer(playoutDelay: 0.150)
        buffer.enqueue(down: true, deviceMs: 1_000, offset: 0, now: 1.300)    // 150 ms late
        buffer.enqueue(down: false, deviceMs: 1_060, offset: 0, now: 1.300)
        _ = buffer.popDue(now: 2)
        buffer.enqueue(down: true, deviceMs: 2_000, offset: 0, now: 2.005)
        XCTAssertEqual(buffer.nextDeadline!, 2.150, accuracy: 1e-9)
    }

    func testNeverHoldsBeyondTheCap() {
        var buffer = CWJitterBuffer(playoutDelay: 0.150, maxExtraHold: 0.25)
        // A 1 s mark whose down arrived 2 s late (a stall): keeping its
        // length would mean holding the up to 4.0, past now + 0.4.
        buffer.enqueue(down: true, deviceMs: 1_000, offset: 0, now: 3.0)
        XCTAssertEqual(buffer.popDue(now: 3.0).count, 1)
        buffer.enqueue(down: false, deviceMs: 2_000, offset: 0, now: 3.0)
        XCTAssertEqual(buffer.nextDeadline!, 3.4, accuracy: 1e-9)
    }

    /// A letter space (shorter than `catchUpSpace`) keeps its length even
    /// while late.
    func testLetterSpaceIsNotShortened() {
        var buffer = CWJitterBuffer(playoutDelay: 0.150)
        buffer.enqueue(down: true, deviceMs: 1_000, offset: 0, now: 1.300)    // 150 ms late
        buffer.enqueue(down: false, deviceMs: 1_060, offset: 0, now: 1.300)
        _ = buffer.popDue(now: 1.5)
        buffer.enqueue(down: true, deviceMs: 1_240, offset: 0, now: 1.245)    // 180 ms space
        XCTAssertEqual(buffer.nextDeadline!, 1.360 + 0.180, accuracy: 1e-9)
    }

    func testRepeatedStateIsIgnored() {
        var buffer = CWJitterBuffer()
        buffer.enqueue(down: true, deviceMs: 0, offset: 0, now: 0)
        buffer.enqueue(down: true, deviceMs: 10, offset: 0, now: 0.01)
        XCTAssertEqual(buffer.popDue(now: 10).map(\.down), [true])
    }

    func testNeverPlaysBeforeThePreviousOne() {
        var buffer = CWJitterBuffer(playoutDelay: 0.1)
        buffer.enqueue(down: true, deviceMs: 1_000, offset: 0, now: 1.0)
        // The offset estimate dropped by 20 ms between the two.
        buffer.enqueue(down: false, deviceMs: 1_005, offset: -0.020, now: 1.005)
        let out = buffer.popDue(now: 5)
        XCTAssertEqual(out.map(\.down), [true, false])
        XCTAssertGreaterThanOrEqual(out[1].playAt, out[0].playAt)
    }

    func testFlushDropsPendingAndLastState() {
        var buffer = CWJitterBuffer()
        buffer.enqueue(down: true, deviceMs: 0, offset: 0, now: 0)
        buffer.flush()
        XCTAssertTrue(buffer.isEmpty)
        // A down right after is not taken as a repeat.
        buffer.enqueue(down: true, deviceMs: 10, offset: 0, now: 0.01)
        XCTAssertFalse(buffer.isEmpty)
    }

    /// The device clock wrapping mid-element doesn't disturb the spacing.
    func testSpacingAcrossTheDeviceClockWrap() {
        var clock = CWDeviceClockUnwrapper()
        var sync = CWClockSync()
        var buffer = CWJitterBuffer(playoutDelay: 0.150)
        let down = clock.unwrap(UInt32.max - 29).ms     // 30 ms before the wrap
        sync.add(deviceMs: down, hostReceived: 10.001)
        buffer.enqueue(down: true, deviceMs: down, offset: sync.offset!, now: 10.001)
        let up = clock.unwrap(30).ms                     // 30 ms after it
        sync.add(deviceMs: up, hostReceived: 10.062)
        buffer.enqueue(down: false, deviceMs: up, offset: sync.offset!, now: 10.062)
        let out = buffer.popDue(now: 20)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].playAt - out[0].playAt, 0.060, accuracy: 1e-6)
    }
}

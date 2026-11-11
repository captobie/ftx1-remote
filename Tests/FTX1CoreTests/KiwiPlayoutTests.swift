import XCTest
@testable import FTX1Core

final class KiwiPlayoutMonitorTests: XCTestCase {
    func testReportsOncePerIntervalWithThatWindowsLevels() {
        var monitor = KiwiPlayoutMonitor(interval: 30)
        XCTAssertNil(monitor.add(bufferedSeconds: 0.1, underruns: 0, now: 100))
        XCTAssertNil(monitor.add(bufferedSeconds: 0.3, underruns: 0, now: 120))
        let report = monitor.add(bufferedSeconds: 0.2, underruns: 2, now: 130)
        XCTAssertEqual(report?.averageMs ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(report?.minimumMs ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(report?.maximumMs ?? 0, 300, accuracy: 1e-9)
        XCTAssertEqual(report?.underruns, 2)
        XCTAssertEqual(report?.elapsedSeconds, 30)
        XCTAssertNil(monitor.add(bufferedSeconds: 0.5, underruns: 2, now: 140))
        let next = monitor.add(bufferedSeconds: 0.5, underruns: 3, now: 160)
        XCTAssertEqual(next?.minimumMs ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(next?.elapsedSeconds, 60)
    }
}

/// The queue-keeping decisions, on a fake clock.
final class KiwiPlayoutControllerTests: XCTestCase {
    private let chunk = 0.043

    /// Feeds `seconds` of readings at chunk rate, returning the actions
    /// other than `.none` and where the clock ended.
    private func run(_ controller: inout KiwiPlayoutController, from start: Double, seconds: Double,
                     buffered: (Double) -> Double) -> (actions: [KiwiPlayoutController.Action], end: Double) {
        var now = start
        var actions: [KiwiPlayoutController.Action] = []
        while now < start + seconds {
            let action = controller.observe(bufferedSeconds: buffered(now), chunkSeconds: 0, now: now)
            if action != .none { actions.append(action) }
            now += chunk
        }
        return (actions, now)
    }

    func testNothingHappensOnTarget() {
        var controller = KiwiPlayoutController(target: 0.25)
        XCTAssertEqual(run(&controller, from: 0, seconds: 60) { _ in 0.25 }.actions, [])
    }

    func testJitterInsideTheDeadbandIsLeftAlone() {
        var controller = KiwiPlayoutController(target: 0.25)
        let result = run(&controller, from: 0, seconds: 120) { now in 0.25 + 0.04 * sin(now * 7) }
        XCTAssertEqual(result.actions, [])
    }

    func testNothingUntilTheWindowHasFilled() {
        var controller = KiwiPlayoutController(target: 0.25)
        let result = run(&controller, from: 0, seconds: 9) { _ in 0.29 }
        XCTAssertEqual(result.actions, [])
    }

    func testSustainedHighQueueSplicesOutAtMostTwiceASecondUntilSettled() {
        var controller = KiwiPlayoutController(target: 0.25)
        var offset = 0.0
        var spliceTimes: [Double] = []
        var now = 0.0
        while now < 60 {
            let action = controller.observe(bufferedSeconds: 0.29 + offset, chunkSeconds: 0, now: now)
            if case .splice(let direction) = action {
                XCTAssertEqual(direction, 1)
                spliceTimes.append(now)
                offset -= 0.001
                controller.applied(seconds: 0.001)
            }
            now += chunk
        }
        XCTAssertEqual(spliceTimes.first ?? 0, 10, accuracy: 0.1)
        XCTAssertEqual(spliceTimes.count, 30, "40 ms over → stops within 10 ms, at 1 ms each")
        for (a, b) in zip(spliceTimes, spliceTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, KiwiPlayoutController.correctionInterval)
        }
    }

    func testSustainedLowQueueAddsAudio() {
        var controller = KiwiPlayoutController(target: 0.25)
        let actions = run(&controller, from: 0, seconds: 11) { _ in 0.21 }.actions
        XCTAssertEqual(actions.first, .splice(direction: -1))
    }

    func testBacklogIsDiscardedOnce() {
        var controller = KiwiPlayoutController(target: 0.25)
        var level = 0.25
        var discards: [Double] = []
        var now = 0.0
        while now < 20 {
            if now >= 5, now < 5 + chunk { level = 2.25 }
            let action = controller.observe(bufferedSeconds: level, chunkSeconds: 0, now: now)
            if case .discard(let seconds) = action {
                discards.append(seconds)
                level = 0.25
            }
            now += chunk
        }
        XCTAssertEqual(discards.count, 1)
        XCTAssertEqual(discards[0], 2, accuracy: 1e-6)
    }

    func testAShortBurstIsntABacklog() {
        var controller = KiwiPlayoutController(target: 0.25)
        let result = run(&controller, from: 0, seconds: 20) { now in
            (now >= 12 && now < 12.2) ? 0.8 : 0.25
        }
        XCTAssertEqual(result.actions, [])
    }

    func testADryQueueIsPadded() {
        var controller = KiwiPlayoutController(target: 0.25)
        _ = run(&controller, from: 0, seconds: 2) { _ in 0.25 }
        let action = controller.observe(bufferedSeconds: 0, chunkSeconds: chunk, now: 2.5)
        XCTAssertEqual(action, .pad(seconds: 0.25 - chunk))
    }

    func testTheLevelIncludesTheChunkBeingAdded() {
        // Just before a chunk the queue is a chunk short of target: on target.
        var controller = KiwiPlayoutController(target: 0.25)
        var now = 0.0
        while now < 60 {
            XCTAssertEqual(controller.observe(bufferedSeconds: 0.25 - chunk, chunkSeconds: chunk, now: now), .none)
            now += chunk
        }
    }

    func testAnEmptyQueueBeforeTheFirstReadingIsntAStall() {
        var controller = KiwiPlayoutController(target: 0.25)
        XCTAssertEqual(controller.observe(bufferedSeconds: 0, chunkSeconds: chunk, now: 0), .none)
    }
}

/// The sample processing, against a simulated queue.
final class KiwiPlayoutAdjusterTests: XCTestCase {
    private let rate = 11_998.902

    private func sine(_ hz: Double, count: Int, amplitude: Double = 10_000, start: Int = 0) -> [Int16] {
        (0..<count).map { Int16(amplitude * sin(2 * .pi * hz * Double(start + $0) / rate)) }
    }

    func testSpliceShortensOrLengthensWithinTheOffsets() throws {
        let x = sine(700, count: 512)
        let shorter = try XCTUnwrap(KiwiPlayoutAdjuster.spliced(x, direction: 1))
        let longer = try XCTUnwrap(KiwiPlayoutAdjuster.spliced(x, direction: -1))
        XCTAssertTrue(KiwiPlayoutAdjuster.offsets.contains(x.count - shorter.count))
        XCTAssertTrue(KiwiPlayoutAdjuster.offsets.contains(longer.count - x.count))
    }

    func testSpliceKeepsASteadyTonesPhase() throws {
        for direction in [1, -1] {
            let x = sine(700, count: 512)
            let y = try XCTUnwrap(KiwiPlayoutAdjuster.spliced(x, direction: direction))
            // The largest step in a clean 700 Hz sine at this amplitude.
            let maxStep = 10_000 * 2 * Double.pi * 700 / rate
            for (a, b) in zip(y, y.dropFirst()) {
                XCTAssertLessThanOrEqual(abs(Double(b) - Double(a)), maxStep * 1.05)
            }
            // The level stays: no dip where the two stretches meet.
            let peak = y[30..<(30 + 96)].map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, 9_000, "direction \(direction)")
        }
    }

    func testTooShortChunksAreLeftAlone() {
        XCTAssertNil(KiwiPlayoutAdjuster.spliced([Int16](repeating: 0, count: 100), direction: 1))
    }

    /// Chunks arrive every 512 samples; the queue drains at `clockRatio`
    /// of the input's rate.
    private func simulate(minutes: Double, clockRatio: Double, stallAt: Double? = nil, stallSeconds: Double = 0)
        -> (peakError: Double, finalQueue: Double, adjuster: KiwiPlayoutAdjuster, totalOut: Int, gaps: Int) {
        var adjuster = KiwiPlayoutAdjuster(sampleRate: rate, targetSeconds: 0.25)
        let chunk = 512
        let chunkSeconds = Double(chunk) / rate
        var queue = 0.25
        var now = 0.0
        var peakError = 0.0
        var totalOut = 0
        var gaps = 0
        var stalled = false
        var index = 0
        var backlog = 0
        while now < minutes * 60 {
            now += chunkSeconds
            queue -= chunkSeconds * clockRatio
            if queue < 0 {
                queue = 0
                gaps += 1
            }
            if let stallAt, !stalled, now >= stallAt {
                stalled = true
                backlog = Int(stallSeconds / chunkSeconds)
                // Nothing arrives for the stall: the queue plays out.
                queue = max(queue - stallSeconds, 0)
                now += stallSeconds
            }
            let arrivals = 1 + backlog
            backlog = 0
            for _ in 0..<arrivals {
                let samples = sine(700, count: chunk, start: index * chunk)
                index += 1
                let out = adjuster.process(samples, bufferedSeconds: queue, now: now)
                totalOut += out.count
                queue += Double(out.count) / rate
            }
            if now > 15, stallAt == nil || now > stallAt! + 15 {
                peakError = max(peakError, abs(queue - 0.25))
            }
        }
        return (peakError, queue, adjuster, totalOut, gaps)
    }

    func testDriftIsHeldInsideTheDeadbandEitherWay() {
        // 200 ppm: far beyond the 5 ppm measured, so a short run exercises it.
        for ratio in [1.0002, 0.9998] {
            let result = simulate(minutes: 10, clockRatio: ratio)
            XCTAssertLessThan(result.peakError, KiwiPlayoutController.deadband + 0.01, "\(ratio)")
            XCTAssertGreaterThan(result.adjuster.splices, 0)
            XCTAssertEqual(result.gaps, 0)
        }
    }

    func testAStallsBacklogDoesntStay() {
        let result = simulate(minutes: 3, clockRatio: 1, stallAt: 30, stallSeconds: 2)
        XCTAssertLessThan(result.peakError, 0.1, "the queue is back near target after the stall")
        XCTAssertEqual(result.adjuster.discardedSeconds, 2, accuracy: 0.4)
    }

    func testAStallWithNoBacklogRefillsTheQueue() {
        var adjuster = KiwiPlayoutAdjuster(sampleRate: rate, targetSeconds: 0.25)
        let chunk = [Int16](repeating: 1000, count: 512)
        _ = adjuster.process(chunk, bufferedSeconds: 0.25, now: 0)
        let out = adjuster.process(chunk, bufferedSeconds: 0, now: 3)
        XCTAssertEqual(adjuster.paddedSeconds, 0.25 - 512 / rate, accuracy: 1e-9)
        XCTAssertEqual(out.count, Int((0.25 - 512 / rate) * rate) + 512)
    }

    func testDiscardedAudioIsNotPassedOnAndTheFirstKeptChunkFadesIn() {
        var adjuster = KiwiPlayoutAdjuster(sampleRate: rate, targetSeconds: 0.25)
        let chunk = [Int16](repeating: 8000, count: 512)
        var now = 0.0
        for _ in 0..<20 {
            _ = adjuster.process(chunk, bufferedSeconds: 0.25 - 512 / rate, now: now)
            now += 0.043
        }
        // A backlog: every reading is high for over 0.5 s.
        var fadeOutSeen = false
        var discarding = false
        for _ in 0..<40 {
            let out = adjuster.process(chunk, bufferedSeconds: 1.25 - 512 / rate, now: now)
            now += 0.043
            if adjuster.discardedSeconds > 0 {
                if !discarding, let last = out.last {
                    XCTAssertLessThan(abs(Int(last)), 200, "the chunk before the jump fades out")
                    fadeOutSeen = true
                }
                discarding = true
            }
        }
        XCTAssertTrue(fadeOutSeen)
        XCTAssertEqual(adjuster.discardedSeconds, 1, accuracy: 0.01)
    }

    func testBeforePlaybackStartsSamplesPassThrough() {
        var adjuster = KiwiPlayoutAdjuster(sampleRate: rate, targetSeconds: 0.25)
        let chunk = sine(700, count: 512)
        XCTAssertEqual(adjuster.process(chunk, bufferedSeconds: nil, now: 0), chunk)
    }
}

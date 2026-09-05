import XCTest
@testable import FTX1Core

final class SquelchGateTests: XCTestCase {
    func testGateOpensAboveThreshold() {
        var gate = SquelchGate(threshold: 0.1)
        XCTAssertFalse(gate.isOpen)
        XCTAssertTrue(gate.update(rms: 0.5))
        XCTAssertTrue(gate.isOpen)
    }

    func testGateStaysClosedBelowThreshold() {
        var gate = SquelchGate(threshold: 0.1)
        XCTAssertFalse(gate.update(rms: 0.01))
        XCTAssertFalse(gate.isOpen)
    }

    func testGateHoldsOpenThroughReleaseWindow() {
        var gate = SquelchGate(threshold: 0.1)
        gate.releaseDuration = 0.3
        let start = Date()

        XCTAssertTrue(gate.update(rms: 0.5, now: start))
        // Level drops, but still within the release window — should still
        // read open (avoids chattering right at the threshold edge).
        XCTAssertTrue(gate.update(rms: 0.0, now: start.addingTimeInterval(0.1)))
    }

    func testGateClosesAfterReleaseWindowElapses() {
        var gate = SquelchGate(threshold: 0.1)
        gate.releaseDuration = 0.3
        let start = Date()

        XCTAssertTrue(gate.update(rms: 0.5, now: start))
        XCTAssertFalse(gate.update(rms: 0.0, now: start.addingTimeInterval(0.5)))
    }

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(SquelchGate.rms(of: [0, 0, 0, 0]), 0)
    }

    func testRMSOfFullScaleIsOne() {
        XCTAssertEqual(SquelchGate.rms(of: [1, -1, 1, -1]), 1, accuracy: 0.0001)
    }

    func testRMSOfInt16BytesMatchesFloatEquivalent() {
        let samples: [Int16] = [Int16.max, Int16.min, Int16.max, Int16.min]
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(SquelchGate.rms(ofInt16Bytes: data), 1, accuracy: 0.01)
    }
}

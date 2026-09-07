import XCTest
@testable import FTX1Core

final class SquelchGateTests: XCTestCase {
    func testGateOpensOnAQuietingDip() {
        var gate = SquelchGate(threshold: 0.01)
        XCTAssertFalse(gate.isOpen)
        XCTAssertTrue(gate.update(rms: 0.005))
        XCTAssertTrue(gate.isOpen)
    }

    func testGateStaysClosedOnLoudStatic() {
        // Static never dips near-silent (see SquelchGate's doc comment for
        // the hardware capture this is based on) — a loud, non-quiet
        // reading alone should never open the gate.
        var gate = SquelchGate(threshold: 0.01)
        XCTAssertFalse(gate.update(rms: 0.07))
        XCTAssertFalse(gate.isOpen)
    }

    func testGateHoldsOpenThroughReleaseWindowAfterQuietingDip() {
        var gate = SquelchGate(threshold: 0.01)
        gate.releaseDuration = 4.0
        let start = Date()

        XCTAssertTrue(gate.update(rms: 0.005, now: start)) // the quieting dip
        // A loud reading right after — indistinguishable from static on its
        // own — should still read open, bridging through real speech.
        XCTAssertTrue(gate.update(rms: 0.07, now: start.addingTimeInterval(1)))
    }

    func testGateClosesAfterReleaseWindowElapsesWithNoFurtherQuieting() {
        var gate = SquelchGate(threshold: 0.01)
        gate.releaseDuration = 4.0
        let start = Date()

        XCTAssertTrue(gate.update(rms: 0.005, now: start))
        XCTAssertFalse(gate.update(rms: 0.07, now: start.addingTimeInterval(5)))
    }

    func testRepeatedQuietingDipsExtendTheHangover() {
        var gate = SquelchGate(threshold: 0.01)
        gate.releaseDuration = 4.0
        let start = Date()

        XCTAssertTrue(gate.update(rms: 0.005, now: start))
        XCTAssertTrue(gate.update(rms: 0.07, now: start.addingTimeInterval(3)))
        // A second dip (e.g. the next pause between phrases) refreshes the
        // hangover instead of letting it expire on the first one's clock.
        XCTAssertTrue(gate.update(rms: 0.005, now: start.addingTimeInterval(3.5)))
        XCTAssertTrue(gate.update(rms: 0.07, now: start.addingTimeInterval(6.5)))
    }

    func testSustainedLoudStaticNeverOpensTheGate() {
        // The core case this design exists for: static that never quiets
        // should stay closed indefinitely, no matter how long it runs.
        var gate = SquelchGate(threshold: 0.01)
        for _ in 0..<200 {
            XCTAssertFalse(gate.update(rms: 0.07))
        }
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

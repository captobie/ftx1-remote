import XCTest
@testable import FTX1Core

final class SMeterScaleTests: XCTestCase {
    // MARK: S scale (RX signal strength, dB relative to S9)

    func testStrengthAnchorPoints() {
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: -54), 0.0, accuracy: 1e-9)
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: -48), 0.05, accuracy: 1e-9)  // S1
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: 0), 0.53, accuracy: 1e-9)    // S9
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: 20), 0.66, accuracy: 1e-9)
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: 40), 0.79, accuracy: 1e-9)
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: 60), 0.92, accuracy: 1e-9)
    }

    /// The labeled anchor fractions must land exactly on the drawn tick
    /// positions — the needle has to point at the printed numeral.
    func testStrengthAnchorsMatchDrawnTicks() {
        // S1..S9 ticks: one S unit = 6dB below S9's 0dB.
        for (label, fraction, _) in SMeterScale.sTicks {
            let db: Double
            if label.hasPrefix("+") {
                db = Double(label.dropFirst())!  // "+20" -> 20
            } else {
                db = Double(Int(label)! - 9) * 6  // S units, 6dB apart below S9
            }
            XCTAssertEqual(SMeterScale.fraction(forStrengthDb: db), fraction, accuracy: 1e-9, "tick \(label)")
        }
    }

    func testStrengthOddSUnitsEvenlySpaced() {
        // S1..S9 are linear in dB, so S3/S5/S7 interpolate evenly.
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: -36), 0.17, accuracy: 1e-9)  // S3
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: -24), 0.29, accuracy: 1e-9)  // S5
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: -12), 0.41, accuracy: 1e-9)  // S7
    }

    func testStrengthClampsOutsideScale() {
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: -80), 0.0)
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: 90), 0.92)
    }

    func testStrengthNilRestsNeedle() {
        XCTAssertEqual(SMeterScale.fraction(forStrengthDb: nil), 0.0)
    }

    func testStrengthMonotonic() {
        let fractions = stride(from: -60.0, through: 70.0, by: 1.0)
            .map { SMeterScale.fraction(forStrengthDb: $0) }
        for (a, b) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b)
        }
    }

    // MARK: SWR scale (TX)

    func testSWRAnchorsMatchDrawnTicks() {
        for (label, fraction) in SMeterScale.swrTicks where label != "∞" {
            let swr = Double(label)!
            XCTAssertEqual(SMeterScale.fraction(forSWR: swr), fraction, accuracy: 1e-9, "tick \(label)")
        }
    }

    func testSWRClampsAtInfinityTick() {
        let infinityFraction = SMeterScale.swrTicks.last!.fraction
        XCTAssertEqual(SMeterScale.fraction(forSWR: 20), infinityFraction, accuracy: 1e-9)
        XCTAssertEqual(SMeterScale.fraction(forSWR: 999), infinityFraction, accuracy: 1e-9)
    }

    func testSWRClampsBelowOne() {
        // SWR < 1.0 is physically impossible; a glitchy reading shouldn't
        // swing the needle below the 1.0 tick.
        XCTAssertEqual(SMeterScale.fraction(forSWR: 0.5), 0.10, accuracy: 1e-9)
    }

    func testSWRNilRestsNeedle() {
        XCTAssertEqual(SMeterScale.fraction(forSWR: nil), 0.0)
    }

    func testSWRMonotonic() {
        let fractions = stride(from: 1.0, through: 25.0, by: 0.1)
            .map { SMeterScale.fraction(forSWR: $0) }
        for (a, b) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b)
        }
    }
}

import XCTest
@testable import FTX1Core

final class TransmitGateTests: XCTestCase {
    func testAllowsInsideAnAmateurBandWhenEnabled() {
        let state = RigState(frequencyHz: 14_200_000)
        XCTAssertNil(TransmitGate.blockReason(transmitEnabled: true, state: state))
    }

    func testBlocksWhenDisabled() {
        let state = RigState(frequencyHz: 14_200_000)
        XCTAssertEqual(TransmitGate.blockReason(transmitEnabled: false, state: state), "Transmit disabled")
    }

    func testBlocksOutsideTheBandsAndBeforeTheFirstRead() {
        XCTAssertNotNil(TransmitGate.blockReason(transmitEnabled: true, state: RigState(frequencyHz: 9_650_000)))
        XCTAssertNotNil(TransmitGate.blockReason(transmitEnabled: true, state: RigState(frequencyHz: 0)))
    }

    /// TX:SUB (or split) transmits on SUB, so SUB's frequency is checked.
    func testChecksSubWhenSubTransmits() {
        var state = RigState(frequencyHz: 14_200_000)
        state.secondaryFrequencyHz = 9_650_000
        state.txSide = .sub
        XCTAssertNotNil(TransmitGate.blockReason(transmitEnabled: true, state: state))

        state.txSide = .main
        state.splitEnabled = true
        XCTAssertNotNil(TransmitGate.blockReason(transmitEnabled: true, state: state))

        state.splitEnabled = false
        XCTAssertNil(TransmitGate.blockReason(transmitEnabled: true, state: state))
    }
}

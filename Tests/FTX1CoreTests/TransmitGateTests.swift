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

    /// TX:SUB transmits on SUB, and split on the TX VFO that
    /// `secondaryFrequencyHz` holds then, so that frequency is checked.
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

    /// The split TX VFO follows MAIN's mode; `secondaryMode` is still the
    /// SUB receiver's then (rig-confirmed 2026-10-31).
    func testSplitTransmitsInMainsMode() {
        var state = RigState(frequencyHz: 21_033_000, mode: .cw)
        state.secondaryFrequencyHz = 21_034_000
        state.secondaryMode = .fm
        state.splitEnabled = true
        XCTAssertEqual(state.transmitFrequencyHz, 21_034_000)
        XCTAssertEqual(state.transmitMode, .cw)
        XCTAssertEqual(TransmitGate.transmitMode(of: state), .cw)
        XCTAssertEqual(state.subTxRxLabel, "TX")
        XCTAssertEqual(state.mainTxRxLabel, "RX")

        state.splitEnabled = false
        state.txSide = .sub
        XCTAssertEqual(state.transmitMode, .fm)
        XCTAssertEqual(state.subTxRxLabel, "TXRX")
    }
}

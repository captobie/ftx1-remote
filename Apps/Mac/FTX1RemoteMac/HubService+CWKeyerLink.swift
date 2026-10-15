import Combine
import FTX1CW
import FTX1Core

/// The CW window's send pane (`CWSender`, shared with the iPad) on the
/// Mac's own rigctld link. The keyer reads and writes are `HubService`'s
/// (`writeCWKeyerMemory`, `ensureCWTextMemory`); playing goes through
/// `send(_:)`, so its Enable Transmit/band gate applies.
extension HubService: CWKeyerLink {
    var cwRigState: RigState { rigState }

    var cwRigStatePublisher: AnyPublisher<RigState, Never> {
        $rigState.eraseToAnyPublisher()
    }

    var cwSendBlock: CWSendBlock? {
        if connectionState != .connected { return .notConnected }
        if !transmitEnabled { return .transmitDisabled }
        if rigState.mode != .cw { return .notCW(rigState.mode) }
        if BandPlan.band(containing: rigState.frequencyHz) == nil { return .outsideBand }
        if rigState.breakIn == false { return .breakInOff }
        return nil
    }

    func playCWTextMemory(slot: Int) {
        send(.playCWTextMemory(slot: slot))
    }
}

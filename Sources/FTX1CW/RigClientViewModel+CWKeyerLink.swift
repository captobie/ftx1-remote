import Combine
import FTX1Core

/// The iPad's CW send section on the hub route (phase 3). The keyer
/// memory is written on the Mac (`CWKeyerRequest`, `RigClientViewModel.
/// writeCWKeyerMemory`/`ensureCWTextMemory`); playing it is
/// `.playCWTextMemory`, which the Mac gates with its own Enable Transmit
/// and band check (`HubService.send`).
extension RigClientViewModel: CWKeyerLink {
    public var cwRigState: RigState { rigState }

    public var cwRigStatePublisher: AnyPublisher<RigState, Never> {
        $rigState.eraseToAnyPublisher()
    }

    /// The Mac's own blocks (`HubService.cwSendBlock`), read from the state
    /// it pushes, plus not while PTT is held here. `transmitEnabled` is the
    /// Mac's Enable Transmit (its Settings toggle, or the hub screen's lock
    /// button through `.setTransmitEnabled`).
    public var cwSendBlock: CWSendBlock? {
        guard connectionState == .connected else { return .notConnected }
        if !rigState.transmitEnabled {
            return .transmitBlocked(String(localized: "rigClient.transmitIsLockedOn", bundle: .module))
        }
        if isTransmitting { return .transmitBlocked(String(localized: "common.pttIsHeld", bundle: .module)) }
        if rigState.mode != .cw { return .notCW(rigState.mode) }
        if BandPlan.band(containing: rigState.frequencyHz) == nil { return .outsideBand }
        if rigState.breakIn == false { return .breakInOff }
        return nil
    }

    public func playCWTextMemory(slot: Int) {
        send(.playCWTextMemory(slot: slot))
    }

    /// Through the hub's coordinator (`CWKeyerRequest` `.acquire`).
    public func acquireCWKeyer() async throws -> CWKeyerBusy? {
        try await acquireCWKeyerLease()
    }

    public func releaseCWKeyer() {
        releaseCWKeyerLease()
    }
}

import Combine
import FTX1Core

/// The iPad's CW send section on Pi direct. Here rather than in FTX1Core,
/// which can't name `CWKeyerLink`; the keyer reads and writes themselves
/// are `PiDirectViewModel`'s own (`writeCWKeyerMemory`, `ensureCWTextMemory`).
extension PiDirectViewModel: CWKeyerLink {
    public var cwRigState: RigState { rigState }

    public var cwRigStatePublisher: AnyPublisher<RigState, Never> {
        $rigState.eraseToAnyPublisher()
    }

    /// The Mac's blocks (`HubService.cwSendBlock`), with this route's own
    /// transmit gate — the lock next to PTT, amateur bands on the
    /// transmitting side, not while the rig scans — and not while PTT is
    /// held here.
    public var cwSendBlock: CWSendBlock? {
        guard connectionState == .connected else { return .notConnected }
        if !transmitEnabled {
            return .transmitBlocked(String(localized: "piDirect.transmitIsLockedUnlock", bundle: .module))
        }
        if let reason = transmitBlockReason { return .transmitBlocked(reason) }
        if isTransmitting { return .transmitBlocked(String(localized: "common.pttIsHeld", bundle: .module)) }
        if rigState.mode != .cw { return .notCW(rigState.mode) }
        if rigState.breakIn == false { return .breakInOff }
        return nil
    }

    public func playCWTextMemory(slot: Int) {
        send(.playCWTextMemory(slot: slot))
    }

    /// No coordinator on this route: the hub isn't in the path (a Mac in
    /// remote mode on the same Pi isn't coordinated with — known gap).
    public func acquireCWKeyer() async throws -> CWKeyerBusy? { nil }

    public func releaseCWKeyer() {}
}

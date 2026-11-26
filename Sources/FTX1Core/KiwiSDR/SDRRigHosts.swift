import Combine
import Foundation

// The iPad's routes as the SDRs' rig side: Follow, Tune rig, Mute on TX
// and muting MAIN while the Kiwi is audible, through whichever view model
// the screen uses. `setSDRAudible` is each model's own.

extension RigClientViewModel: SDRRigHost {
    public var sdrRigState: RigState { rigState }
    public var sdrRigStatePublisher: AnyPublisher<RigState, Never> { $rigState.eraseToAnyPublisher() }
    public var sdrRigConnected: Bool { connectionState == .connected }
    public func sdrSend(_ command: RigCommand) { send(command) }
}

extension PiDirectViewModel: SDRRigHost {
    public var sdrRigState: RigState { rigState }
    public var sdrRigStatePublisher: AnyPublisher<RigState, Never> { $rigState.eraseToAnyPublisher() }
    public var sdrRigConnected: Bool { connectionState == .connected }
    public func sdrSend(_ command: RigCommand) { send(command) }
}

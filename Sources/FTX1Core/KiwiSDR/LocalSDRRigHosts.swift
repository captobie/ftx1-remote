import Combine
import Foundation

// The iPad's routes as MyKiwiSDR's rig side: Follow, Tune rig, Mute on TX
// and muting MAIN while the Kiwi is audible, through whichever view model
// the screen uses. `setLocalSDRAudible` is each model's own.

extension RigClientViewModel: LocalSDRRigHost {
    public var localSDRRigState: RigState { rigState }
    public var localSDRRigStatePublisher: AnyPublisher<RigState, Never> { $rigState.eraseToAnyPublisher() }
    public var localSDRRigConnected: Bool { connectionState == .connected }
    public func localSDRSend(_ command: RigCommand) { send(command) }
}

extension PiDirectViewModel: LocalSDRRigHost {
    public var localSDRRigState: RigState { rigState }
    public var localSDRRigStatePublisher: AnyPublisher<RigState, Never> { $rigState.eraseToAnyPublisher() }
    public var localSDRRigConnected: Bool { connectionState == .connected }
    public func localSDRSend(_ command: RigCommand) { send(command) }
}

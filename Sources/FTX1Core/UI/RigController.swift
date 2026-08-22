import SwiftUI

/// Common interface for whatever is backing a rig-control screen — the
/// Mac's `HubService` (talks to rigctld directly) or a mobile client's
/// `RigClientViewModel` (talks to the Mac over WebSocket). Lets shared views
/// like `MenuPageView` work against either without depending on Mac-only or
/// mobile-only types.
@MainActor
public protocol RigController: ObservableObject {
    var rigState: RigState { get }
    func send(_ command: RigCommand)

    /// Whether this controller can open Deep Settings screens. Requires a
    /// per-item read capability that only the Mac's direct rigctld link has
    /// today (`HubService.readMenuItem`) — the WebSocket wire protocol has
    /// no request/response mechanism for a remote client to fetch a Deep
    /// Settings item's current value, only fire-and-forget commands and
    /// one-way state pushes. Defaults to `false`.
    var supportsDeepSettings: Bool { get }

    /// Type-erased Deep Settings destination for the given category, or
    /// `nil` if unsupported. Type-erased because the concrete destination
    /// view (`DeepSettingsView`) lives in the Mac app target, which this
    /// shared package can't import — only `HubService`'s conformance
    /// builds a real one.
    func deepSettingsDestination(title: String, p1s: [Int]) -> AnyView?
}

public extension RigController {
    var supportsDeepSettings: Bool { false }
    func deepSettingsDestination(title: String, p1s: [Int]) -> AnyView? { nil }
}

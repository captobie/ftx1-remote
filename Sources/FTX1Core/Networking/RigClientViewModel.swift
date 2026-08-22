import Combine
import Foundation

/// Client-side counterpart to the Mac hub's `HubService` — owns the
/// `RigWebSocketClient` connection to the Mac's `RigWebSocketServer` and
/// exposes the live rig state to SwiftUI. Never talks to rigctld directly
/// (see repo root CLAUDE.md): this app is a WebSocket client only. Shared by
/// the iOS and iPadOS app targets so their connection logic can't drift
/// apart.
@MainActor
public final class RigClientViewModel: ObservableObject, RigController {
    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published public private(set) var rigState = RigState()
    @Published public private(set) var connectionState: ConnectionState = .disconnected

    private var client: RigWebSocketClient?
    private let port: UInt16

    public init(port: UInt16 = 8765) {
        self.port = port
    }

    public func connect(toHost host: String) {
        guard !host.isEmpty, let url = URL(string: "ws://\(host):\(port)") else {
            connectionState = .failed("Invalid host")
            return
        }

        let client = RigWebSocketClient(hubURL: url)
        self.client = client
        connectionState = .connecting

        Task {
            await client.setOnStateUpdate { [weak self] state in
                Task { @MainActor in self?.rigState = state }
            }
            // Not just a one-shot read after connect(): the client can
            // transition later on its own (e.g. its heartbeat detecting a
            // dead link), and without this the UI would keep showing
            // "Connected" forever after the Mac actually became
            // unreachable.
            await client.setOnStateChange { [weak self] state in
                Task { @MainActor in self?.apply(state) }
            }
            await client.connect()
            await self.refreshConnectionState()
        }
    }

    public func disconnect() {
        guard let client else { return }
        Task { await client.disconnect() }
        self.client = nil
        connectionState = .disconnected
    }

    public func send(_ command: RigCommand) {
        guard let client else { return }
        Task { try? await client.send(command) }
    }

    private func refreshConnectionState() async {
        guard let client else { return }
        apply(await client.state)
    }

    private func apply(_ state: RigWebSocketClient.ConnectionState) {
        switch state {
        case .disconnected: connectionState = .disconnected
        case .connecting: connectionState = .connecting
        case .connected: connectionState = .connected
        case .failed(let message): connectionState = .failed(message)
        }
    }
}

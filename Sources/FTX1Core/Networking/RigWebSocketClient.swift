import Foundation

/// Client-side connection to the Mac hub's WebSocket server.
/// Used by iOS/iPadOS apps (and optionally the Mac app's own UI, if it
/// ends up talking to its own server rather than the local RigctldClient
/// directly — see the open design question on Mac UI architecture).
public actor RigWebSocketClient {
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private let url: URL

    public private(set) var state: ConnectionState = .disconnected

    /// Called on every state push received from the hub. Delivered on
    /// whatever executor the caller sets up — UI layers should hop to
    /// @MainActor themselves when updating SwiftUI state.
    public var onStateUpdate: (@Sendable (RigState) -> Void)?

    public init(hubURL: URL, session: URLSession = .shared) {
        self.url = hubURL
        self.session = session
    }

    public func connect() {
        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        state = .connected
        listen()
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    public func send(_ command: RigCommand) async throws {
        guard let task else { throw RigWebSocketError.notConnected }
        let data = try JSONEncoder().encode(command)
        try await task.send(.data(data))
    }

    private func listen() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                Task { await self.handle(message) }
                Task { await self.listen() }
            case .failure(let error):
                Task { await self.markFailed(error) }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let d): data = d
        case .string(let s): data = s.data(using: .utf8)
        @unknown default: data = nil
        }
        guard let data,
              let push = try? JSONDecoder().decode(RigStatePush.self, from: data) else { return }
        onStateUpdate?(push.state)
    }

    private func markFailed(_ error: Error) {
        state = .failed(error.localizedDescription)
    }
}

public enum RigWebSocketError: Error {
    case notConnected
}

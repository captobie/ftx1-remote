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
    private let openSignal = OpenSignal()
    private let url: URL

    public private(set) var state: ConnectionState = .disconnected

    /// Called on every state push received from the hub. Delivered on
    /// whatever executor the caller sets up — UI layers should hop to
    /// @MainActor themselves when updating SwiftUI state.
    public var onStateUpdate: (@Sendable (RigState) -> Void)?

    public init(hubURL: URL) {
        self.url = hubURL
        self.session = URLSession(configuration: .default, delegate: openSignal, delegateQueue: nil)
    }

    public func setOnStateUpdate(_ handler: @escaping @Sendable (RigState) -> Void) {
        onStateUpdate = handler
    }

    /// Waits for the server to actually accept the WebSocket handshake
    /// before reporting `.connected` — `URLSessionWebSocketTask.resume()`
    /// only *schedules* the attempt, it doesn't confirm success. Flipping to
    /// `.connected` right after `resume()` (as this used to do) meant the UI
    /// could show "Connected" even when the Mac was unreachable (wrong
    /// Tailscale address, firewalled port, rigctld host down) and no data
    /// would ever arrive, with no way to distinguish that from a real,
    /// working connection that just hasn't received its first push yet.
    public func connect(timeout: Duration = .seconds(8)) async {
        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        openSignal.reset()
        task.resume()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.openSignal.waitForOpen() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw RigWebSocketError.connectTimedOut
                }
                try await group.next()
                group.cancelAll()
            }
            state = .connected
            listen()
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            self.task = nil
            state = .failed(errorMessage(for: error))
        }
    }

    private func errorMessage(for error: Error) -> String {
        if error is RigWebSocketError {
            return "Timed out connecting"
        }
        return error.localizedDescription
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
    case connectTimedOut
}

/// Bridges `URLSessionWebSocketDelegate`'s handshake-outcome callbacks
/// (which fire on an arbitrary delegate queue, not the actor) into a single
/// `async` wait point `connect()` can race against a timeout. `reset()`
/// must be called before each new connection attempt so a stale open/error
/// from a previous attempt can't resolve the new one.
private final class OpenSignal: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var resolution: Result<Void, Error>?

    func reset() {
        lock.lock()
        continuation = nil
        resolution = nil
        lock.unlock()
    }

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let resolution {
                lock.unlock()
                continuation.resume(with: resolution)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        resolution = result
        lock.unlock()
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        resolve(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        resolve(.failure(error))
    }
}

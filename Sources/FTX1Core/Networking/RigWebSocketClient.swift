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
    private var heartbeatTask: Task<Void, Never>?
    private var lastActivity: Date = .distantPast

    public private(set) var state: ConnectionState = .disconnected

    /// Called on every state push received from the hub. Delivered on
    /// whatever executor the caller sets up — UI layers should hop to
    /// @MainActor themselves when updating SwiftUI state.
    public var onStateUpdate: (@Sendable (RigState) -> Void)?

    /// Called whenever `state` changes, including transitions that happen
    /// well after `connect()` already returned — e.g. the heartbeat below
    /// noticing a dead link. A caller that only reads `state` once, right
    /// after `connect()`, has no way to learn the connection later died: a
    /// "blackholed" link (the peer's network interface vanishes with no
    /// RST ever arriving) can leave `URLSessionWebSocketTask` looking
    /// connected for a very long time with no read error to trigger
    /// `markFailed` on its own.
    public var onStateChange: (@Sendable (ConnectionState) -> Void)?

    /// Called with the raw PCM payload of every audio frame received from
    /// the hub (tag byte already stripped) — see `AudioStreamFormat`. Never
    /// fires for a client that never sees an audio frame (Mac-only servers
    /// or an older hub build); delivered on whatever executor the caller
    /// sets up, same as `onStateUpdate`.
    public var onAudioData: (@Sendable (Data) -> Void)?

    public init(hubURL: URL) {
        self.url = hubURL
        self.session = URLSession(configuration: .default, delegate: openSignal, delegateQueue: nil)
    }

    public func setOnStateUpdate(_ handler: @escaping @Sendable (RigState) -> Void) {
        onStateUpdate = handler
    }

    public func setOnStateChange(_ handler: @escaping @Sendable (ConnectionState) -> Void) {
        onStateChange = handler
    }

    public func setOnAudioData(_ handler: @escaping @Sendable (Data) -> Void) {
        onAudioData = handler
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
        setState(.connecting)
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
            setState(.connected)
            listen()
            startHeartbeat()
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            self.task = nil
            setState(.failed(errorMessage(for: error)))
        }
    }

    private func errorMessage(for error: Error) -> String {
        if error is RigWebSocketError {
            return "Timed out connecting"
        }
        return error.localizedDescription
    }

    public func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setState(.disconnected)
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
                Task { await self.markFailed(error, from: task) }
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
        guard let data else { return }

        if AudioStreamFormat.isAudioFrame(data) {
            lastActivity = Date()
            onAudioData?(AudioStreamFormat.payload(of: data))
            return
        }

        guard let push = try? JSONDecoder().decode(RigStatePush.self, from: data) else { return }
        lastActivity = Date()
        onStateUpdate?(push.state)
    }

    /// `failedTask` guards against a stale callback from a task that's
    /// already been superseded (by `disconnect()` or a fresh `connect()`)
    /// clobbering current state — without it, a receive-failure callback
    /// that fires just after a clean, user-initiated `disconnect()` could
    /// flip `state` from `.disconnected` back to `.failed`.
    private func markFailed(_ error: Error, from failedTask: URLSessionWebSocketTask) {
        guard task === failedTask else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task = nil
        setState(.failed(error.localizedDescription))
    }

    private func setState(_ newState: ConnectionState) {
        state = newState
        onStateChange?(newState)
    }

    /// Periodically pings the hub and tracks how long it's been since we
    /// last heard *anything* back (a state push, or a successful pong) —
    /// needed because a blackholed link (e.g. the Mac's Tailscale interface
    /// disappearing) produces no TCP reset for the socket layer to react
    /// to; without an active probe, `URLSessionWebSocketTask` can sit
    /// looking connected indefinitely.
    ///
    /// Deliberately does *not* structurally await `sendPing`'s completion:
    /// on a genuinely blackholed connection that completion handler may
    /// simply never fire, and `withTaskGroup` waits for every child task to
    /// finish (even cancelled ones) before returning, which would let one
    /// hung ping wedge this whole loop forever — exactly the symptom this
    /// is meant to fix, not reintroduce. Firing the ping and separately
    /// polling elapsed time sidesteps that: a hung ping's completion
    /// handler is simply abandoned rather than awaited.
    private func startHeartbeat() {
        lastActivity = Date()
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                guard let self else { return }
                let shouldContinue = await self.heartbeatTick()
                if !shouldContinue { return }
            }
        }
    }

    /// Returns `false` once the link should be considered dead.
    private func heartbeatTick() -> Bool {
        guard state == .connected, let task else { return false }
        task.sendPing { [weak self] error in
            guard error == nil else { return }
            Task { await self?.recordActivity() }
        }
        guard Date().timeIntervalSince(lastActivity) <= 12 else {
            handleHeartbeatTimeout()
            return false
        }
        return true
    }

    private func recordActivity() {
        lastActivity = Date()
    }

    private func handleHeartbeatTimeout() {
        guard state == .connected else { return }
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        heartbeatTask = nil
        setState(.failed("Connection timed out"))
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

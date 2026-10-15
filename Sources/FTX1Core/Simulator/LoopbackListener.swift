import Foundation
import Network

/// A TCP listener on 127.0.0.1 only, on a port the system picks — the
/// Demo Mode simulator's servers (rigctld, audio, TX audio). Never reachable
/// from the network, and no fixed port to collide with a real rigctld on
/// the same machine (the iOS Simulator shares the Mac's loopback).
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    let queue: DispatchQueue

    /// `onConnection` runs on `queue` for each accepted connection, not yet
    /// started.
    init(label: String, onConnection: @escaping @Sendable (NWConnection) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        queue = DispatchQueue(label: "com.ftx1remote.simulator.\(label)")
        listener.newConnectionHandler = onConnection
    }

    /// Starts listening and returns the port once ready.
    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: SimulatorError.noPort)
                    }
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: SimulatorError.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [listener] in
                guard once.claim() else { return }
                listener.cancel()
                continuation.resume(throwing: SimulatorError.noPort)
            }
        }
    }

    func stop() {
        listener.cancel()
    }
}

public enum SimulatorError: Error, LocalizedError {
    case noPort
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noPort: "The demo simulator couldn't open a local port."
        case .cancelled: "The demo simulator was stopped."
        }
    }
}

/// True for the first `claim()` only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

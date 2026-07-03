import Foundation
import Network

/// Talks to rigctld over its plain-text TCP protocol on localhost:4532.
///
/// This is only ever instantiated by the Mac hub app — mobile apps go
/// through `RigWebSocketClient` instead and never see this type in practice
/// (it lives here rather than in a Mac-only target so the Mac app doesn't
/// need a second local package just for this one file).
public actor RigctldClient {
    private var connection: NWConnection?
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port

    public init(host: String = "127.0.0.1", port: UInt16 = 4532) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    public func connect() async throws {
        let conn = NWConnection(host: host, port: port, using: .tcp)
        self.connection = conn
        conn.start(queue: .global(qos: .userInitiated))
        // TODO: await conn.stateUpdateHandler reaching .ready before returning,
        // with a timeout — placeholder for now.
    }

    /// Sends a raw rigctld command (e.g. "F 14250000\n") and returns the
    /// single-line response. rigctld's protocol is request/response, so
    /// callers should serialize access via CommandQueue rather than firing
    /// concurrent requests at this client.
    public func send(_ command: String) async throws -> String {
        guard let connection else {
            throw RigctldError.notConnected
        }
        let data = (command + "\n").data(using: .utf8)!

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(throwing: RigctldError.badResponse)
                    return
                }
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

public enum RigctldError: Error {
    case notConnected
    case badResponse
}

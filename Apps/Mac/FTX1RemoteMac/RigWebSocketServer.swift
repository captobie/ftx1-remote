import FTX1Core
import Foundation
import Network

/// Mac-only WebSocket server. iOS/iPadOS clients (and the Mac's own local
/// UI, once it goes through `RigWebSocketClient` too) connect here to
/// receive `RigStatePush` updates and send `RigCommand`s.
///
/// Built on `NWListener` + `NWProtocolWebSocket` rather than a hand-rolled
/// WebSocket implementation, since `URLSessionWebSocketTask` (used by
/// `RigWebSocketClient`) is client-only — see repo README/CLAUDE.md.
actor RigWebSocketServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var latestState: RigState?
    private var onCommandReceived: (@Sendable (RigCommand) -> Void)?
    /// Whichever client most recently sent `.setPTT(true)`, if any. Unlike
    /// the Mac's own local PTT button (which calls `HubService` directly,
    /// no network in between), a remote client's connection can drop while
    /// it's mid-transmission — e.g. a phone losing Tailscale/Wi-Fi — and
    /// the "release" `.setPTT(false)` would then never arrive, leaving the
    /// radio keyed indefinitely. `remove(_:)` uses this to synthesize that
    /// release if the PTT-holding connection is the one that just closed.
    private var pttHolder: ObjectIdentifier?

    func start(port: UInt16, onCommand: @escaping @Sendable (RigCommand) -> Void) throws {
        guard listener == nil else { return }
        onCommandReceived = onCommand

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true

        // A connection whose peer just vanishes — e.g. the Mac's own
        // Tailscale interface being disabled mid-session — produces no RST
        // and, if the connection happens to be idle (no in-flight reads or
        // writes), the OS has no reason to ever notice on its own; the
        // NWConnection can sit reporting itself as healthy indefinitely.
        // Enabling TCP keepalive makes the kernel actively probe idle
        // connections, so a genuinely dead peer/interface gets detected
        // (and `.failed`/`.cancelled` fires, triggering PTT auto-release
        // below) within roughly idle + interval * count seconds instead of
        // never.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        tcpOptions.keepaliveInterval = 3
        tcpOptions.keepaliveCount = 3

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw RigWebSocketServerError.invalidPort
        }

        let listener = try NWListener(using: parameters, on: endpointPort)
        // A plain listener with no Bonjour service never gives macOS/iOS a
        // trigger point to show the Local Network permission prompt — it
        // just silently blocks non-loopback inbound connections forever,
        // with no dialog and no error. Advertising a (unused) Bonjour
        // service is what actually causes the OS to ask. iOS/mobile clients
        // still connect directly by Tailscale IP:port; nothing browses for
        // this service.
        listener.service = NWListener.Service(name: "FTX1 Remote Hub", type: "_ftx1remote._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        latestState = nil
        onCommandReceived = nil
    }

    /// Sends the given state to every connected client, and remembers it so
    /// clients that connect afterwards get an immediate snapshot instead of
    /// waiting for the next poll tick.
    func broadcast(_ state: RigState) {
        latestState = state
        guard let data = try? JSONEncoder().encode(RigStatePush(state: state)) else { return }
        for connection in connections.values {
            connection.send(data)
        }
    }

    private func accept(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        let client = Connection(
            connection: connection,
            onCommand: { [weak self] command in
                Task { await self?.handleCommand(command, from: connectionID) }
            },
            onClose: { [weak self] id in
                Task { await self?.remove(id) }
            }
        )
        connections[client.id] = client
        client.start()

        if let latestState, let data = try? JSONEncoder().encode(RigStatePush(state: latestState)) {
            client.send(data)
        }
    }

    private func handleCommand(_ command: RigCommand, from id: ObjectIdentifier) {
        if case .setPTT(let on) = command {
            // Only the current holder's own .setPTT(false) clears it — an
            // unrelated client's release shouldn't cancel someone else's
            // active transmission. (This tool is single-operator in
            // practice; concurrent multi-client PTT isn't specially
            // handled beyond not letting one client clobber another's
            // holder tracking.)
            pttHolder = on ? id : (pttHolder == id ? nil : pttHolder)
        }
        onCommandReceived?(command)
    }

    private func remove(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
        if pttHolder == id {
            pttHolder = nil
            onCommandReceived?(.setPTT(false))
        }
    }
}

enum RigWebSocketServerError: Error {
    case invalidPort
}

/// Wraps one accepted `NWConnection`, doing the WebSocket message send/
/// receive loop and JSON encode/decode against the shared wire types.
private final class Connection {
    let id: ObjectIdentifier

    private let connection: NWConnection
    private let onCommand: (RigCommand) -> Void
    private let onClose: (ObjectIdentifier) -> Void

    init(
        connection: NWConnection,
        onCommand: @escaping (RigCommand) -> Void,
        onClose: @escaping (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.id = ObjectIdentifier(connection)
        self.onCommand = onCommand
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.onClose(self.id)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop()
    }

    func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "state", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil else {
                self.onClose(self.id)
                return
            }
            if let data, let command = try? JSONDecoder().decode(RigCommand.self, from: data) {
                self.onCommand(command)
            }
            self.receiveLoop()
        }
    }
}

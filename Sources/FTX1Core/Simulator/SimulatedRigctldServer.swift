import Foundation
import Network

/// rigctld's TCP protocol on loopback, answered by a `SimulatedRig`: one
/// request per "\n"-terminated line, answered in order, each answer
/// possibly after a pause (`SimulatedRig.Reply.delay`), like the real
/// rigctld's one-command-at-a-time handling. Several clients at once, as
/// rigctld allows.
public final class SimulatedRigctldServer: @unchecked Sendable {
    public let rig: SimulatedRig
    private var listener: LoopbackListener?
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: RigctldConnection] = [:]

    public init(rig: SimulatedRig) {
        self.rig = rig
    }

    /// Starts listening; returns the port.
    public func start() async throws -> UInt16 {
        let listener = try LoopbackListener(label: "rigctld") { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        return try await listener.start()
    }

    public func stop() {
        listener?.stop()
        listener = nil
        let open = lock.withLock {
            let open = connections.values
            connections = [:]
            return Array(open)
        }
        open.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard let queue = listener?.queue else { return connection.cancel() }
        let handler = RigctldConnection(connection: connection, rig: rig, queue: queue) { [weak self] closed in
            self?.lock.withLock { _ = self?.connections.removeValue(forKey: ObjectIdentifier(closed)) }
        }
        lock.withLock { connections[ObjectIdentifier(handler)] = handler }
        handler.start()
    }
}

/// One client: buffers bytes into lines and answers them strictly in order.
/// Everything runs on the listener's serial queue.
private final class RigctldConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let rig: SimulatedRig
    private let queue: DispatchQueue
    private let onClose: (RigctldConnection) -> Void
    private var buffer = Data()
    private var pending: [String] = []
    private var answering = false
    private var closed = false

    init(connection: NWConnection, rig: SimulatedRig, queue: DispatchQueue, onClose: @escaping (RigctldConnection) -> Void) {
        self.connection = connection
        self.rig = rig
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        queue.async { self.close() }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: self.buffer[self.buffer.startIndex..<newline], as: UTF8.self)
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    self.pending.append(line)
                }
                self.answerNext()
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func answerNext() {
        guard !answering, !closed, !pending.isEmpty else { return }
        let line = pending.removeFirst()
        guard let reply = rig.handle(line) else { return answerNext() }
        answering = true
        let send = { [weak self] in
            guard let self, !self.closed else { return }
            if !reply.bytes.isEmpty {
                self.connection.send(content: Data(reply.bytes), completion: .contentProcessed { _ in })
            }
            self.answering = false
            self.answerNext()
        }
        if reply.delay > 0 {
            queue.asyncAfter(deadline: .now() + reply.delay, execute: send)
        } else {
            send()
        }
    }
}

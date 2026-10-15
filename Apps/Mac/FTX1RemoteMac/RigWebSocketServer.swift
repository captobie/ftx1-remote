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
    /// Set once `listener` actually reports `.ready`, cleared on
    /// `.failed`/`.waiting`/`.cancelled` — see `isListening()`. A bind
    /// conflict (e.g. the port still held by a just-killed previous
    /// instance) was confirmed by testing to report as `.waiting`, not
    /// `.failed` — `listener != nil` alone isn't a reliable "is this
    /// actually accepting connections" signal, since `listener` gets
    /// assigned as soon as `NWListener.start(queue:)` is called, well
    /// before the OS confirms the bind actually succeeded.
    private var isReady = false
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var latestState: RigState?
    /// Sent to each client on connect, like `latestState`.
    private var latestMemoryList: MemoryListSnapshot?
    /// Encoded once per change, since it's the whole APRS history.
    private var latestAPRSList: Data?
    private var onCommandReceived: (@Sendable (RigCommand) -> Void)?
    /// Whichever client most recently sent `.setPTT(true)`, if any. Unlike
    /// the Mac's own local PTT button (which calls `HubService` directly,
    /// no network in between), a remote client's connection can drop while
    /// it's mid-transmission — e.g. a phone losing Tailscale/Wi-Fi — and
    /// the "release" `.setPTT(false)` would then never arrive, leaving the
    /// radio keyed indefinitely. `remove(_:)` uses this to synthesize that
    /// release if the PTT-holding connection is the one that just closed.
    private var pttHolder: ObjectIdentifier?
    /// Transmit audio (`AudioStreamFormat.txAudioTag`) from the client
    /// holding PTT; frames from anyone else are dropped.
    private var onTXAudioReceived: (@Sendable (Data) -> Void)?
    /// Reads one Deep Settings item for a client's `MenuItemReadRequest`;
    /// the answer goes back to that client only.
    private var onMenuItemRead: (@Sendable (Int, Int, Int) async -> String?)?
    /// Writes or checks a CW TEXT keyer memory for a client's
    /// `CWKeyerRequest` (slot, text — nil = make it a TEXT memory); returns
    /// what the rig stored, or throws. The answer goes back to that client.
    private var onCWKeyer: (@Sendable (Int, String?) async throws -> String?)?
    /// Whichever client most recently played a CW TEXT keyer memory
    /// ("KY0<n>", the iPad's CW send section). If it drops mid-message,
    /// `remove(_:)` stops the keyer ("KY00"), as it unkeys a dropped PTT
    /// holder — the rig would otherwise finish its up-to-50 characters.
    private var keyerPlayer: ObjectIdentifier?

    // MARK: CW keyer coordinator

    /// Who may use the rig's CW TEXT keyer memory right now: the Mac's own
    /// CW window or one hub client (the iPad's CW send section). Each
    /// sender takes it before every chunk and gives it back after each
    /// line (`CWSender`), so two senders can't overwrite the memory or
    /// restart each other's message mid-line ("KY" while one plays restarts
    /// it). A client's write or play without it is refused; "KY00" (stop)
    /// always goes through. Released after `keyerLeaseTimeout` with no
    /// keyer activity, so a stuck or blocked sender can't hold it forever,
    /// and when the holding client disconnects.
    enum KeyerHolder: Equatable, Sendable {
        case mac
        case client(ObjectIdentifier)
    }
    private var keyerHolder: KeyerHolder?
    private var keyerHolderActiveAt = Date.distantPast
    private static let keyerLeaseTimeout: TimeInterval = 30

    /// Everything clients send, in arrival order: commands and transmit
    /// audio share one stream so a client's `.setPTT(true)` is always
    /// handled before its first audio frame (separate `Task`s per message
    /// could reorder them, and drop that frame as not-from-the-holder).
    private enum Inbound: Sendable {
        case command(RigCommand, ObjectIdentifier)
        case txAudio(Data, ObjectIdentifier)
        case menuItemRead(MenuItemReadRequest, ObjectIdentifier)
        case cwKeyer(CWKeyerRequest, ObjectIdentifier)
    }
    private let inbound: AsyncStream<Inbound>
    private let inboundContinuation: AsyncStream<Inbound>.Continuation
    private var inboundTask: Task<Void, Never>?

    init() {
        (inbound, inboundContinuation) = AsyncStream<Inbound>.makeStream()
    }

    func start(
        port: UInt16,
        onCommand: @escaping @Sendable (RigCommand) -> Void,
        onTXAudio: @escaping @Sendable (Data) -> Void = { _ in },
        onMenuItemRead: @escaping @Sendable (Int, Int, Int) async -> String? = { _, _, _ in nil },
        onCWKeyer: @escaping @Sendable (Int, String?) async throws -> String? = { _, _ in nil }
    ) throws {
        guard listener == nil else { return }
        onCommandReceived = onCommand
        onTXAudioReceived = onTXAudio
        self.onMenuItemRead = onMenuItemRead
        self.onCWKeyer = onCWKeyer
        if inboundTask == nil {
            let inbound = inbound
            inboundTask = Task { [weak self] in
                for await message in inbound {
                    await self?.handle(message)
                }
            }
        }

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
        // A listener that fails to bind (e.g. the port still held by a
        // just-killed previous instance) reports that asynchronously via
        // this handler — confirmed by testing against a real port
        // conflict to be `.waiting`, not `.failed` — not by throwing from
        // `start(queue:)` below. Without watching for it, `self.listener`
        // stays set to a listener that's never actually accepting
        // connections forever, and `start(port:)`'s `guard listener ==
        // nil` then silently no-ops on every future call, permanently
        // disabling the WebSocket server for the rest of this process's
        // life with no visible error anywhere (the Mac's own local UI
        // never touches this server — see this type's doc comment — so
        // nothing else would ever notice either). Clearing `self.listener`
        // on `.failed`/`.waiting` is what lets `HubService`'s retry loop
        // actually rebind once the port frees up, rather than trusting
        // NWListener's own internal `.waiting` recovery, which testing
        // showed does not reliably happen on its own within a reasonable
        // time. `[weak listener]` guards against a late callback from an
        // already-replaced listener (a fast stop()+start()) clobbering the
        // new one.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                Task { await self?.handleListenerReady(listener) }
            case .failed, .waiting:
                Task { await self?.handleListenerNotReady(listener) }
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func handleListenerReady(_ readyListener: NWListener?) {
        guard readyListener === listener else { return }
        isReady = true
    }

    private func handleListenerNotReady(_ notReadyListener: NWListener?) {
        guard notReadyListener === listener else { return }
        listener?.cancel()
        listener = nil
        isReady = false
    }

    /// Whether the listener has actually reached `.ready` — see `isReady`'s
    /// doc comment for why `listener != nil` alone isn't sufficient. Polled
    /// by `HubService`'s retry loop rather than making `start` itself await
    /// a bind confirmation, since nothing here needs to block on that.
    func isListening() -> Bool {
        isReady
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isReady = false
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

    /// Sends the memory channel list (`MemoryListPush`) to every connected
    /// client, and remembers it for clients that connect later.
    func broadcastMemoryList(_ list: MemoryListSnapshot) {
        latestMemoryList = list
        guard let data = try? JSONEncoder().encode(MemoryListPush(list: list)) else { return }
        for connection in connections.values {
            connection.send(data)
        }
    }

    /// Sends the decoded APRS history (`APRSListPush`) to every connected
    /// client, and remembers it for clients that connect later.
    func broadcastAPRSList(_ push: APRSListPush) {
        guard let data = try? JSONEncoder().encode(push) else { return }
        latestAPRSList = data
        for connection in connections.values {
            connection.send(data)
        }
    }

    /// Relays one chunk of the Mac's captured Main-channel radio audio (see
    /// `AudioStreamEncoder`) to every connected client, tagged so
    /// `RigWebSocketClient` can tell it apart from `RigStatePush` JSON
    /// before decoding. No-ops when nobody's connected — the caller doesn't
    /// need to check that itself before encoding.
    func broadcastAudio(_ pcm: Data) {
        guard !connections.isEmpty else { return }
        let framed = AudioStreamFormat.frame(pcm)
        for connection in connections.values {
            connection.send(framed)
        }
    }

    /// Sub-channel counterpart to `broadcastAudio(_:)` — same shape, tagged
    /// with `AudioStreamFormat.subAudioTag` instead.
    func broadcastSubAudio(_ pcm: Data) {
        guard !connections.isEmpty else { return }
        let framed = AudioStreamFormat.subFrame(pcm)
        for connection in connections.values {
            connection.send(framed)
        }
    }

    private func accept(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        let inbound = inboundContinuation
        let client = Connection(
            connection: connection,
            onCommand: { command in
                inbound.yield(.command(command, connectionID))
            },
            onTXAudio: { pcm in
                inbound.yield(.txAudio(pcm, connectionID))
            },
            onMenuItemRead: { request in
                inbound.yield(.menuItemRead(request, connectionID))
            },
            onCWKeyer: { request in
                inbound.yield(.cwKeyer(request, connectionID))
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
        if let latestMemoryList, let data = try? JSONEncoder().encode(MemoryListPush(list: latestMemoryList)) {
            client.send(data)
        }
        if let latestAPRSList {
            client.send(latestAPRSList)
        }
    }

    private func handle(_ message: Inbound) {
        switch message {
        case .command(let command, let id):
            handleCommand(command, from: id)
        case .txAudio(let pcm, let id):
            guard id == pttHolder else { return }
            onTXAudioReceived?(pcm)
        case .menuItemRead(let request, let id):
            // Off the inbound stream: a read takes a rigctld round trip,
            // and commands behind it shouldn't wait for that.
            guard let read = onMenuItemRead else { return }
            Task {
                let value = await read(request.p1, request.p2, request.p3)
                self.reply(MenuItemPush(p1: request.p1, p2: request.p2, p3: request.p3, value: value), to: id)
            }
        case .cwKeyer(let request, let id):
            switch request.action {
            case .acquire:
                let busy = acquireKeyer(.client(id))
                reply(CWKeyerReply(id: request.id, stored: nil, error: nil, busy: busy), to: id)
                return
            case .release:
                releaseKeyer(.client(id))
                reply(CWKeyerReply(id: request.id, stored: nil, error: nil), to: id)
                return
            case nil:
                break
            }
            guard holdsKeyer(.client(id)) else {
                let who = keyerHolder.map { describe($0, to: .client(id)) } ?? "nobody"
                reply(CWKeyerReply(id: request.id, stored: nil,
                                   error: "The keyer isn't yours to write (held by \(who))"), to: id)
                return
            }
            // Off the stream too: a keyer write takes ~2 s over the Pi. The
            // client waits for this answer before it plays the memory, so
            // the play can't overtake the write.
            guard let keyer = onCWKeyer else { return }
            Task {
                let reply: CWKeyerReply
                do {
                    let stored = try await keyer(request.slot, request.text)
                    reply = CWKeyerReply(id: request.id, stored: stored, error: nil)
                } catch {
                    reply = CWKeyerReply(id: request.id, stored: nil, error: error.localizedDescription)
                }
                self.reply(reply, to: id)
            }
        }
    }

    /// The keyer lease for `holder`: nil if granted (or already held —
    /// that refreshes it), otherwise who has it, for the waiting sender.
    func acquireKeyer(_ holder: KeyerHolder) -> String? {
        if let current = keyerHolder, current != holder,
           Date().timeIntervalSince(keyerHolderActiveAt) < Self.keyerLeaseTimeout {
            return describe(current, to: holder)
        }
        keyerHolder = holder
        keyerHolderActiveAt = Date()
        return nil
    }

    func releaseKeyer(_ holder: KeyerHolder) {
        if keyerHolder == holder { keyerHolder = nil }
    }

    /// Whether `holder` holds the lease now; refreshes it if so.
    private func holdsKeyer(_ holder: KeyerHolder) -> Bool {
        guard keyerHolder == holder,
              Date().timeIntervalSince(keyerHolderActiveAt) < Self.keyerLeaseTimeout else { return false }
        keyerHolderActiveAt = Date()
        return true
    }

    private func describe(_ current: KeyerHolder, to asker: KeyerHolder) -> String {
        switch current {
        case .mac: "the Mac's CW window"
        case .client: asker == .mac ? "a device on the hub" : "another device on the hub"
        }
    }

    /// Sends an answer to the one client that asked, if it's still
    /// connected.
    private func reply(_ push: some Encodable, to id: ObjectIdentifier) {
        guard let connection = connections[id], let data = try? JSONEncoder().encode(push) else { return }
        connection.send(data)
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
        if case .playCWTextMemory(let slot) = command {
            // Playing needs the keyer lease (stopping never does).
            if slot != 0, !holdsKeyer(.client(id)) {
                return
            }
            keyerPlayer = slot != 0 ? id : (keyerPlayer == id ? nil : keyerPlayer)
        }
        onCommandReceived?(command)
    }

    private func remove(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
        if pttHolder == id {
            pttHolder = nil
            onCommandReceived?(.setPTT(false))
        }
        if keyerPlayer == id {
            keyerPlayer = nil
            onCommandReceived?(.playCWTextMemory(slot: 0))
        }
        releaseKeyer(.client(id))
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
    private let onTXAudio: (Data) -> Void
    private let onMenuItemRead: (MenuItemReadRequest) -> Void
    private let onCWKeyer: (CWKeyerRequest) -> Void
    private let onClose: (ObjectIdentifier) -> Void

    init(
        connection: NWConnection,
        onCommand: @escaping (RigCommand) -> Void,
        onTXAudio: @escaping (Data) -> Void,
        onMenuItemRead: @escaping (MenuItemReadRequest) -> Void,
        onCWKeyer: @escaping (CWKeyerRequest) -> Void,
        onClose: @escaping (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.id = ObjectIdentifier(connection)
        self.onCommand = onCommand
        self.onTXAudio = onTXAudio
        self.onMenuItemRead = onMenuItemRead
        self.onCWKeyer = onCWKeyer
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
            if let data, AudioStreamFormat.isTXAudioFrame(data) {
                self.onTXAudio(Data(AudioStreamFormat.payload(of: data)))
            } else if let data, let command = try? JSONDecoder().decode(RigCommand.self, from: data) {
                self.onCommand(command)
            } else if let data, let request = try? JSONDecoder().decode(MenuItemReadRequest.self, from: data),
                      request.type == MenuItemReadRequest.typeName {
                self.onMenuItemRead(request)
            } else if let data, let request = try? JSONDecoder().decode(CWKeyerRequest.self, from: data),
                      request.type == CWKeyerRequest.typeName {
                self.onCWKeyer(request)
            }
            self.receiveLoop()
        }
    }
}

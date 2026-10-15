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
    /// The hub's memory channel list (`MemoryListPush`) — nil until the hub
    /// sends one (an older hub never does). Changes at most once a second.
    @Published public private(set) var memoryList: MemoryListSnapshot?
    /// The hub's decoded APRS history (`APRSListPush`), for the iPad's
    /// S.LIST/M.LIST pane — nil until the hub sends one (an older hub
    /// never does). Changes at most every 2 s.
    @Published public private(set) var aprsList: APRSListPush?

    /// Plays back the Mac's relayed Main-channel radio audio — see
    /// `AudioPlaybackEngine`. Started/stopped alongside the connection
    /// itself (`apply(_:)`/`disconnect()`), not tied to any particular view
    /// being on screen.
    public let audioEngine = AudioPlaybackEngine()
    /// Sub-channel counterpart to `audioEngine` (2026-09-18) — its own
    /// independent `AudioPlaybackEngine` instance, fed from
    /// `RigWebSocketClient.onSubAudioData`. Simply never receives any
    /// pushes against a hub that isn't relaying Sub (see
    /// `RigWebSocketClient.onSubAudioData`'s doc comment) — no separate
    /// "is Sub available" flag needed here either, same reasoning as the
    /// Mac side.
    public let subAudioEngine = AudioPlaybackEngine()

    /// The Filter Function Display's spectrum, computed here from the same
    /// relayed audio (before the mute/transmit checks) — see
    /// `FilterSpectrumStore`. Its own object so the per-chunk updates
    /// re-render only the display.
    public let filterSpectrum = FilterSpectrumStore()

    /// Every 8 kHz receive chunk (`AudioStreamFormat`), MAIN and SUB, on
    /// the main actor, before the mute/transmit checks — for the iPad's CW
    /// decoder, which lives in `FTX1CW` and so can't be named here.
    public var onReceiveAudio: (@MainActor (Data, FilterSide) -> Void)?

    /// Mirrors `HubService.isMainAudioMuted`/`isSubAudioMuted` on the Mac —
    /// same shape (`private(set)` + an explicit toggle method, since this
    /// is a discrete action rather than a continuously-adjustable value
    /// like volume/squelch), same persisted `AudioPlaybackSettings` keys
    /// (though each device's `UserDefaults` is its own — see that enum's
    /// doc comment, "never synced between devices"). Doesn't stop/start
    /// either engine itself — muting just gates whether the relevant
    /// `onAudioData`/`onSubAudioData` closure below pushes into it, so
    /// un-muting resumes instantly.
    @Published public private(set) var isMainAudioMuted = AudioPlaybackSettings.isMuted
    @Published public private(set) var isSubAudioMuted = AudioPlaybackSettings.subIsMuted

    /// This client is holding PTT (press to release, plus the unkey
    /// delay) — drives the iPad's PTT button and mutes receive playback,
    /// so the rig's monitor audio can't feed back into the microphone.
    @Published public private(set) var isTransmitting = false
    /// Set when a press couldn't transmit audio (no microphone access, the
    /// microphone wouldn't start); cleared on the next press.
    @Published public private(set) var transmitProblem: String?

    private var client: RigWebSocketClient?
    private let port: UInt16
    /// Deep Settings reads waiting for the hub's `MenuItemPush`, by item
    /// address ("p1.p2.p3"); a second read of the same item joins the
    /// first rather than asking again.
    /// `token` ties a request's timeout to that request, so a timeout left
    /// over from an earlier read of the same item can't end a later one.
    private var pendingMenuReads: [String: (token: UUID, waiting: [CheckedContinuation<String?, Never>])] = [:]
    /// Long enough for a whole tab read one at a time over the Pi
    /// (~20 items, interleaved with the hub's poll); a hub that predates
    /// `MenuItemReadRequest` never answers.
    private static let menuReadTimeout: Duration = .seconds(10)
    /// CW keyer requests waiting for the hub's `CWKeyerReply`, by id.
    private var pendingKeyerRequests: [Int: CheckedContinuation<CWKeyerReply?, Never>] = [:]
    private var nextKeyerRequestID = 1
    /// A keyer write takes ~2 s over the Pi, behind the hub's own poll
    /// round trips; a hub that predates `CWKeyerRequest` never answers.
    private static let keyerTimeout: Duration = .seconds(15)
    #if os(iOS)
    private let microphone = MicrophoneTransmitter(logSubsystem: "com.ftx1remote.client")
    private var unkeyTask: Task<Void, Never>?
    #endif

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
                Task { @MainActor in
                    guard let self else { return }
                    self.rigState = state
                    self.filterSpectrum.selectedSide = state.activeFilterSide
                }
            }
            // Not just a one-shot read after connect(): the client can
            // transition later on its own (e.g. its heartbeat detecting a
            // dead link), and without this the UI would keep showing
            // "Connected" forever after the Mac actually became
            // unreachable.
            await client.setOnStateChange { [weak self] state in
                Task { @MainActor in self?.apply(state) }
            }
            await client.setOnMemoryList { [weak self] list in
                Task { @MainActor in self?.memoryList = list }
            }
            await client.setOnAPRSList { [weak self] push in
                Task { @MainActor in self?.aprsList = push }
            }
            await client.setOnCWKeyerReply { [weak self] reply in
                Task { @MainActor in self?.finishKeyerRequest(reply.id, reply: reply) }
            }
            await client.setOnMenuItem { [weak self] push in
                Task { @MainActor in
                    self?.finishMenuRead(Self.menuReadKey(push.p1, push.p2, push.p3), value: push.value)
                }
            }
            await client.setOnAudioData { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.filterSpectrum.ingest(pcm: data, side: .main)
                    self.onReceiveAudio?(data, .main)
                    guard !self.isMainAudioMuted, !self.isTransmitting else { return }
                    self.audioEngine.push(pcm: data)
                }
            }
            await client.setOnSubAudioData { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.filterSpectrum.ingest(pcm: data, side: .sub)
                    self.onReceiveAudio?(data, .sub)
                    guard !self.isSubAudioMuted, !self.isTransmitting else { return }
                    self.subAudioEngine.push(pcm: data)
                }
            }
            await client.connect()
            await self.refreshConnectionState()
        }
    }

    public func disconnect() {
        guard let client else { return }
        #if os(iOS)
        // The hub unkeys a client that leaves holding PTT, but say so
        // anyway rather than rely on it.
        if isTransmitting {
            microphone.stop()
            unkeyTask?.cancel()
            unkeyTask = nil
            Task { try? await client.send(.setPTT(false)) }
            isTransmitting = false
        }
        #endif
        Task { await client.disconnect() }
        self.client = nil
        connectionState = .disconnected
        memoryList = nil
        aprsList = nil
        finishAllMenuReads()
        filterSpectrum.reset()
        audioEngine.stop()
        subAudioEngine.stop()
    }

    public func send(_ command: RigCommand) {
        guard let client else { return }
        Task { try? await client.send(command) }
    }

    /// Deep Settings on the hub route: the hub reads the item from the rig
    /// and answers this client alone (`MenuItemReadRequest`/`MenuItemPush`).
    public var supportsDeepSettings: Bool { true }

    /// S.LIST/M.LIST show the Mac's decoded lists (`aprsList`).
    public var supportsAPRSDecoding: Bool { true }

    public func readMenuItem(p1: Int, p2: Int, p3: Int) async -> String? {
        guard let client, connectionState == .connected else { return nil }
        let key = Self.menuReadKey(p1, p2, p3)
        return await withCheckedContinuation { continuation in
            if pendingMenuReads[key] != nil {
                pendingMenuReads[key]?.waiting.append(continuation)
                return
            }
            let token = UUID()
            pendingMenuReads[key] = (token, [continuation])
            Task {
                do {
                    try await client.sendMenuItemRead(p1: p1, p2: p2, p3: p3)
                } catch {
                    self.finishMenuRead(key, value: nil, token: token)
                    return
                }
                try? await Task.sleep(for: Self.menuReadTimeout)
                self.finishMenuRead(key, value: nil, token: token)
            }
        }
    }

    private static func menuReadKey(_ p1: Int, _ p2: Int, _ p3: Int) -> String {
        "\(p1).\(p2).\(p3)"
    }

    /// Resumes everyone waiting on `key`; a no-op once they have been
    /// (an answer after the timeout, or the timeout after an answer). With
    /// a `token`, only if it's still that request's.
    private func finishMenuRead(_ key: String, value: String?, token: UUID? = nil) {
        guard let pending = pendingMenuReads[key], token == nil || pending.token == token else { return }
        pendingMenuReads.removeValue(forKey: key)
        pending.waiting.forEach { $0.resume(returning: value) }
    }

    private func finishAllMenuReads() {
        let waiting = pendingMenuReads.values.flatMap(\.waiting)
        pendingMenuReads.removeAll()
        waiting.forEach { $0.resume(returning: nil) }
        // Keyer requests end with the link the same way.
        let keyer = pendingKeyerRequests.values
        pendingKeyerRequests.removeAll()
        keyer.forEach { $0.resume(returning: nil) }
    }

    // MARK: - CW keyer memory (the iPad's CW send section)

    /// Writes CW TEXT keyer memory `slot` through the hub
    /// (`CWKeyerRequest`) and returns what the rig stored. Doesn't
    /// transmit; playing is `.playCWTextMemory`, which the hub gates.
    public func writeCWKeyerMemory(slot: Int, text: String) async throws -> String {
        try await keyerRequest(slot: slot, text: text) ?? ""
    }

    /// Makes sure keyer memory `slot` is a TEXT memory, through the hub.
    public func ensureCWTextMemory(slot: Int) async throws {
        _ = try await keyerRequest(slot: slot, text: nil)
    }

    private func keyerRequest(slot: Int, text: String?) async throws -> String? {
        guard let client, connectionState == .connected else { throw CWKeyerRequestError.notConnected }
        let id = nextKeyerRequestID
        nextKeyerRequestID += 1
        let reply = await withCheckedContinuation { continuation in
            pendingKeyerRequests[id] = continuation
            Task {
                do {
                    try await client.sendCWKeyer(CWKeyerRequest(id: id, slot: slot, text: text))
                } catch {
                    self.finishKeyerRequest(id, reply: nil)
                    return
                }
                try? await Task.sleep(for: Self.keyerTimeout)
                self.finishKeyerRequest(id, reply: nil)
            }
        }
        guard let reply else { throw CWKeyerRequestError.noReply }
        if let error = reply.error { throw CWKeyerRequestError.failed(error) }
        return reply.stored
    }

    /// A no-op once that request has been answered (an answer after the
    /// timeout, or the timeout after an answer).
    private func finishKeyerRequest(_ id: Int, reply: CWKeyerReply?) {
        pendingKeyerRequests.removeValue(forKey: id)?.resume(returning: reply)
    }

    #if os(iOS)
    /// PTT pressed: key, then stream the microphone to the hub, which plays
    /// it into the rig (`HubService`). The first press only asks for
    /// microphone access — the prompt takes the press — and keys nothing.
    /// The view checks the hub's gate (`canTransmit`) before calling; the
    /// hub enforces it regardless.
    public func startTransmit() {
        guard let client, connectionState == .connected else { return }
        transmitProblem = nil
        guard TXAudioCapture.permissionGranted else {
            Task {
                if await !TXAudioCapture.requestPermission() {
                    transmitProblem = "Microphone access is off — allow it in Settings to transmit audio"
                }
            }
            return
        }
        if let unkeyTask {
            // Pressed again within the unkey delay: still keyed, carry on.
            unkeyTask.cancel()
            self.unkeyTask = nil
        } else {
            send(.setPTT(true))
        }
        isTransmitting = true
        // Off for the press (muted anyway) so the session can switch to
        // recording — see `TXAudioCapture`.
        audioEngine.stop()
        subAudioEngine.stop()
        do {
            try microphone.start { pcm in
                try? await client.sendTXAudio(pcm)
            }
        } catch {
            transmitProblem = "Microphone didn't start: \(error.localizedDescription)"
            // Keyed with nothing to send: unkey rather than carry dead air.
            stopTransmit()
        }
    }

    /// PTT released: stop the microphone, unkey once the audio in flight
    /// has played out.
    public func stopTransmit() {
        guard isTransmitting, unkeyTask == nil else { return }
        microphone.stop()
        resumeReceiveAudio()
        unkeyTask = Task { [weak self] in
            try? await Task.sleep(for: MicrophoneTransmitter.unkeyDelay)
            guard let self, !Task.isCancelled else { return }
            self.send(.setPTT(false))
            self.isTransmitting = false
            self.unkeyTask = nil
        }
    }

    /// Back on `.playback` after a press; muted until the unkey lands.
    private func resumeReceiveAudio() {
        guard connectionState == .connected else { return }
        audioEngine.start()
        subAudioEngine.start()
    }
    #endif

    /// See `HubService.toggleMainAudioMuted()`'s doc comment — identical
    /// shape.
    public func toggleMainAudioMuted() {
        isMainAudioMuted.toggle()
        AudioPlaybackSettings.isMuted = isMainAudioMuted
    }

    public func toggleSubAudioMuted() {
        isSubAudioMuted.toggle()
        AudioPlaybackSettings.subIsMuted = isSubAudioMuted
    }

    private func refreshConnectionState() async {
        guard let client else { return }
        apply(await client.state)
    }

    private func apply(_ state: RigWebSocketClient.ConnectionState) {
        #if os(iOS)
        // The link is gone, so there's no one to unkey through: the hub
        // unkeys a client that drops while holding PTT.
        if state != .connected, isTransmitting {
            microphone.stop()
            unkeyTask?.cancel()
            unkeyTask = nil
            isTransmitting = false
        }
        #endif
        switch state {
        case .disconnected:
            connectionState = .disconnected
            finishAllMenuReads()
            audioEngine.stop()
            subAudioEngine.stop()
        case .connecting:
            connectionState = .connecting
        case .connected:
            connectionState = .connected
            audioEngine.start()
            subAudioEngine.start()
        case .failed(let message):
            connectionState = .failed(message)
            finishAllMenuReads()
            audioEngine.stop()
            subAudioEngine.stop()
        }
    }
}

/// Why a hub-route keyer request (`RigClientViewModel.writeCWKeyerMemory`/
/// `ensureCWTextMemory`) didn't go through.
public enum CWKeyerRequestError: LocalizedError, Equatable {
    case notConnected
    /// No `CWKeyerReply` in time — most likely a Mac app from before CW
    /// sending on the hub route.
    case noReply
    /// The hub answered with an error (e.g. the rig rejected the write).
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Mac"
        case .noReply: "The Mac didn't answer — update the Mac app to send CW from here"
        case .failed(let message): message
        }
    }
}

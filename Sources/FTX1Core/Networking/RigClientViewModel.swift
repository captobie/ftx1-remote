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
            await client.setOnAudioData { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self, !self.isMainAudioMuted else { return }
                    self.audioEngine.push(pcm: data)
                }
            }
            await client.setOnSubAudioData { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self, !self.isSubAudioMuted else { return }
                    self.subAudioEngine.push(pcm: data)
                }
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
        audioEngine.stop()
        subAudioEngine.stop()
    }

    public func send(_ command: RigCommand) {
        guard let client else { return }
        Task { try? await client.send(command) }
    }

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
        switch state {
        case .disconnected:
            connectionState = .disconnected
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
            audioEngine.stop()
            subAudioEngine.stop()
        }
    }
}

import Combine
import FTX1Core
import Foundation
import os

/// Proof of concept (2026-10-05): the iPhone talking to the Pi's rigctld
/// directly over Tailscale, without the Mac hub. A deliberate, contained
/// exception to "mobile apps never talk to rigctld" (see repo root
/// CLAUDE.md) — lives in the iOS target only, and the Mac-hub path
/// (`RigClientViewModel`) is untouched.
///
/// Receive-only: there's no PTT here, because the Enable Transmit and
/// amateur-band gates live in `HubService.send(_:)`, which this path
/// bypasses entirely. Port a gate first (like Windows' `TransmitGate`)
/// before adding any transmit-capable control.
///
/// rigctld accepts several clients at once, so this coexists with the Mac
/// (or WSJT-X) being connected to the same Pi.
///
/// Audio (milestone 2): a separate `RemoteAudioStreamClient` connection to
/// `Pi/ftx1-audiostream.py` (:8532), its own retry loop independent of the
/// rigctld link. Plays the left channel only — Main, unless the rig's
/// Main/Sub have been swapped (the Mac's `audioChannelsSwapped` tracking
/// isn't ported). The Pi serves one audio client at a time, so while the
/// Mac holds the stream this stays at `.waiting`.
@MainActor
final class PiDirectViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var rigState = RigState()
    @Published private(set) var connectionState: ConnectionState = .disconnected

    enum AudioState: Equatable {
        case off
        /// Connected (or retrying) but no samples lately — the Pi
        /// unreachable on :8532, or another client (the Mac) holding the
        /// stream.
        case waiting
        case playing
    }

    @Published private(set) var audioState: AudioState = .off
    /// Same persisted key as the Mac-hub path's Main mute
    /// (`RigClientViewModel.isMainAudioMuted`) — one mute for "the Main
    /// audio on this phone", whichever route it comes from.
    @Published private(set) var isAudioMuted = AudioPlaybackSettings.isMuted

    /// Fixed, like the Mac's `.remote` mode — only the host is configurable.
    private static let rigctldPort: UInt16 = 4532
    private static let pollInterval: Duration = .seconds(1)
    private static let reconnectDelay: Duration = .seconds(3)
    private static let audioPort: UInt16 = 8532
    /// No samples for this long → `.waiting`. Chunks arrive ~21×/s.
    private static let audioStaleAfter: TimeInterval = 2
    private static let logSubsystem = "com.ftx1remote.ios"
    private static let logger = Logger(subsystem: logSubsystem, category: "pi-direct")

    private var rigctld: RigctldClient?
    private var queue: CommandQueue?
    private var sessionTask: Task<Void, Never>?

    private let audioEngine = AudioPlaybackEngine()
    private var audioClient: RemoteAudioStreamClient?
    private var audioWatchTask: Task<Void, Never>?
    /// Deliberately not `@Published` — updated per audio chunk; the watch
    /// task samples it once a second into `audioState`.
    private var lastAudioAt: Date?

    func connect(toHost host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            connectionState = .failed("Enter the Pi's hostname")
            return
        }
        disconnect()
        let rigctld = RigctldClient(host: host, port: Self.rigctldPort)
        self.rigctld = rigctld
        queue = CommandQueue(rigctld: rigctld)
        sessionTask = Task { [weak self] in
            await self?.runSession(rigctld: rigctld, host: host)
        }
        startAudio(host: host)
    }

    func disconnect() {
        sessionTask?.cancel()
        sessionTask = nil
        if let rigctld {
            Task { await rigctld.disconnect() }
        }
        rigctld = nil
        queue = nil
        connectionState = .disconnected
        stopAudio()
    }

    func setVolume(_ volume: Double) {
        audioEngine.volume = Float(volume)
    }

    func setSquelchThreshold(_ threshold: Double) {
        audioEngine.squelchThreshold = Float(threshold)
    }

    func toggleAudioMuted() {
        isAudioMuted.toggle()
        AudioPlaybackSettings.isMuted = isAudioMuted
    }

    private func startAudio(host: String) {
        audioEngine.start()
        lastAudioAt = nil
        audioState = .waiting
        let downsampler = PiAudioDownsampler()
        let client = RemoteAudioStreamClient(
            host: host,
            port: Self.audioPort,
            logSubsystem: Self.logSubsystem
        ) { [weak self] left, _, sampleRate in
            // Runs on the client's actor; resample there, hop to the main
            // actor only to hand the 8 kHz chunk to the engine.
            let pcm = downsampler.convert(left, sourceRate: sampleRate)
            guard !pcm.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.audioClient != nil else { return }
                self.lastAudioAt = Date()
                if self.audioState != .playing { self.audioState = .playing }
                if !self.isAudioMuted { self.audioEngine.push(pcm: pcm) }
            }
        }
        audioClient = client
        Task { await client.start() }
        audioWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let fresh = self.lastAudioAt.map { Date().timeIntervalSince($0) < Self.audioStaleAfter } ?? false
                let state: AudioState = fresh ? .playing : .waiting
                if self.audioState != state { self.audioState = state }
            }
        }
    }

    private func stopAudio() {
        audioWatchTask?.cancel()
        audioWatchTask = nil
        if let audioClient {
            Task { await audioClient.stop() }
        }
        audioClient = nil
        audioEngine.stop()
        lastAudioAt = nil
        audioState = .off
    }

    func send(_ command: RigCommand) {
        guard connectionState == .connected, let queue else { return }
        switch command {
        case .setFrequency, .setMode:
            break
        default:
            // RX-only proof of concept — see the type's doc comment.
            Self.logger.notice("ignoring unsupported command \(String(describing: command), privacy: .public)")
            return
        }
        applyOptimistically(command)
        Task { await queue.enqueue(command) }
    }

    /// Shows the change at once rather than up to a poll interval later;
    /// the next poll corrects it if the rig didn't take it.
    private func applyOptimistically(_ command: RigCommand) {
        switch command {
        case .setFrequency(let hz):
            rigState.frequencyHz = hz
        case .setMode(let mode):
            rigState.mode = mode
        default:
            break
        }
    }

    /// Connect, poll until the link dies, wait, retry — until cancelled by
    /// `disconnect()`.
    private func runSession(rigctld: RigctldClient, host: String) async {
        while !Task.isCancelled {
            connectionState = .connecting
            do {
                try await rigctld.connect()
                Self.logger.notice("connected to \(host, privacy: .public):\(Self.rigctldPort)")
                connectionState = .connected
                try await pollUntilFailure(rigctld)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                Self.logger.error("session ended: \(message, privacy: .public)")
                connectionState = .failed(message)
                await rigctld.disconnect()
            }
            try? await Task.sleep(for: Self.reconnectDelay)
        }
    }

    private func pollUntilFailure(_ rigctld: RigctldClient) async throws {
        while !Task.isCancelled {
            try await refresh(rigctld)
            try await Task.sleep(for: Self.pollInterval)
        }
        throw CancellationError()
    }

    /// One poll tick. Every field is best-effort and keeps its last value
    /// on a bad/slow reply, as in `HubService` — only a dead connection
    /// ends the session. "FA" is always MAIN regardless of the active side;
    /// "MD0"/"MD1" are MAIN/SUB (raw, since hamlib's mode read goes stale
    /// after a swap and doesn't know C4FM).
    private func refresh(_ rigctld: RigctldClient) async throws {
        var state = rigState

        do {
            state.frequencyHz = try await rigctld.getFrequency()
        } catch let error as RigctldError where error == .connectionLost || error == .notConnected {
            throw error
        } catch {
            // Bad or slow CAT reply — keep the last value.
        }
        if let mode = (try? await rigctld.getModeCode(p1: 0)).flatMap({ $0 }).flatMap(RigMode.init(catModeCode:)) {
            state.mode = mode
        }
        if let ptt = try? await rigctld.getPTT() {
            state.ptt = ptt
        }
        if let subHz = try? await rigctld.getFrequency(ofVFO: "Sub") {
            state.secondaryFrequencyHz = subHz
        }
        if let subMode = (try? await rigctld.getModeCode(p1: 1)).flatMap({ $0 }).flatMap(RigMode.init(catModeCode:)) {
            state.secondaryMode = subMode
        }

        guard !Task.isCancelled else { return }
        state.lastUpdated = Date()
        rigState = state
    }
}

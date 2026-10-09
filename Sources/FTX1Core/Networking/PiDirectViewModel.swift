import Combine
import Foundation
import os

/// Proof of concept (2026-10-05): a mobile client talking to the Pi's
/// rigctld directly over Tailscale, without the Mac hub. A deliberate,
/// contained exception to "mobile apps never talk to rigctld" (see repo
/// root CLAUDE.md) — used by the iPhone and (since 2026-10-06) the iPad,
/// each with its own view; the Mac-hub path (`RigClientViewModel`) is
/// untouched.
///
/// Receive-only: there's no PTT here, because the Enable Transmit and
/// amateur-band gates live in `HubService.send(_:)`, which this path
/// bypasses entirely. Port a gate first (like Windows' `TransmitGate`)
/// before adding any transmit-capable control.
///
/// rigctld accepts several clients at once, so this coexists with the Mac
/// (or WSJT-X) being connected to the same Pi.
///
/// Audio: a separate `RemoteAudioStreamClient` connection to
/// `Pi/ftx1-audiostream.py` (:8532), its own retry loop independent of the
/// rigctld link. The left channel is Main and the right Sub, unless the
/// rig's Main/Sub have been swapped (the Mac's `audioChannelsSwapped`
/// tracking isn't ported). The Pi serves one audio client at a time, so
/// while the Mac (or another phone/iPad) holds the stream this stays at
/// `.waiting`.
///
/// Explicitly `@MainActor`: this package doesn't use the app targets'
/// MainActor default isolation.
@MainActor
public final class PiDirectViewModel: ObservableObject {
    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published public private(set) var rigState = RigState()
    @Published public private(set) var connectionState: ConnectionState = .disconnected

    public enum AudioState: Equatable {
        case off
        /// Connected (or retrying) but no samples lately — the Pi
        /// unreachable on :8532, or another client (the Mac) holding the
        /// stream.
        case waiting
        case playing
    }

    @Published public private(set) var audioState: AudioState = .off
    /// Same persisted keys as the Mac-hub path's mutes
    /// (`RigClientViewModel.isMainAudioMuted`/`isSubAudioMuted`) — one
    /// mute per channel on this device, whichever route the audio comes
    /// from.
    @Published public private(set) var isMainAudioMuted = AudioPlaybackSettings.isMuted
    @Published public private(set) var isSubAudioMuted = AudioPlaybackSettings.subIsMuted

    /// The rig's programmed memory channels, read through this route's own
    /// rigctld link (attached while connected) and cached on this device —
    /// the iPad's VFO-box channel list. Read only on Refresh, or the first
    /// time the list is shown with no cache, as on the Mac.
    public let memoryList = MemoryListStore()
    /// `memoryList.snapshot`, republished at most twice a second (a scan
    /// publishes per channel) so a view observing this model sees it.
    @Published public private(set) var memoryListSnapshot: MemoryListSnapshot

    /// Fixed, like the Mac's `.remote` mode — only the host is configurable.
    private static let rigctldPort: UInt16 = 4532
    private static let pollInterval: Duration = .seconds(1)
    private static let reconnectDelay: Duration = .seconds(3)
    private static let audioPort: UInt16 = 8532
    /// No samples for this long → `.waiting`. Chunks arrive ~21×/s.
    private static let audioStaleAfter: TimeInterval = 2

    private let logSubsystem: String
    private let logger: Logger
    /// The iPad plays Sub (right channel) too; the iPhone leaves it out.
    private let playsSubAudio: Bool
    /// Adds MAIN's "STRENGTH" and SUB's "RM2" reads per poll tick, for
    /// screens that show both S-meters (the iPad).
    private let readsSMeter: Bool
    /// Adds everything else the Mac's VFO boxes show (the iPad): TX/RX
    /// tags ("ST"/"FT"), single-receive display ("FR"), both sides'
    /// memory mode/channel/tag ("VM"/"MC"/"MT") and the memory scan
    /// ("RI0"/"SC") — see `refreshVFODetails` — plus the C4FM callsign and
    /// reflector from a WPSD hotspot (`connect(toHost:wpsdHost:)`).
    private let readsVFODetails: Bool
    /// Poll ticks since connect, for the reads that only run every
    /// `slowReadEvery` ticks.
    private var tick = 0
    /// The Mac reads these in its slow tier; they change rarely.
    private static let slowReadEvery = 5
    /// Do the slow-tier reads on the next tick regardless — set after a SUB
    /// memory channel change, so SUB's box catches up within a tick.
    private var forceSlowReads = false
    private var memoryListCancellable: AnyCancellable?

    /// Same scraper as the Mac's (`HubService`), polling the hotspot
    /// straight from this device — there's no hub in the path. Only runs
    /// while a WPSD host is set and either side is in C4FM.
    private let wpsdMonitor = WPSDCallsignMonitor()
    private var wpsdHost = ""
    /// Kept outside `rigState` and copied in at publish: a poll tick works
    /// on a copy of `rigState` across its awaits, which would overwrite a
    /// callback's write made in between.
    private var c4fmCallsign: String?
    private var c4fmReflector: String?

    private var rigctld: RigctldClient?
    private var queue: CommandQueue?
    private var sessionTask: Task<Void, Never>?

    /// Public so a view can set volume/squelch on them directly, as the
    /// iPad's audio columns do with `RigClientViewModel`'s engines.
    public let mainAudioEngine = AudioPlaybackEngine()
    public let subAudioEngine = AudioPlaybackEngine()
    private var audioClient: RemoteAudioStreamClient?
    private var audioWatchTask: Task<Void, Never>?
    /// Deliberately not `@Published` — updated per audio chunk; the watch
    /// task samples it once a second into `audioState`.
    private var lastAudioAt: Date?

    public init(
        logSubsystem: String,
        playsSubAudio: Bool = false,
        readsSMeter: Bool = false,
        readsVFODetails: Bool = false
    ) {
        self.logSubsystem = logSubsystem
        logger = Logger(subsystem: logSubsystem, category: "pi-direct")
        self.playsSubAudio = playsSubAudio
        self.readsSMeter = readsSMeter
        self.readsVFODetails = readsVFODetails
        memoryListSnapshot = memoryList.snapshot
        memoryListCancellable = memoryList.$entries
            .combineLatest(memoryList.$scanningChannel, memoryList.$lastScanned)
            .map { MemoryListSnapshot(entries: $0, scanned: $2, scanningChannel: $1) }
            .removeDuplicates()
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.memoryListSnapshot = $0 }
        wpsdMonitor.onCallsignUpdate = { [weak self] callsign in
            self?.c4fmCallsign = callsign
            self?.rigState.c4fmCallsign = callsign
        }
        wpsdMonitor.onReflectorUpdate = { [weak self] reflector in
            self?.c4fmReflector = reflector
            self?.rigState.c4fmReflector = reflector
        }
    }

    /// `wpsdHost`: the WPSD hotspot to read the C4FM callsign/reflector
    /// from (only with `readsVFODetails`); empty leaves that lookup off.
    public func connect(toHost host: String, wpsdHost: String = "") {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            connectionState = .failed("Enter the Pi's hostname")
            return
        }
        disconnect()
        self.wpsdHost = wpsdHost.trimmingCharacters(in: .whitespaces)
        tick = 0
        let rigctld = RigctldClient(host: host, port: Self.rigctldPort)
        self.rigctld = rigctld
        let queue = CommandQueue(rigctld: rigctld)
        self.queue = queue
        Task {
            await queue.setOnCommandApplied { [weak self] command, _ in
                // No optimistic SUB channel (the rig ignores a blank one):
                // read it back on the next tick instead of up to 5 later.
                // MAIN's is read every tick anyway.
                switch command {
                case .setSubMemoryChannel, .stepSubMemoryChannel:
                    Task { @MainActor in self?.forceSlowReads = true }
                default:
                    break
                }
            }
        }
        memoryList.rigctld = rigctld
        sessionTask = Task { [weak self] in
            await self?.runSession(rigctld: rigctld, host: host)
        }
        startAudio(host: host)
    }

    public func disconnect() {
        sessionTask?.cancel()
        sessionTask = nil
        if let rigctld {
            Task { await rigctld.disconnect() }
        }
        rigctld = nil
        queue = nil
        memoryList.rigctld = nil
        connectionState = .disconnected
        stopAudio()
        stopWPSD()
        // A reconnect starts from a blank state, as the Mac's does: none of
        // these should linger from the last session until re-read.
        rigState = RigState()
    }

    public func toggleMainAudioMuted() {
        isMainAudioMuted.toggle()
        AudioPlaybackSettings.isMuted = isMainAudioMuted
    }

    public func toggleSubAudioMuted() {
        isSubAudioMuted.toggle()
        AudioPlaybackSettings.subIsMuted = isSubAudioMuted
    }

    private func startAudio(host: String) {
        mainAudioEngine.start()
        if playsSubAudio { subAudioEngine.start() }
        lastAudioAt = nil
        audioState = .waiting
        // One per channel: each converter keeps filter state across chunks.
        let mainDownsampler = PiAudioDownsampler()
        let subDownsampler = playsSubAudio ? PiAudioDownsampler() : nil
        let client = RemoteAudioStreamClient(
            host: host,
            port: Self.audioPort,
            logSubsystem: logSubsystem
        ) { [weak self] left, right, sampleRate in
            // Runs on the client's actor; resample there, hop to the main
            // actor only to hand the 8 kHz chunks to the engines.
            let mainPCM = mainDownsampler.convert(left, sourceRate: sampleRate)
            let subPCM = subDownsampler?.convert(right, sourceRate: sampleRate) ?? Data()
            guard !mainPCM.isEmpty || !subPCM.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.audioClient != nil else { return }
                self.lastAudioAt = Date()
                if self.audioState != .playing { self.audioState = .playing }
                if !mainPCM.isEmpty, !self.isMainAudioMuted { self.mainAudioEngine.push(pcm: mainPCM) }
                if !subPCM.isEmpty, !self.isSubAudioMuted { self.subAudioEngine.push(pcm: subPCM) }
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
        mainAudioEngine.stop()
        subAudioEngine.stop()
        lastAudioAt = nil
        audioState = .off
    }

    public func send(_ command: RigCommand) {
        guard connectionState == .connected, let queue else { return }
        switch command {
        case .setFrequency, .setMode, .setSecondaryFrequency, .setSecondaryMode,
             .setMemoryChannel, .stepMemoryChannel, .setSubMemoryChannel, .stepSubMemoryChannel:
            // None of these transmit. Not while the rig scans: the hub
            // stops the scan first and puts the TX side back (see
            // `HubService.memoryScanStop`), which this route doesn't port.
            if rigState.memoryScan == .scanning || rigState.memoryScan == .paused {
                logger.notice("ignoring \(String(describing: command), privacy: .public) while the rig scans")
                return
            }
        case .refreshMemoryList:
            memoryList.refresh()
            return
        default:
            // RX-only proof of concept — see the type's doc comment.
            logger.notice("ignoring unsupported command \(String(describing: command), privacy: .public)")
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
        case .setSecondaryFrequency(let hz):
            rigState.secondaryFrequencyHz = hz
        case .setSecondaryMode(let mode):
            rigState.secondaryMode = mode
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
                logger.notice("connected to \(host, privacy: .public):\(Self.rigctldPort)")
                connectionState = .connected
                try await pollUntilFailure(rigctld)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                logger.error("session ended: \(message, privacy: .public)")
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
        if readsSMeter {
            // Not carried forward on failure, like the Mac's fast tier: a
            // meter should fall to rest rather than freeze. SUB's comes
            // from raw "RM2", same as `HubService` (STRENGTH reads only the
            // active side).
            state.smeterDb = try? await rigctld.getLevel("STRENGTH")
            state.subSmeterDb = (try? await rigctld.getMeterReading(2)).flatMap { $0 }.map(SMeterScale.strengthDb(forRaw:))
        }
        if readsVFODetails {
            await refreshVFODetails(rigctld, into: &state)
        }
        tick += 1

        guard !Task.isCancelled else { return }
        state.lastUpdated = Date()
        state.c4fmCallsign = c4fmCallsign
        state.c4fmReflector = c4fmReflector
        rigState = state
        if readsVFODetails { updateWPSD() }
    }

    /// The rest of the Mac's VFO-box fields, read the way `HubService`
    /// reads them (its fast tier for MAIN's memory mode and the scan, its
    /// slow tier for the others). Display only — nothing here is writable
    /// from this route. Best-effort, like every other field.
    private func refreshVFODetails(_ rigctld: RigctldClient, into state: inout RigState) async {
        if tick % Self.slowReadEvery == 0 || forceSlowReads {
            forceSlowReads = false
            // "FR" (FUNCTION RX): 00 dual receive, 01 single.
            if let receiveMode = try? await rigctld.getRawInt("FR") {
                state.singleReceive = receiveMode == 1
            }
            if let split = try? await rigctld.getRawBool("ST") {
                state.splitEnabled = split
            }
            // "FT": the TX side (0 MAIN, 1 SUB), a bare digit like "ST".
            if let side = (try? await rigctld.getRawDigit("FT")).flatMap({ $0 }).flatMap(FilterSide.init(rawValue:)) {
                state.txSide = side
            }
            let subModeRaw = try? await rigctld.getRawInt("VM1")
            let subChannel = subModeRaw == 11 ? (try? await rigctld.getRawInt("MC1")) : nil
            state.subVfoMemoryMode = subModeRaw.flatMap { $0 }.map(VFOMemoryMode.init(rawP2:)) ?? state.subVfoMemoryMode
            // No fallback: back to nil out of Memory mode, as on the Mac.
            state.subMemoryChannel = subChannel.flatMap { $0 }
            state.subMemoryChannelTag = nil
            if let channel = state.subMemoryChannel {
                state.subMemoryChannelTag = (try? await rigctld.getMemoryChannelTag(channel: channel)).flatMap { $0 }
            }
        }

        // "VM0" every tick: it decides whether MAIN's frequency is a VFO's
        // or a memory channel's.
        let mainModeRaw = (try? await rigctld.getRawInt("VM0")).flatMap { $0 }
        state.vfoMemoryMode = mainModeRaw.map(VFOMemoryMode.init(rawP2:)) ?? state.vfoMemoryMode
        let mainChannel = mainModeRaw == 11 ? (try? await rigctld.getRawInt("MC0")).flatMap({ $0 }) : nil
        state.memoryChannel = mainChannel
        state.memoryChannelTag = nil
        if let mainChannel {
            state.memoryChannelTag = (try? await rigctld.getMemoryChannelTag(channel: mainChannel)).flatMap { $0 }
        }

        // The scan state is for the whole radio ("RI0" P7); read only in
        // Memory mode, or while a scan was last seen running, as on the Mac.
        let scanWasActive = state.memoryScan == .scanning || state.memoryScan == .paused
        if state.vfoMemoryMode == .memory || state.subVfoMemoryMode == .memory || scanWasActive {
            if let info = (try? await rigctld.getRadioInformation()).flatMap({ $0 }) {
                state.memoryScan = info.scan
                // Every scan is a front-panel one here: "SC;" reads back
                // the side last told to scan, e.g. "SC11;".
                if info.scan != .stopped,
                   let side = (try? await rigctld.getRawDigit("SC")).flatMap({ $0 }).flatMap(FilterSide.init(rawValue:)) {
                    state.memoryScanSide = side
                }
            }
        } else {
            state.memoryScan = nil
        }
    }

    /// Mirrors `HubService.updateWPSDMonitorState`; `start`/`stop` are
    /// no-ops when already in that state.
    private func updateWPSD() {
        guard !wpsdHost.isEmpty, rigState.mode == .c4fm || rigState.secondaryMode == .c4fm else {
            stopWPSD()
            return
        }
        wpsdMonitor.start(host: wpsdHost)
    }

    private func stopWPSD() {
        wpsdMonitor.stop()
        c4fmCallsign = nil
        c4fmReflector = nil
        rigState.c4fmCallsign = nil
        rigState.c4fmReflector = nil
    }
}

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
/// Transmit (2026-10-09, iPad): hold-to-talk PTT keys the rig through
/// rigctld ("T currVFO 1") and streams the microphone to
/// `Pi/ftx1-txaudio.py` (:8533, `RemoteTXAudioClient`), which plays it into
/// the rig's USB audio input. The hub's gates don't apply on this path, so
/// keying goes through `TransmitGate` (this device's own `transmitEnabled`,
/// off by default, and the amateur bands) and is refused while the rig
/// scans; unkeying always goes through. The MENU grid's MOX and ANT TUNE
/// (2026-10-09, `readsMenuSettings`) go through the same gate; anything
/// else that transmits needs it too. If this device vanishes
/// mid-transmission, the Pi's TX audio service unkeys the rig (its
/// watchdog) — but not MOX, which isn't tied to that connection.
///
/// MENU grid (2026-10-09, iPad): with `readsMenuSettings` this conforms to
/// `RigController`, so the shared `MenuPageView` runs on it. It accepts the
/// grid's setting commands (`isMenuSetting`) and reads their fields a few
/// per poll tick (`menuSettingReads`, the hub's slow-tier reads).
/// RECORD/PLAY stay unsupported, as on the hub route.
///
/// Deep Settings (2026-10-11, iPad, with `readsMenuSettings`): the shared
/// `DeepSettingsView` reads the open tab's items straight over this
/// rigctld link (`readMenuItem`) and writes with `.setMenuItem`, as the
/// Mac does. Like the hub, those writes aren't transmit-gated: the
/// catalog's momentary/irreversible items (`.action`) are never sent.
///
/// Filters (2026-10-11, iPad): with `readsFilters` it takes the filter
/// row's commands (WIDTH/SHIFT/CONTOUR-APF/N/W/NOTCH and the MAIN/SUB
/// selector) and reads the selected side's filter state a few fields per
/// tick (`FilterStateReads`, shared with the hub), plus a full re-read
/// after a side switch or swap and a width re-read after N/W — the hub's
/// rules. `filterSpectrum` is the Filter Function Display's spectrum,
/// computed from this route's own 8 kHz audio.
///
/// APRS (2026-10-14, iPad, `decodesAPRS`): an `APRSDecoder` per side runs
/// on the Pi's 44.1 kHz audio, before the downsampling — the same decoder
/// and gate (`APRSSettings`, this device's own copy) as the Mac's, Sub
/// gated on SUB's frequency — into `aprsStore`, persisted on this device,
/// for the S.LIST/M.LIST pane. Decoding runs whenever audio arrives and
/// the gate is open, pane shown or not, like the Mac's.
///
/// rigctld accepts several clients at once, so this coexists with the Mac
/// (or WSJT-X) being connected to the same Pi.
///
/// Audio: a separate `RemoteAudioStreamClient` connection to
/// `Pi/ftx1-audiostream.py` (:8532), its own retry loop independent of the
/// rigctld link. The left channel is Main and the right Sub until the rig's
/// Main/Sub are swapped: the rig keeps L/R with the physical receiver, so
/// `audioChannelsSwapped` tracks the parity like the Mac's (an app swap,
/// a detected front-panel swap, or the manual toggle). The Pi serves one audio client at a time, so
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

    @Published public private(set) var rigState = RigState() {
        didSet {
            filterSpectrum.selectedSide = rigState.activeFilterSide
            if aprsStore != nil { updateAPRSGate() }
        }
    }
    @Published public private(set) var connectionState: ConnectionState = .disconnected

    /// The Filter Function Display's spectrum from this route's audio, fed
    /// before the mute/transmit checks — see `FilterSpectrumStore`.
    public let filterSpectrum = FilterSpectrumStore()

    /// Every downsampled 8 kHz receive chunk (`AudioStreamFormat`), MAIN and SUB, on
    /// the main actor, before the mute/transmit checks — for the iPad's CW
    /// decoder, which lives in `FTX1CW` and so can't be named here.
    public var onReceiveAudio: (@MainActor (Data, FilterSide) -> Void)?

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
    /// Whether the Pi's L/R channels are exchanged before playback (R plays
    /// as Main) — `HubService.audioChannelsSwapped`'s counterpart, same
    /// persisted key (each device's own). Flipped by an app swap (not in
    /// single-receive display, where `SV` doesn't move the audio), a
    /// detected front-panel swap, or `toggleAudioChannelsSwapped()`.
    @Published public private(set) var audioChannelsSwapped = AudioPlaybackSettings.channelsSwapped
    /// `audioChannelsSwapped` for the audio client's actor.
    private let channelSwap = ChannelSwapFlag(AudioPlaybackSettings.channelsSwapped)

    /// Decoded APRS stations/messages (`decodesAPRS` only, else nil).
    public let aprsStore: APRSStore?
    private let aprsDecoderMain: APRSDecoder?
    /// Only when this also plays Sub (`playsSubAudio`).
    private let aprsDecoderSub: APRSDecoder?
    /// Whether each side is on the APRS frequency, for the audio client's
    /// actor — refreshed on every `rigState` change.
    private let aprsGate = APRSGateFlags()
    /// The last station each side decoded, for the VFO boxes' APRS
    /// indicator — shown for 5 s, as on the hub. Kept outside `rigState`
    /// and copied in at publish, like `c4fmCallsign`.
    private var aprsLastHeard: [APRSSource: (callsign: String, at: Date)] = [:]
    /// MAIN's last VFO-mode frequency/mode, replayed when leaving Memory
    /// mode — "VM000" alone leaves MAIN parked on the channel's values. See
    /// `HubService.lastVFOState`; cleared by a swap the same way.
    private var lastVFOState: (hz: Int, mode: RigMode)?
    /// Baseline for `trackExternalSwap` — see `HubService`'s.
    private var lastDistinctFrequencies: (main: Int, sub: Int)?
    /// Bumped when a swap, V/M or scan start/stop lands, so a poll tick
    /// that straddled it is dropped rather than published (and mistaken
    /// for a swap back, or a scan that hasn't started/stopped).
    private var commandGeneration = 0
    /// The TX side to put back when the app stops the memory scan it
    /// started — `HubService.txSideBeforeMemoryScan`: starting a scan moves
    /// the rig's TX/RX side to the scanning side. nil when there's nothing
    /// to undo, or after a scan stopped from the front panel.
    private var txSideBeforeMemoryScan: FilterSide?
    /// When the rig took the app's last scan start: a "stopped" read just
    /// after may predate the rig acting on "SC" (as in `HubService`).
    private var memoryScanStartedAt: ContinuousClock.Instant?

    /// The rig's programmed memory channels, read through this route's own
    /// rigctld link (attached while connected) and cached on this device —
    /// the iPad's VFO-box channel list. Read only on Refresh, or the first
    /// time the list is shown with no cache, as on the Mac.
    public let memoryList = MemoryListStore()
    /// `memoryList.snapshot`, republished at most twice a second (a scan
    /// publishes per channel) so a view observing this model sees it.
    @Published public private(set) var memoryListSnapshot: MemoryListSnapshot

    private static let pollInterval: Duration = .seconds(1)
    private static let reconnectDelay: Duration = .seconds(3)
    /// No samples for this long → `.waiting`. Chunks arrive ~21×/s.
    private static let audioStaleAfter: TimeInterval = 2

    /// This device's Enable Transmit for this route — the hub's toggle
    /// lives on the Mac, which isn't in the path. Persisted, off by
    /// default; turning it off while keyed unkeys at once.
    @Published public var transmitEnabled = SettingsStore.defaults.bool(forKey: PiDirectViewModel.transmitEnabledKey) {
        didSet {
            SettingsStore.defaults.set(transmitEnabled, forKey: Self.transmitEnabledKey)
            // `MenuPageView` gates MOX/ANT TUNE on the state's copy.
            rigState.transmitEnabled = transmitEnabled
            if !transmitEnabled, isTransmitting { abortTransmit(reason: "Enable Transmit turned off") }
            if !transmitEnabled, rigState.moxEnabled == true { send(.setMox(false)) }
            // The CW sender's keyer memory (stopping it is always allowed).
            if !transmitEnabled, cwKeyerUsed { send(.playCWTextMemory(slot: 0)) }
        }
    }
    public static let transmitEnabledKey = "piDirect.transmitEnabled"
    /// Holding PTT (press to release, plus the unkey delay). Mutes receive
    /// playback meanwhile, so the rig's monitor audio can't feed back into
    /// the microphone.
    @Published public private(set) var isTransmitting = false
    /// Why the last press didn't transmit (gate, microphone access, ...);
    /// cleared on the next press.
    @Published public private(set) var transmitProblem: String?

    /// nil when a press would key — for the PTT button's look.
    public var transmitBlockReason: String? {
        if rigState.memoryScan == .scanning || rigState.memoryScan == .paused {
            return "Transmit disabled while the rig scans"
        }
        return TransmitGate.blockReason(transmitEnabled: transmitEnabled, state: rigState)
    }

    private var endpoint = PiEndpoint(host: "")
    #if os(iOS)
    private lazy var microphone = MicrophoneTransmitter(logSubsystem: logSubsystem)
    #endif
    private var unkeyTask: Task<Void, Never>?
    /// A CW TEXT keyer memory was played this session (the iPad's CW send
    /// section), so a lock or a disconnect also sends "KY00": the rig would
    /// otherwise finish its up-to-50 characters on its own.
    private var cwKeyerUsed = false

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
    /// Adds the MENU grid's fields (the iPad), `menuReadsPerTick` of
    /// `menuSettingReads` per tick, round-robin.
    private let readsMenuSettings: Bool
    /// Where the next tick resumes `menuSettingReads`.
    private var menuReadCursor = 0
    /// Adds the filter row (the iPad): accepts its commands and reads the
    /// selected side's filter state, `filterReadsPerTick` of
    /// `FilterStateReads.all` per tick, round-robin.
    private let readsFilters: Bool
    /// Where the next tick resumes `FilterStateReads.all`.
    private var filterReadCursor = 0
    /// The ten reads in ~4 s — the hub reads them every ~10 s in its slow
    /// tier; a side switch or swap re-reads them all at once anyway.
    private static let filterReadsPerTick = 3
    /// ~9 s for the whole list at one tick a second — about the Mac's slow
    /// tier — for ~0.3 s more per tick over the Pi.
    private static let menuReadsPerTick = 4
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
        readsVFODetails: Bool = false,
        readsMenuSettings: Bool = false,
        readsFilters: Bool = false,
        decodesAPRS: Bool = false
    ) {
        self.logSubsystem = logSubsystem
        logger = Logger(subsystem: logSubsystem, category: "pi-direct")
        self.playsSubAudio = playsSubAudio
        self.readsSMeter = readsSMeter
        self.readsVFODetails = readsVFODetails
        self.readsMenuSettings = readsMenuSettings
        self.readsFilters = readsFilters
        if decodesAPRS {
            aprsStore = APRSStore()
            aprsDecoderMain = APRSDecoder(logSubsystem: logSubsystem)
            aprsDecoderSub = playsSubAudio ? APRSDecoder(logSubsystem: logSubsystem) : nil
        } else {
            aprsStore = nil
            aprsDecoderMain = nil
            aprsDecoderSub = nil
        }
        memoryListSnapshot = memoryList.snapshot
        rigState.transmitEnabled = transmitEnabled
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
        wireAPRSDecoder(aprsDecoderMain, source: .main)
        wireAPRSDecoder(aprsDecoderSub, source: .sub)
    }

    private func wireAPRSDecoder(_ decoder: APRSDecoder?, source: APRSSource) {
        guard let decoder else { return }
        // The decoder calls these on the main queue.
        decoder.onStation = { [weak self] callsign, latitude, longitude, symbolTable, symbolCode, comment in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.aprsLastHeard[source] = (callsign, Date())
                // At once, not on the next tick.
                var state = self.rigState
                self.applyAPRSIndicators(to: &state)
                self.rigState = state
                self.aprsStore?.recordStation(callsign: callsign, latitude: latitude, longitude: longitude, symbolTable: symbolTable, symbolCode: symbolCode, comment: comment, heardAt: Date(), source: source)
            }
        }
        decoder.onMessage = { [weak self] from, to, text, messageID in
            MainActor.assumeIsolated {
                self?.aprsStore?.recordMessage(from: from, to: to, text: text, messageID: messageID, receivedAt: Date(), source: source)
            }
        }
    }

    /// The VFO boxes' APRS indicator, as `HubService.refreshFastTier` sets
    /// it: on the APRS frequency (decoding enabled), plus the callsign
    /// decoded there in the last 5 s.
    private func applyAPRSIndicators(to state: inout RigState) {
        guard aprsStore != nil else { return }
        func recent(_ source: APRSSource) -> String? {
            aprsLastHeard[source].flatMap { Date().timeIntervalSince($0.at) < 5 ? $0.callsign : nil }
        }
        state.aprsActive = APRSSettings.isActive(atFrequencyHz: state.frequencyHz)
        state.aprsLastCallsign = state.aprsActive ? recent(.main) : nil
        state.aprsSubActive = state.secondaryFrequencyHz.map { APRSSettings.isActive(atFrequencyHz: $0) } ?? false
        state.aprsSubLastCallsign = state.aprsSubActive ? recent(.sub) : nil
    }

    /// Re-reads `APRSSettings` each time, so a change in the pane's
    /// settings applies on the next poll tick.
    private func updateAPRSGate() {
        let main = connectionState == .connected && APRSSettings.isActive(atFrequencyHz: rigState.frequencyHz)
        let sub = connectionState == .connected && (rigState.secondaryFrequencyHz.map { APRSSettings.isActive(atFrequencyHz: $0) } ?? false)
        aprsGate.set(main: main, sub: sub)
    }

    /// `wpsdHost`: the WPSD hotspot to read the C4FM callsign/reflector
    /// from (only with `readsVFODetails`); empty leaves that lookup off.
    public func connect(toHost host: String, wpsdHost: String = "") {
        connect(to: PiEndpoint(host: host), wpsdHost: wpsdHost)
    }

    /// `endpoint`: the Pi's three services — the real Pi's fixed ports, or
    /// the iPad's Demo Mode simulator on loopback.
    public func connect(to endpoint: PiEndpoint, wpsdHost: String = "") {
        let host = endpoint.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            connectionState = .failed("Enter the Pi's hostname")
            return
        }
        disconnect()
        var endpoint = endpoint
        endpoint.host = host
        self.endpoint = endpoint
        self.wpsdHost = wpsdHost.trimmingCharacters(in: .whitespaces)
        tick = 0
        menuReadCursor = 0
        filterReadCursor = 0
        let rigctld = RigctldClient(host: host, port: endpoint.rigctldPort)
        self.rigctld = rigctld
        let queue = CommandQueue(rigctld: rigctld)
        self.queue = queue
        Task { [weak self] in
            await queue.setOnCommandApplied { command, _ in
                // No optimistic SUB channel (the rig ignores a blank one):
                // read it back on the next tick instead of up to 5 later.
                // MAIN's is read every tick anyway.
                switch command {
                case .setSubMemoryChannel, .stepSubMemoryChannel:
                    Task { @MainActor in self?.forceSlowReads = true }
                case .swapActiveVFO, .setVFOMemoryMode, .setMemoryScan, .setTXSide:
                    Task { @MainActor in self?.commandApplied(command) }
                case _ where Self.isMenuSetting(command) || command.isFilterSideCommand:
                    // A tick that read the field before the rig took the
                    // set would put the old value back until its next read.
                    Task { @MainActor in self?.commandGeneration += 1 }
                default:
                    break
                }
            }
        }
        memoryList.rigctld = rigctld
        sessionTask = Task { [weak self] in
            await self?.runSession(rigctld: rigctld, endpoint: endpoint)
        }
        startAudio(endpoint: endpoint)
    }

    public func disconnect() {
        let wasTransmitting = isTransmitting
        let wasMox = rigState.moxEnabled == true
        let wasKeyerUsed = cwKeyerUsed
        cwKeyerUsed = false
        stopTransmitLocally()
        sessionTask?.cancel()
        sessionTask = nil
        if let rigctld {
            Task {
                // Unkey ahead of the teardown, on the same link. MOX too:
                // nothing on the Pi would end it after this link is gone.
                if wasTransmitting { _ = try? await rigctld.send("T currVFO 0") }
                if wasMox { try? await rigctld.setRawBool("MX", false) }
                if wasKeyerUsed { try? await rigctld.setRawInt("KY0", 0, digits: 1) }
                await rigctld.disconnect()
            }
        }
        rigctld = nil
        queue = nil
        memoryList.rigctld = nil
        connectionState = .disconnected
        stopAudio()
        stopWPSD()
        // A reconnect starts from a blank state, as the Mac's does: none of
        // these should linger from the last session until re-read. (The
        // audio swap parity is kept: it describes the rig, not the session.)
        rigState = RigState()
        rigState.transmitEnabled = transmitEnabled
        filterSpectrum.reset()
        lastVFOState = nil
        lastDistinctFrequencies = nil
        aprsLastHeard = [:]
        txSideBeforeMemoryScan = nil
        memoryScanStartedAt = nil
    }

    public func toggleMainAudioMuted() {
        isMainAudioMuted.toggle()
        AudioPlaybackSettings.isMuted = isMainAudioMuted
    }

    public func toggleSubAudioMuted() {
        isSubAudioMuted.toggle()
        AudioPlaybackSettings.subIsMuted = isSubAudioMuted
    }

    private func startAudio(endpoint: PiEndpoint) {
        mainAudioEngine.start()
        if playsSubAudio { subAudioEngine.start() }
        lastAudioAt = nil
        audioState = .waiting
        // One per channel: each converter keeps filter state across chunks.
        let mainDownsampler = PiAudioDownsampler()
        let subDownsampler = playsSubAudio ? PiAudioDownsampler() : nil
        let client = RemoteAudioStreamClient(
            host: endpoint.host,
            port: endpoint.audioPort,
            logSubsystem: logSubsystem
        ) { [weak self, channelSwap, aprsGate, aprsDecoderMain, aprsDecoderSub] left, right, sampleRate in
            // L/R follow the physical receivers, so after a swap R is Main.
            let (left, right) = channelSwap.value ? (right, left) : (left, right)
            // Full rate, before downsampling: at 8 kHz the demodulator has
            // too few samples per bit (see Audio-over-Pi in CLAUDE.md).
            let gate = aprsGate.value
            if gate.main { aprsDecoderMain?.process(samples: left, sampleRate: sampleRate) }
            if gate.sub { aprsDecoderSub?.process(samples: right, sampleRate: sampleRate) }
            // Runs on the client's actor; resample there, hop to the main
            // actor only to hand the 8 kHz chunks to the engines.
            let mainPCM = mainDownsampler.convert(left, sourceRate: sampleRate)
            let subPCM = subDownsampler?.convert(right, sourceRate: sampleRate) ?? Data()
            guard !mainPCM.isEmpty || !subPCM.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.audioClient != nil else { return }
                self.lastAudioAt = Date()
                if self.audioState != .playing { self.audioState = .playing }
                // Before the mute/transmit checks: a muted side still shows.
                if !mainPCM.isEmpty {
                    self.filterSpectrum.ingest(pcm: mainPCM, side: .main)
                    self.onReceiveAudio?(mainPCM, .main)
                }
                if !subPCM.isEmpty {
                    self.filterSpectrum.ingest(pcm: subPCM, side: .sub)
                    self.onReceiveAudio?(subPCM, .sub)
                }
                guard !self.isTransmitting else { return }
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
        case .swapActiveVFO, .setVFOMemoryMode:
            // Not while scanning, as above. Applied to `rigState` once the
            // rig has taken them (`commandApplied`), not optimistically.
            if rigState.memoryScan == .scanning || rigState.memoryScan == .paused {
                logger.notice("ignoring \(String(describing: command), privacy: .public) while the rig scans")
                return
            }
            if case .setVFOMemoryMode(memory: false) = command, let last = lastVFOState {
                // Same as the hub: leave Memory first (the rig rejects "FA"
                // in Memory mode), then put the VFO back. FIFO queue.
                Task {
                    await queue.enqueue(command)
                    await queue.enqueue(.setFrequency(hz: last.hz))
                    await queue.enqueue(.setMode(last.mode))
                }
                return
            }
            Task { await queue.enqueue(command) }
            return
        case .setBand(let name):
            // MAIN's band picker. No band memory on this route (that's the
            // hub's `BandMemory`): a band goes to its default frequency and
            // keeps the mode; a general-coverage segment also gets its
            // default mode, as on the hub. Not while scanning, as above.
            if rigState.memoryScan == .scanning || rigState.memoryScan == .paused {
                logger.notice("ignoring \(String(describing: command), privacy: .public) while the rig scans")
                return
            }
            var commands: [RigCommand]
            if let band = BandPlan.band(named: name) {
                commands = [.setFrequency(hz: band.defaultFrequencyHz)]
            } else if let segment = GeneralCoverageSegments.segment(named: name) {
                commands = [.setFrequency(hz: segment.defaultFrequencyHz), .setMode(segment.defaultMode)]
            } else {
                logger.notice("ignoring unknown band \(name, privacy: .public)")
                return
            }
            commands.forEach(applyOptimistically)
            // One task, so the mode can't overtake the frequency.
            Task { for command in commands { await queue.enqueue(command) } }
            return
        case .refreshMemoryList:
            memoryList.refresh()
            return
        case .setAudioChannelsSwapped(let swapped):
            setAudioChannelsSwapped(swapped, reason: "manual toggle")
            return
        case .setMemoryScan(let direction, let side):
            sendMemoryScan(direction, side: side, queue: queue)
            return
        case .setPTT(let on):
            // Only keying is gated; unkeying always goes through.
            if on, let reason = transmitBlockReason {
                logger.notice("refusing PTT: \(reason, privacy: .public)")
                return
            }
            rigState.ptt = on
            Task { await queue.enqueue(command) }
            return
        case .setMox(true), .triggerAntennaTune:
            // The MENU grid's transmit-capable buttons: same gate as PTT
            // (incl. refused while the rig scans). MOX off always goes
            // through, below.
            guard readsMenuSettings else {
                logger.notice("ignoring unsupported command \(String(describing: command), privacy: .public)")
                return
            }
            if let reason = transmitBlockReason {
                logger.notice("refusing \(String(describing: command), privacy: .public): \(reason, privacy: .public)")
                return
            }
        case .playCWTextMemory(let slot):
            // The CW send section's keyer memory play ("KY0<slot>"), iPad
            // only. Playing keys the rig: same gate as PTT. "KY00" (stop)
            // always goes through.
            guard readsMenuSettings else {
                logger.notice("ignoring unsupported command \(String(describing: command), privacy: .public)")
                return
            }
            if slot != 0 {
                if let reason = transmitBlockReason {
                    logger.notice("refusing CW keyer memory \(slot): \(reason, privacy: .public)")
                    return
                }
                cwKeyerUsed = true
            }
            Task { await queue.enqueue(command) }
            return
        case _ where readsMenuSettings && Self.isMenuSetting(command):
            break
        case .setFilterSide(let side) where readsFilters:
            // As on the hub: SUB isn't shown in single-receive display.
            if side == .sub, rigState.singleReceive == true {
                logger.notice("ignoring SUB filter selection in single-receive display")
                return
            }
            // The fields hold the selected side's values: blank them until
            // that side is read, never show the other side's as its own.
            rigState.filterSide = side
            rigState.clearFilterFields()
            commandGeneration += 1
            Task {
                // No CAT traffic — retargets the queue's filter commands.
                await queue.enqueue(command)
                await self.refreshFilterState(side: side)
            }
            return
        case .setNarrow where readsFilters:
            // N/W changes what "SH" reports (AM/FM) and which width
            // applies: re-read right behind the write, as the hub does.
            applyOptimistically(command)
            Task {
                await queue.enqueue(command)
                await self.refreshWidthAfterNarrow()
            }
            return
        case _ where readsFilters && command.isFilterSideCommand:
            break
        default:
            // RX-only proof of concept — see the type's doc comment.
            logger.notice("ignoring unsupported command \(String(describing: command), privacy: .public)")
            return
        }
        applyOptimistically(command)
        Task { await queue.enqueue(command) }
    }

    /// The hub's memory-scan rules (`HubService.send(_:memoryScanStopped:)`),
    /// minus its fast scan polling: start only in that side's Memory mode
    /// ("SC" in VFO mode is the rig's VFO scan) and, for SUB, in dual
    /// receive; one side at a time, since any stop stops both and "RI0"
    /// reports one state for the whole radio; a stop puts back the TX side
    /// the scan moved. A start on the side already scanning is a Skip.
    /// Applied to `rigState` once the rig has taken it (`commandApplied`).
    private func sendMemoryScan(_ direction: MemoryScanDirection, side: FilterSide, queue: CommandQueue) {
        let active = rigState.memoryScan == .scanning || rigState.memoryScan == .paused
        let activeSide = rigState.memoryScanSide ?? .main
        if direction == .off {
            let previous = txSideBeforeMemoryScan
            txSideBeforeMemoryScan = nil
            Task {
                await queue.enqueue(.setMemoryScan(.off, side: active ? activeSide : side))
                if let previous { await queue.enqueue(.setTXSide(previous)) }
            }
            return
        }
        guard rigState.canStartMemoryScan(on: side) else {
            logger.notice("ignoring \(side.displayName, privacy: .public) memory scan outside Memory mode or in single receive")
            return
        }
        // One already remembered (carried over from the other side's scan)
        // is the original and stays.
        if txSideBeforeMemoryScan == nil {
            let current = rigState.txSide ?? .main
            if current != side { txSideBeforeMemoryScan = current }
        }
        Task {
            if active, activeSide != side {
                await queue.enqueue(.setMemoryScan(.off, side: activeSide))
            }
            await queue.enqueue(.setMemoryScan(direction, side: side))
        }
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
        case .setPowerLevel(let level): rigState.powerLevel = level
        case .setBreakIn(let on): rigState.breakIn = on
        case .setKeyer(let on): rigState.keyerEnabled = on
        case .setCWSpeed(let wpm): rigState.cwSpeedWpm = wpm
        case .setCWPitch(let hz): rigState.cwPitchHz = hz
        case .setBreakInDelay(let ms): rigState.bkDelayMs = ms
        case .setCWSpot(let on): rigState.cwSpot = on
        case .setMoniLevel(let level): rigState.moniLevel = level
        case .setMox(let on): rigState.moxEnabled = on
        case .setAtt(let on): rigState.attEnabled = on
        case .setPreamp(let mode): rigState.preampMode = mode
        case .setTuner(let on): rigState.tunerEnabled = on
        case .setDisplayContrast(let value): rigState.displayContrast = value
        case .setDisplayDimmer(let value): rigState.displayDimmer = value
        case .setDisplayLevel(let dB): rigState.displayLevel = dB
        case .setDisplayPeak(let level): rigState.displayPeak = level
        case .setDisplayMarker(let on): rigState.displayMarker = on
        case .setMicGain(let value): rigState.micGain = value
        case .setAMCLevel(let value): rigState.amcLevel = value
        case .setVox(let on): rigState.voxEnabled = on
        case .setVoxGain(let value): rigState.voxGain = value
        case .setVoxDelay(let ms): rigState.voxDelayMs = ms
        case .setDNF(let on): rigState.dnfEnabled = on
        case .setAGC(let mode): rigState.agcMode = mode
        case .setMicEQ(let on): rigState.micEQEnabled = on
        case .setProcLevel(let level): rigState.procLevel = level
        case .setNBLevel(let level): rigState.nbLevel = level
        case .setDNRLevel(let level): rigState.dnrLevel = level
        case .setAntSelect(let mode): rigState.antSelect = mode
        case .setSquelchType(let mode): rigState.squelchType = mode
        case .setToneFreq(let index): rigState.ctcssToneIndex = index
        case .setDCSCode(let index): rigState.dcsCodeIndex = index
        case .setRepeaterShift(let mode): rigState.repeaterShiftMode = mode
        case .setAPRSBeaconType(let mode): rigState.aprsBeaconType = mode
        case .setFMChannelStep(let step): rigState.fmChannelStep = step
        case _ where command.isFilterSideCommand:
            rigState.applyFilterCommand(command)
        default:
            break
        }
        // Drop a tick in flight: it may have read the old value.
        if Self.isMenuSetting(command) || command.isFilterSideCommand { commandGeneration += 1 }
    }

    /// Reads `side`'s whole filter state right after something changed
    /// which values the fields should show (a MAIN/SUB switch, a swap) —
    /// `HubService.refreshFilterState`. The delay lets the queue apply the
    /// command first. Dropped if the side, its mode or the link changed
    /// meanwhile.
    private func refreshFilterState(side: FilterSide, afterDelay delay: Duration = .milliseconds(200)) async {
        try? await Task.sleep(for: delay)
        guard let rigctld else { return }
        let mode = rigState.filterMode(for: side)
        let snapshot = await rigctld.readFilterState(side: side, mode: mode)
        guard self.rigctld === rigctld, rigState.activeFilterSide == side, rigState.filterMode(for: side) == mode else { return }
        commandGeneration += 1
        rigState.applyFilterSnapshot(snapshot, mode: mode)
    }

    /// After N/W: WIDTH and the mode's NAR WIDTH preset only —
    /// `HubService.refreshWidthAfterNarrow`, without its retry (the
    /// round-robin reads catch up within a few ticks).
    private func refreshWidthAfterNarrow() async {
        let side = rigState.activeFilterSide
        let mode = rigState.filterMode
        try? await Task.sleep(for: .milliseconds(300))
        guard let rigctld else { return }
        var snapshot = FilterSnapshot()
        await FilterStateReads.width(rigctld, side, mode, &snapshot)
        await FilterStateReads.narrowPreset(rigctld, side, mode, &snapshot)
        guard self.rigctld === rigctld, rigState.activeFilterSide == side else { return }
        commandGeneration += 1
        rigState.applyFilterSnapshot(snapshot, mode: mode)
    }

    /// The MENU grid's commands (`MenuPageView`) other than tuning (HOME
    /// sends `.setFrequency`), plus Deep Settings' `.setMenuItem`, all
    /// queued as the hub queues them. Only
    /// MOX on and ANT TUNE transmit; `send` gates those first.
    nonisolated private static func isMenuSetting(_ command: RigCommand) -> Bool {
        switch command {
        case .setPowerLevel, .setBreakIn, .setKeyer, .setCWSpeed, .setCWPitch, .setBreakInDelay,
             .setCWSpot, .triggerZeroIn, .setMoniLevel, .setMox, .triggerAntennaTune, .setAtt,
             .setPreamp, .setTuner, .setDisplayContrast, .setDisplayDimmer, .setDisplayLevel,
             .setDisplayPeak, .setDisplayMarker, .setMicGain, .setAMCLevel, .setVox, .setVoxGain,
             .setVoxDelay, .setDNF, .setAGC, .setMicEQ, .setProcLevel, .setNBLevel, .setDNRLevel,
             .setAntSelect, .setSquelchType, .setToneFreq, .setDCSCode, .setRepeaterShift,
             .setAPRSBeaconType, .setFMChannelStep, .setMenuItem:
            return true
        default:
            return false
        }
    }

    #if os(iOS)
    /// PTT pressed: key through rigctld and stream the microphone to the
    /// Pi's TX audio service. The first press only asks for microphone
    /// access (the prompt takes the press) and keys nothing.
    public func startTransmit() {
        guard connectionState == .connected else { return }
        transmitProblem = nil
        if let reason = transmitBlockReason {
            transmitProblem = reason
            return
        }
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
        mainAudioEngine.stop()
        subAudioEngine.stop()
        let txClient = RemoteTXAudioClient(host: endpoint.host, port: endpoint.txAudioPort, logSubsystem: logSubsystem)
        Task { await txClient.start() }
        do {
            try microphone.start(
                sink: { pcm in await txClient.send(pcm) },
                finish: { await txClient.finish() }
            )
        } catch {
            Task { await txClient.finish() }
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
    #endif

    /// Unkey now, without the tail delay (Enable Transmit turned off).
    private func abortTransmit(reason: String) {
        logger.notice("unkeying: \(reason, privacy: .public)")
        stopTransmitLocally()
        send(.setPTT(false))
    }

    /// Microphone off and the PTT state cleared, without sending anything.
    /// Closing the TX audio connection also lets the Pi's watchdog unkey
    /// when the rigctld link is the thing that died.
    private func stopTransmitLocally() {
        #if os(iOS)
        if microphone.isRunning {
            microphone.stop()
            resumeReceiveAudio()
        }
        #endif
        unkeyTask?.cancel()
        unkeyTask = nil
        isTransmitting = false
    }

    /// Back on `.playback` after a press (the audio stream is still up);
    /// muted until the unkey lands. `disconnect()` stops them right after.
    private func resumeReceiveAudio() {
        guard audioClient != nil else { return }
        mainAudioEngine.start()
        if playsSubAudio { subAudioEngine.start() }
    }

    /// The manual override for `audioChannelsSwapped`, for when the tracked
    /// parity has drifted (a swap made while this app wasn't watching).
    public func toggleAudioChannelsSwapped() {
        setAudioChannelsSwapped(!audioChannelsSwapped, reason: "manual toggle")
    }

    private func setAudioChannelsSwapped(_ swapped: Bool, reason: String) {
        guard swapped != audioChannelsSwapped else { return }
        audioChannelsSwapped = swapped
        channelSwap.value = swapped
        AudioPlaybackSettings.channelsSwapped = swapped
        logger.notice("audio channels swapped=\(swapped, privacy: .public) (\(reason, privacy: .public))")
    }

    /// A swap or V/M the rig has just applied. Done here rather than
    /// optimistically so a poll tick can't read the pre-swap values after
    /// the baseline moved; `commandGeneration` drops a tick in flight.
    private func commandApplied(_ command: RigCommand) {
        commandGeneration += 1
        switch command {
        case .swapActiveVFO:
            let main = rigState.frequencyHz
            rigState.frequencyHz = rigState.secondaryFrequencyHz ?? main
            rigState.secondaryFrequencyHz = main
            if let subMode = rigState.secondaryMode {
                rigState.secondaryMode = rigState.mode
                rigState.mode = subMode
            }
            if rigState.singleReceive == true {
                logger.notice("app swap in single-receive display — audio channels left as is")
            } else {
                setAudioChannelsSwapped(!audioChannelsSwapped, reason: "app swap command")
            }
            if let sub = rigState.secondaryFrequencyHz, sub != rigState.frequencyHz {
                lastDistinctFrequencies = (rigState.frequencyHz, sub)
            } else {
                lastDistinctFrequencies = nil
            }
            lastVFOState = nil
            if readsFilters {
                // Whether a receiver's filters travel with the VFO or stay
                // with the receiver, re-reading shows what the rig has now.
                let side = rigState.activeFilterSide
                Task { await refreshFilterState(side: side, afterDelay: .milliseconds(400)) }
            }
        case .setVFOMemoryMode(let memory):
            rigState.vfoMemoryMode = memory ? .memory : .vfo
            if !memory, let last = lastVFOState {
                rigState.frequencyHz = last.hz
                rigState.mode = last.mode
            }
        case .setMemoryScan(let direction, let side):
            if direction == .off {
                rigState.memoryScan = .stopped
                memoryScanStartedAt = nil
                // The scanning side's box was hidden: read its channel now.
                forceSlowReads = true
            } else {
                rigState.memoryScan = .scanning
                rigState.memoryScanSide = side
                // The rig moves its TX/RX side to the scanning side.
                rigState.txSide = side
                memoryScanStartedAt = .now
            }
        case .setTXSide(let side):
            rigState.txSide = side
        default:
            break
        }
    }

    /// A front-panel swap: both frequencies exchange at once relative to
    /// the last pair where they differed — `HubService.trackExternalSwap`.
    private func trackExternalSwap(main: Int, sub: Int?) {
        guard let sub, sub != main else { return }
        if let last = lastDistinctFrequencies, main == last.sub, sub == last.main {
            setAudioChannelsSwapped(!audioChannelsSwapped, reason: "front-panel swap detected (\(last.main)/\(last.sub) → \(main)/\(sub) Hz)")
            lastVFOState = nil
        }
        lastDistinctFrequencies = (main, sub)
    }

    /// Connect, poll until the link dies, wait, retry — until cancelled by
    /// `disconnect()`.
    private func runSession(rigctld: RigctldClient, endpoint: PiEndpoint) async {
        while !Task.isCancelled {
            connectionState = .connecting
            do {
                try await rigctld.connect()
                logger.notice("connected to \(endpoint.host, privacy: .public):\(endpoint.rigctldPort)")
                connectionState = .connected
                try await pollUntilFailure(rigctld)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                logger.error("session ended: \(message, privacy: .public)")
                if isTransmitting {
                    // Can't unkey through a dead link; dropping the TX
                    // audio connection makes the Pi do it.
                    stopTransmitLocally()
                }
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
        let generation = commandGeneration

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
        if readsMenuSettings {
            let reads = Self.menuSettingReads
            for _ in 0..<Self.menuReadsPerTick {
                await reads[menuReadCursor % reads.count](rigctld, &state)
                menuReadCursor = (menuReadCursor + 1) % reads.count
            }
        }
        if readsFilters {
            // The selected side as of this tick, at the mode just read; a
            // side switch mid-tick bumps `commandGeneration`, dropping it.
            let side = state.activeFilterSide
            let mode = state.filterMode(for: side)
            var snapshot = FilterSnapshot()
            let reads = FilterStateReads.all
            for _ in 0..<Self.filterReadsPerTick {
                await reads[filterReadCursor % reads.count](rigctld, side, mode, &snapshot)
                filterReadCursor = (filterReadCursor + 1) % reads.count
            }
            state.applyFilterSnapshot(snapshot, mode: mode)
        }
        tick += 1

        guard !Task.isCancelled else { return }
        // A swap or V/M landed mid-tick: some reads may predate it.
        guard generation == commandGeneration else { return }
        trackExternalSwap(main: state.frequencyHz, sub: state.secondaryFrequencyHz)
        // Only from a genuine VFO-mode snapshot, never a channel's values.
        if state.vfoMemoryMode == .vfo {
            lastVFOState = (state.frequencyHz, state.mode)
        }
        state.lastUpdated = Date()
        state.c4fmCallsign = c4fmCallsign
        state.c4fmReflector = c4fmReflector
        applyAPRSIndicators(to: &state)
        rigState = state
        if readsVFODetails { updateWPSD() }
        // As on the hub: if the rig went to single-receive display with SUB
        // selected, fall back to MAIN through the normal path.
        if readsFilters, state.singleReceive == true, state.activeFilterSide == .sub {
            logger.notice("single-receive display while SUB filter selected — falling back to MAIN")
            send(.setFilterSide(.main))
        }
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
            if let info = (try? await rigctld.getRadioInformation()).flatMap({ $0 }),
               !(info.scan == .stopped && memoryScanStartedAt.map { ContinuousClock.now - $0 < .seconds(1) } == true) {
                if info.scan == .stopped, scanWasActive {
                    // Stopped without the app (front panel): leave the TX
                    // side as the rig has it, as the hub does.
                    txSideBeforeMemoryScan = nil
                }
                state.memoryScan = info.scan
                // "SC;" reads back the side last told to scan, e.g.
                // "SC11;" — also how a front-panel scan's side is learned.
                if info.scan != .stopped,
                   let side = (try? await rigctld.getRawDigit("SC")).flatMap({ $0 }).flatMap(FilterSide.init(rawValue:)) {
                    state.memoryScanSide = side
                }
            }
        } else {
            state.memoryScan = nil
        }
    }

    /// One MENU-grid field read into the tick's state. Best-effort: a failed
    /// read keeps the last value.
    private typealias MenuSettingRead = (RigctldClient, inout RigState) async -> Void

    /// The fields `MenuPageView` shows, read the way `HubService.
    /// slowTierSteps()` reads them (see its comments for each command's
    /// quirks). Not here because `refreshVFODetails` reads them already:
    /// "FR", "ST", "FT", "VM1"; not shown by the grid: the filter fields,
    /// "TS", the CW MESSAGE status.
    private static let menuSettingReads: [MenuSettingRead] = [
        { if let v = try? await $0.getLevel("RFPOWER") { $1.powerLevel = v } },
        { if let v = try? await $0.getRawBool("BI") { $1.breakIn = v } },
        { if let v = try? await $0.getRawBool("KR") { $1.keyerEnabled = v } },
        { if let v = try? await $0.getRawInt("KS") { $1.cwSpeedWpm = v } },
        // 00-75 steps above 300 Hz.
        { if let v = try? await $0.getRawInt("KP") { $1.cwPitchHz = 300 + v * 10 } },
        { if let v = (try? await $0.getRawInt("SD")).flatMap(RigDelayCode.milliseconds(forCode:)) { $1.bkDelayMs = v } },
        { if let v = try? await $0.getRawBool("CS") { $1.cwSpot = v } },
        // "ML1" is the level; "ML0" would be MONI on/off.
        { if let v = try? await $0.getRawInt("ML1") { $1.moniLevel = v } },
        { if let v = try? await $0.getRawBool("MX") { $1.moxEnabled = v } },
        { if let v = try? await $0.getRawBool("RA0") { $1.attEnabled = v } },
        { if let v = try? await $0.getRawInt("PA0") { $1.preampMode = v } },
        { if let v = try? await $0.getTunerEnabled() { $1.tunerEnabled = v } },
        { rigctld, state in
            if let v = try? await rigctld.getDisplaySettings() {
                state.displayContrast = v.contrast
                state.displayDimmer = v.brightness
            }
        },
        { if let v = try? await $0.getSpectrumScopeLevel() { $1.displayLevel = v } },
        { if let v = try? await $0.getRawDigit("SS01") { $1.displayPeak = v } },
        { if let v = try? await $0.getRawBool("SS02") { $1.displayMarker = v } },
        { if let v = try? await $0.getRawInt("MG") { $1.micGain = v } },
        { if let v = try? await $0.getRawInt("AO") { $1.amcLevel = v } },
        { if let v = try? await $0.getRawBool("VX") { $1.voxEnabled = v } },
        { if let v = try? await $0.getRawInt("VG") { $1.voxGain = v } },
        { if let v = (try? await $0.getRawInt("VD")).flatMap(RigDelayCode.milliseconds(forCode:)) { $1.voxDelayMs = v } },
        { if let v = try? await $0.getRawBool("BC0") { $1.dnfEnabled = v } },
        // "GT0"/"PR1" go unanswered in C4FM, each costing a raw-CAT
        // timeout and a reconnect — skipped then, as on the Mac.
        { rigctld, state in
            guard state.mode != .c4fm, let v = try? await rigctld.getRawInt("GT0") else { return }
            state.agcMode = v
        },
        { rigctld, state in
            guard state.mode != .c4fm, let v = try? await rigctld.getRawBool("PR1") else { return }
            state.micEQEnabled = v
        },
        { if let v = try? await $0.getRawInt("PL") { $1.procLevel = v } },
        { if let v = try? await $0.getRawInt("NL0") { $1.nbLevel = v } },
        { if let v = try? await $0.getRawInt("RL0") { $1.dnrLevel = v } },
        // HF ANT SELECT, BEACON TYPE and FM CH STEP have no mnemonic of
        // their own: "EX" at fixed addresses.
        { if let v = (try? await $0.getMenuItem(p1: 3, p2: 7, p3: 4)).flatMap(Int.init) { $1.antSelect = v } },
        { if let v = try? await $0.getRawDigit("CT0") { $1.squelchType = v } },
        { if let v = try? await $0.getRawInt("CN00") { $1.ctcssToneIndex = v } },
        { if let v = try? await $0.getRawInt("CN01") { $1.dcsCodeIndex = v } },
        { if let v = try? await $0.getRawDigit("OS0") { $1.repeaterShiftMode = v } },
        { if let v = (try? await $0.getMenuItem(p1: 7, p2: 1, p3: 1)).flatMap(Int.init) { $1.aprsBeaconType = v } },
        { if let v = (try? await $0.getMenuItem(p1: 3, p2: 6, p3: 6)).flatMap(Int.init) { $1.fmChannelStep = v } },
    ]

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

/// Where `PiDirectViewModel` finds the Pi's services: rigctld, the receive
/// audio stream (`Pi/ftx1-audiostream.py`) and the transmit audio service
/// (`Pi/ftx1-txaudio.py`). The real Pi's ports are fixed, like the Mac's
/// `.remote` mode — only the host is configurable; Demo Mode's simulator
/// listens on loopback ports the system picks.
public struct PiEndpoint: Equatable, Sendable {
    public var host: String
    public var rigctldPort: UInt16
    public var audioPort: UInt16
    public var txAudioPort: UInt16

    public init(host: String, rigctldPort: UInt16 = 4532, audioPort: UInt16 = 8532, txAudioPort: UInt16 = RemoteTXAudioClient.defaultPort) {
        self.host = host
        self.rigctldPort = rigctldPort
        self.audioPort = audioPort
        self.txAudioPort = txAudioPort
    }
}

/// `audioChannelsSwapped`, readable from the audio client's actor.
private final class ChannelSwapFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Each side's APRS gate, readable from the audio client's actor.
private final class APRSGateFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = (main: false, sub: false)

    var value: (main: Bool, sub: Bool) { lock.withLock { stored } }

    func set(main: Bool, sub: Bool) {
        lock.withLock { stored = (main, sub) }
    }
}

/// Lets the shared `MenuPageView` run on this route (the iPad's Pi-direct
/// screen). Recording keeps the protocol's unsupported default.
// MARK: - CW keyer memory (the iPad's CW send section)

extension PiDirectViewModel {
    /// Writes CW TEXT keyer memory `slot` and returns what the rig stored
    /// (`RigctldClient.writeKeyerMemory`). Straight over the rigctld link,
    /// like `HubService.writeCWKeyerMemory`; doesn't transmit.
    public func writeCWKeyerMemory(slot: Int, text: String) async throws -> String {
        guard readsMenuSettings, connectionState == .connected, let rigctld else { throw RigctldError.notConnected }
        return try await rigctld.writeKeyerMemory(slot: slot, text: text)
    }

    /// Makes sure keyer memory `slot` is a TEXT memory (CW SETTING → KEYER
    /// → CW MEMORY 1-5, "EX" 02 02 06-10: 0 TEXT, 1 MESSAGE), as
    /// `HubService.ensureCWTextMemory` does.
    public func ensureCWTextMemory(slot: Int) async throws {
        guard readsMenuSettings, connectionState == .connected, let rigctld else { throw RigctldError.notConnected }
        let value = try await rigctld.getMenuItem(p1: 2, p2: 2, p3: 5 + slot)
        if value != "0" {
            logger.notice("CW MEMORY \(slot) was \(value ?? "unreadable", privacy: .public); setting it to TEXT")
            try await rigctld.setMenuItem(p1: 2, p2: 2, p3: 5 + slot, rawValue: "0")
        }
    }
}

extension PiDirectViewModel: RigController {
    public var supportsDeepSettings: Bool { readsMenuSettings }

    /// S.LIST/M.LIST show this device's own decode (`aprsStore`).
    public var supportsAPRSDecoding: Bool { aprsStore != nil }

    /// Straight over the rigctld link, like `HubService.readMenuItem`; its
    /// round-trip lock interleaves these with the poll's reads.
    public func readMenuItem(p1: Int, p2: Int, p3: Int) async -> String? {
        guard readsMenuSettings, connectionState == .connected, let rigctld else { return nil }
        return try? await rigctld.getMenuItem(p1: p1, p2: p2, p3: p3)
    }
}

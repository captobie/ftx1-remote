import Combine
import CoreGraphics
import FTX1Core
import Foundation
import os

/// The Mac hub: owns the `RigctldClient` connection and the `CommandQueue`
/// that serializes commands into it, and polls rigctld for state changes
/// (rigctld has no server-push of its own — this is the only way to notice
/// e.g. a PTT toggled from the radio's own front panel). Also owns the
/// `RigWebSocketServer` that re-broadcasts this state to mobile clients and
/// forwards their commands into the same `CommandQueue`, and the
/// `RigctldProcessController` that actually starts/stops the `rigctld`
/// daemon itself.
///
/// Two independent lifecycles live here:
///  - The WebSocket server (`start()`/`stop()`) runs for as long as the app
///    does, regardless of window state — mobile clients shouldn't lose
///    their connection just because the rig link is toggled off.
///  - The rigctld process + polling loop (`startRigctld()`/`stopRigctld()`)
///    is what the on/off switch controls.
@MainActor
final class HubService: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var rigState = RigState(transmitEnabled: RigctldSettings.transmitEnabled)
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var rigctldProcessState: RigctldProcessController.State = .stopped
    /// Whether the on/off toggle has been switched on — true from
    /// `startRigctld()` until `stopRigctld()`. A mode-independent stand-in
    /// for `rigctldProcessState == .running/.starting`: that reflects
    /// `RigctldProcessController`'s local-process lifecycle, which has
    /// nothing to report in `RigctldSettings.ConnectionMode.remote` (see
    /// `startRigctld()` below) since nothing is ever spawned there.
    @Published private(set) var isActive = false
    /// Mirrors `audioRecorder.isRecording`, same "reflect a subsystem's own
    /// state into a `@Published` property" shape as `rigctldProcessState`
    /// mirroring `RigctldProcessController` — lets `MenuPageView`'s RECORD
    /// button (observing `HubService` via the `RigController` protocol)
    /// react to a toggle without `AudioRecorder` itself being an
    /// `ObservableObject` every view would need to import separately.
    @Published private(set) var isRecordingAudio = false
    /// The live waterfall/oscilloscope frames — deliberately NOT
    /// `@Published` on this object. `AudioCaptureEngine` delivers a new
    /// frame ~21 times a second (44100 Hz / 2048-sample chunks), and when
    /// these were `@Published` here, every frame invalidated everything
    /// observing `HubService` — i.e. all of `ContentView`, including the
    /// 28-button `MenuPageView` grid and two `.segmented` pickers, whose
    /// `NSSegmentedControl` relayout was measured (2026-09-09, `sample` on
    /// a Release build) at ~50% of a core, continuously, with the rest of
    /// the app near idle. A separate store lets only `ScopeDisplayView`
    /// subscribe, so the 21 Hz churn stops at that one leaf view.
    let scopeFrames = ScopeFrameStore()
    @Published private(set) var waterfallZoom: Float = 1
    @Published private(set) var oscilloscopeZoom: Float = 1
    /// Whether the Mac itself plays the captured radio audio out loud —
    /// independent of the waterfall/oscilloscope display and of the
    /// Mac→iPad relay, both of which keep running regardless. Persisted via
    /// `AudioPlaybackSettings.isMuted` (shared with iPad, though iPad has no
    /// UI for it yet) so the choice survives a relaunch.
    @Published private(set) var isAudioMuted = AudioPlaybackSettings.isMuted
    /// Both bound directly by the Mac's squelch/volume sliders (`ContentView`)
    /// — plain read-write `@Published`, not `private(set)`, since SwiftUI
    /// needs a two-way `Binding` to a slider's value. `didSet` pushes the
    /// live change straight into `audioPlayback` and persists it via
    /// `AudioPlaybackSettings` (shared with iPad, same as `isAudioMuted`)
    /// in one place rather than needing a separate setter method per
    /// property. Initial squelch default (0.02) is what left audio gated
    /// silent on the Mac before this UI existed to raise or lower it —
    /// see the "Audio-over-Pi" section of repo root CLAUDE.md.
    @Published var audioVolume: Float = Float(AudioPlaybackSettings.volume) {
        didSet {
            audioPlayback.volume = audioVolume
            AudioPlaybackSettings.volume = Double(audioVolume)
        }
    }
    /// See `SquelchGate`'s doc comment — this is now a "how close to true
    /// silence counts as quieting" cutoff, not a loudness gate. `ContentView`
    /// inverts the slider's displayed direction so raising it still reads as
    /// "tighter," matching a normal squelch knob, even though a *smaller*
    /// stored value is what's actually stricter here.
    @Published var squelchThreshold: Float = Float(AudioPlaybackSettings.squelchThreshold) {
        didSet {
            audioPlayback.squelchThreshold = squelchThreshold
            AudioPlaybackSettings.squelchThreshold = Double(squelchThreshold)
        }
    }
    /// Bound live by `SettingsView`'s "Enable Transmit" toggle — unlike the
    /// rest of the rigctld tab, this applies immediately rather than
    /// waiting for "Done", since it's a safety cutoff, not a connection
    /// parameter. `didSet` persists it, mirrors it into `rigState` (so
    /// remote clients see the same disabled state — see `MenuPageView`'s
    /// MOX/ANT TUNE buttons and each app target's PTT button), broadcasts
    /// the change, and — if switched off mid-transmission — force-unkeys
    /// the rig immediately rather than just blocking future attempts.
    @Published var transmitEnabled: Bool = RigctldSettings.transmitEnabled {
        didSet {
            RigctldSettings.transmitEnabled = transmitEnabled
            rigState.transmitEnabled = transmitEnabled
            if !transmitEnabled {
                if rigState.ptt { send(.setPTT(false)) }
                if rigState.moxEnabled == true { send(.setMox(false)) }
            }
            let state = rigState
            Task { await server.broadcast(state) }
        }
    }

    private let rigctld: RigctldClient
    private let commandQueue: CommandQueue
    private let server: RigWebSocketServer
    private let rigctldProcess = RigctldProcessController()
    private let audioCapture = AudioCaptureEngine()
    private let audioStreamEncoder = AudioStreamEncoder()
    /// Backs the CW page's RECORD/PLAY buttons (`MenuPageView`) — see
    /// `AudioRecorder`'s doc comment. Fed unconditionally from the same
    /// `audioCapture.onAudioSamples` tap as `ft8Coordinator`/`aprsDecoder`
    /// below; it's a no-op internally whenever not recording. Not
    /// `private` — `HubService+RigController.swift`'s `toggleAudioRecording()`
    /// calls into it directly, same visibility as `aprsStore`/`ft8Store`.
    let audioRecorder = AudioRecorder()
    /// Plays the same captured audio locally on the Mac that
    /// `audioStreamEncoder` sends to iPad clients — reuses `AudioPlaybackEngine`
    /// as-is (already cross-platform, see its own doc comment) rather than a
    /// second implementation. Started/stopped alongside `audioCapture`, fed
    /// the exact same encoded PCM chunk `broadcastAudio` sends, in
    /// `onAudioSamples` below.
    private let audioPlayback = AudioPlaybackEngine()
    private let wpsdMonitor = WPSDCallsignMonitor()
    private let aprsDecoder = APRSDecoder()
    let aprsStore = APRSStore()
    /// Unlike `aprsDecoder`, not wired into `audioCapture.onAudioSamples`
    /// unconditionally — `ingest(samples:sampleRate:)` drops audio on its
    /// own whenever `isRunning` is false, and `isRunning` only becomes true
    /// between `startFT8Decoding()`/`stopFT8Decoding()`, called from the
    /// Digital/FT8 window's lifecycle, not from `start()`/`init` here. See
    /// `FT8DecodeCoordinator`'s doc comment for why FT8 can't reuse APRS's
    /// always-on frequency-gate pattern.
    private let ft8Coordinator = FT8DecodeCoordinator()
    let ft8Store = FT8Store()
    private let webSocketPort: UInt16
    private let rigctldHost: String
    private let rigctldPort: UInt16
    private var runLoopTask: Task<Void, Never>?
    private var webSocketServerTask: Task<Void, Never>?
    /// Holds off App Nap for as long as `audioCapture` is running — see
    /// `beginBackgroundActivity()`'s doc comment.
    private var backgroundActivityToken: NSObjectProtocol?
    /// Diagnostic-only — logs only on a state transition, not per-buffer.
    /// See `APRSDecoder`'s heartbeat logging for the matching "is audio
    /// still reaching the decoder" question on the other side of the gate.
    private var aprsGateWasActive = false
    private static let aprsGateLogger = Logger(subsystem: "com.ftx1remote.mac", category: "aprs-gate")
    /// Diagnostic-only — surfaces exactly what `runConnectionLoop` caught,
    /// since `connectionState`'s `.failed(String)` case (backed by
    /// `error.localizedDescription`) is not shown anywhere in the UI today,
    /// and a plain `RigctldError`/`NWError` case with no `LocalizedError`
    /// conformance produces an unhelpful generic string there anyway.
    /// Check via Console.app (subsystem "com.ftx1remote.mac", category
    /// "connection") regardless of how the app was launched.
    private static let connectionLogger = Logger(subsystem: "com.ftx1remote.mac", category: "connection")
    /// Most recently APRS-decoded station + when it was heard.
    /// `refreshFastTier` (the ~500ms poll/broadcast cycle) surfaces this as
    /// `RigState.aprsLastCallsign` for up to 5 seconds past `at`, then lets
    /// it read back as `nil` — no separate expiry `Timer` needed since that
    /// cycle runs often enough on its own to notice the 5-second mark
    /// passing.
    private var aprsLastCallsignHeard: (callsign: String, at: Date)?

    /// Bumped by `applyOptimistically` every time a command lands.
    /// `refreshFastTier`/`refreshSlowTier` (the two halves the poll cycle is
    /// split into — see their doc comments) each check this before and after
    /// their own sequential reads to detect whether a command was
    /// optimistically applied mid-cycle — see their use below for why that
    /// matters.
    private var commandGeneration = 0

    /// Counts fast-tier poll ticks so `pollLoop()` runs `refreshSlowTier()`
    /// only every `slowTierInterval`th tick instead of every tick.
    private var slowTierTickCounter = 0
    /// ~3s at the default 500ms `pollInterval`. The slow tier only needs to
    /// catch external (front-panel) menu changes or correct a mispredicted
    /// optimistic value — changes made through the app already show up
    /// instantly via `applyOptimistically` — so trading a few seconds of
    /// staleness on menu/settings fields is an acceptable price for them no
    /// longer sharing a path with the VFO display (see `refreshFastTier`'s
    /// doc comment).
    private static let slowTierInterval = 6

    /// The Main-side frequency/mode most recently polled while the rig was
    /// in VFO (not Memory) mode — refreshed every poll tick in VFO mode,
    /// frozen the moment Memory mode is entered, so it always holds "what
    /// the VFO was showing right before the memory channel took over".
    /// `send(_:)` replays it after `.setVFOMemoryMode(memory: false)`.
    ///
    /// Why: driven over CAT from this app, "VM000" flips the rig's VFO/
    /// Memory flag but leaves the Main-side frequency/mode parked on the
    /// memory channel's values; the front-panel V/M button restores the
    /// VFO correctly, so the rig does keep a parked VFO — it just doesn't
    /// expose it: `MR00000;` (the manual's "read VFO" channel) answers
    /// with the *active memory channel's* contents while in Memory mode,
    /// confirmed on real hardware 2026-09-08. Three attempts at giving the
    /// CAT link quiet time around the exit write (poll-snapshot discard,
    /// poll-loop pause, lock-held pause) all failed on hardware — see git
    /// log — so rather than keep hunting for a way to make the rig restore
    /// the VFO itself, the hub remembers the VFO and puts it back
    /// explicitly. `nil` until the first VFO-mode poll completes (e.g. the
    /// app launched with the rig already in Memory mode), in which case
    /// the exit falls back to a bare "VM000".
    private var lastVFOState: (hz: Int, mode: RigMode)?

    private let pollInterval: Duration
    private let reconnectDelay: Duration
    private let startupRetryInterval: Duration
    private let startupGracePeriod: Duration

    init(
        rigctldHost: String = "127.0.0.1",
        rigctldPort: UInt16 = 4532,
        webSocketPort: UInt16 = 8765,
        pollInterval: Duration = .milliseconds(500),
        reconnectDelay: Duration = .seconds(3),
        startupRetryInterval: Duration = .milliseconds(250),
        startupGracePeriod: Duration = .seconds(10)
    ) {
        let client = RigctldClient(host: rigctldHost, port: rigctldPort)
        self.rigctld = client
        self.commandQueue = CommandQueue(rigctld: client)
        self.server = RigWebSocketServer()
        self.webSocketPort = webSocketPort
        self.rigctldHost = rigctldHost
        self.rigctldPort = rigctldPort
        self.pollInterval = pollInterval
        self.reconnectDelay = reconnectDelay
        self.startupRetryInterval = startupRetryInterval
        self.startupGracePeriod = startupGracePeriod

        rigctldProcess.onStateChange = { [weak self] state in
            self?.rigctldProcessState = state
        }
        audioRecorder.onRecordingStateChanged = { [weak self] isRecording in
            self?.isRecordingAudio = isRecording
        }
        audioCapture.onNewFrame = { [weak self] frame in
            self?.scopeFrames.update(frame)
        }
        audioCapture.setDisplayEnabled(ScopeDisplayMode.persisted != .off)
        audioCapture.onAudioSamples = { [weak self] samples, sampleRate in
            guard let self else { return }

            // Relay to mobile clients for the iPad's audio-playback panel
            // (see AudioStreamEncoder/RigWebSocketServer.broadcastAudio) —
            // unconditional, unlike the APRS gate below: this isn't tied to
            // frequency, and `broadcastAudio` itself is a cheap no-op when
            // no client is connected, so there's no need to check that here
            // before paying the (also cheap) conversion cost.
            if let pcm = self.audioStreamEncoder.encode(samples: samples, sampleRate: sampleRate) {
                Task { await self.server.broadcastAudio(pcm) }
                if !self.isAudioMuted {
                    self.audioPlayback.push(pcm: pcm)
                }
            }

            // Unconditional (no frequency gate) — deliberately BEFORE the
            // APRS gate below returns early. ft8Coordinator drops this
            // itself when not running (see its doc comment); it must not be
            // downstream of `guard isActive else { return }`, which gates
            // on the APRS calling frequency specifically and would
            // otherwise silently starve FT8 of audio on every other band.
            self.ft8Coordinator.ingest(samples: samples, sampleRate: sampleRate)

            // Same reasoning as ft8Coordinator above — recording isn't tied
            // to any calling frequency either, and `audioRecorder` itself
            // drops this when not recording.
            self.audioRecorder.ingest(samples: samples, sampleRate: sampleRate)

            let isActive = APRSSettings.isActive(atFrequencyHz: self.rigState.frequencyHz)
            if isActive != self.aprsGateWasActive {
                self.aprsGateWasActive = isActive
                Self.aprsGateLogger.debug("APRS gate \(isActive ? "opened" : "closed", privacy: .public) at \(self.rigState.frequencyHz) Hz")
            }
            guard isActive else { return }
            self.aprsDecoder.process(samples: samples, sampleRate: sampleRate)
        }
        aprsDecoder.onStation = { [weak self] callsign, latitude, longitude, symbolTable, symbolCode, comment in
            self?.aprsLastCallsignHeard = (callsign, Date())
            self?.aprsStore.recordStation(callsign: callsign, latitude: latitude, longitude: longitude, symbolTable: symbolTable, symbolCode: symbolCode, comment: comment, heardAt: Date())
        }
        aprsDecoder.onMessage = { [weak self] from, to, text, messageID in
            self?.aprsStore.recordMessage(from: from, to: to, text: text, messageID: messageID, receivedAt: Date())
        }
        ft8Coordinator.dialFrequencyProvider = { [weak self] in
            self?.rigState.frequencyHz ?? 0
        }
        ft8Coordinator.onSpotsDecoded = { [weak self] coordinatorSpots in
            guard let self else { return }
            let spots = coordinatorSpots.map { FT8Spot(coordinatorSpot: $0) }
            self.ft8Store.record(spots)
        }
        ft8Coordinator.onCycleStatusChanged = { [weak self] status in
            self?.ft8Store.updateCycleStatus(status)
        }
        wpsdMonitor.onCallsignUpdate = { [weak self] callsign in
            self?.rigState.c4fmCallsign = callsign
        }
        wpsdMonitor.onReflectorUpdate = { [weak self] reflector in
            self?.rigState.c4fmReflector = reflector
        }
    }

    /// App-launch lifecycle: starts the WebSocket server. Independent of
    /// the rigctld link — mobile/local clients can connect immediately and
    /// see "rig offline" rather than being unable to reach the Mac at all.
    func start() {
        Task { [weak self, commandQueue] in
            await commandQueue.setOnCommandApplied { command in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyOptimistically(command)
                    // Broadcasts the same optimistic value the Mac's own
                    // `rigState` binding already shows instantly — without
                    // this, a remote (iPad) client only saw an app-triggered
                    // change once the next poll tick republished it (up to
                    // ~3s later for a slow-tier field). See
                    // `applyOptimistically`'s doc comment for why predicting
                    // the outcome here is safe.
                    await self.server.broadcast(self.rigState)
                }
            }
        }
        startWebSocketServer()
    }

    /// Retries the bind indefinitely (reusing `reconnectDelay` as the
    /// interval — no need for a second, separately-tuned constant here)
    /// whenever `RigWebSocketServer.isListening()` reports false — covers
    /// both the initial bind failing (e.g. the port still held by a
    /// just-killed previous instance) and a later failure it clears itself
    /// (see that type's `stateUpdateHandler`). Without this, a one-time
    /// bind failure would silently and permanently disable the WebSocket
    /// server for the rest of the app's life: the Mac's own local UI calls
    /// `HubService` directly and never touches this server, so nothing
    /// else would ever notice or recover it.
    private func startWebSocketServer() {
        guard webSocketServerTask == nil else { return }
        let port = webSocketPort
        webSocketServerTask = Task { [weak self, server, reconnectDelay] in
            while !Task.isCancelled {
                if await server.isListening() {
                    try? await Task.sleep(for: reconnectDelay)
                    continue
                }
                try? await server.start(port: port) { command in
                    Task { @MainActor in self?.send(command) }
                }
                try? await Task.sleep(for: reconnectDelay)
            }
        }
    }

    /// App-termination lifecycle: stops the WebSocket server and ensures
    /// rigctld isn't left running as an orphaned child process.
    func stop() {
        stopRigctld()
        stopFT8Decoding()
        webSocketServerTask?.cancel()
        webSocketServerTask = nil
        Task { [server] in await server.stop() }
    }

    /// Called from the Digital/FT8 window's `.onAppear` — decoding runs
    /// only while that window is open (see `FT8DecodeCoordinator`'s doc
    /// comment for why FT8 can't reuse APRS's always-on gate).
    func startFT8Decoding() {
        ft8Coordinator.start()
    }

    /// Called from the Digital/FT8 window's `.onDisappear`, and as a safety
    /// net from `stop()` in case the app quits with that window still open.
    func stopFT8Decoding() {
        ft8Coordinator.stop()
    }

    /// What the on/off switch calls: launches rigctld (clearing out any
    /// stale rigctld left over from a previous run first — see
    /// `RigctldProcessController`), then starts the polling loop. rigctld
    /// still takes a moment after spawning to open the serial device and
    /// bind its TCP listener, so the very first connection attempt races
    /// it and reliably fails — `connectRigctld(isFreshStart:)` suppresses
    /// surfacing that as a `.failed` connectionState for a short grace
    /// window, retrying quickly instead, so the UI doesn't flash an error
    /// on every normal startup.
    func startRigctld() {
        isActive = true
        guard RigctldSettings.connectionMode == .local else {
            // Remote mode: rigctld already runs on the configured host (e.g.
            // a Raspberry Pi over Tailscale) — this Mac only ever connects
            // to it as a network client, never spawns or owns the process.
            // `isFreshStart: false` is deliberate too: that grace period
            // exists for a rigctld this app just spawned and is still
            // opening its serial device/binding its port, which doesn't
            // apply to one that was already running before this app
            // launched.
            connectRigctld(isFreshStart: false)
            return
        }
        let config = RigctldProcessController.Configuration(
            binaryPath: RigctldSettings.binaryPath,
            modelNumber: RigctldSettings.modelNumber,
            devicePath: RigctldSettings.devicePath,
            baudRate: RigctldSettings.baudRate,
            host: rigctldHost,
            port: rigctldPort,
            pttPort: RigctldSettings.pttPort
        )
        Task { [weak self, rigctldProcess] in
            await rigctldProcess.start(with: config)
            self?.connectRigctld(isFreshStart: true)
        }
    }

    func stopRigctld() {
        isActive = false
        disconnectRigctld()
        guard RigctldSettings.connectionMode == .local else { return }
        rigctldProcess.stop()
    }

    /// `.setBand` is resolved here rather than in `CommandQueue` — rigctld
    /// has no "set band" verb, so band selection really means "jump to a
    /// frequency", and knowing *which* frequency (the last one used on that
    /// band, or a sensible default the first time) is app-level band-plan
    /// knowledge, not something the low-level command serializer should
    /// own. This is the only path commands take (local UI and WebSocket-
    /// forwarded mobile commands both call this), so it covers both.
    func send(_ command: RigCommand) {
        if !transmitEnabled, Self.isTransmitCapable(command) {
            Self.connectionLogger.notice("Blocked transmit-capable command (transmit disabled): \(String(describing: command), privacy: .public)")
            return
        }
        if Self.isTransmitCapable(command), BandPlan.band(containing: rigState.frequencyHz) == nil {
            Self.connectionLogger.notice("Blocked transmit-capable command (outside amateur band): \(String(describing: command), privacy: .public)")
            return
        }
        if case .setBand(let name) = command {
            // Captured synchronously, before the Task below does anything
            // async, so it reflects the band being left at the moment this
            // command was issued — not whatever `rigState.frequencyHz`/
            // `.band` have drifted to once the Task actually runs.
            let departingBand = BandPlan.band(containing: rigState.frequencyHz)
            if let band = BandPlan.band(named: name) {
                let targetHz = BandMemory.lastFrequencyHz(forBand: band.name) ?? band.defaultFrequencyHz
                let targetMode = BandMemory.lastMode(forBand: band.name)
                let targetFilterWidth = BandMemory.lastFilterWidthIndex(forBand: band.name)
                Task {
                    await Self.captureFilterWidth(leaving: departingBand, rigctld: self.rigctld)
                    await commandQueue.enqueue(.setFrequency(hz: targetHz))
                    if let targetMode {
                        await commandQueue.enqueue(.setMode(targetMode))
                    }
                    // Width must go out after mode, not before — "SH"'s P3
                    // index is interpreted against the *current* mode (see
                    // RigState.filterWidthIndex), so applying it before the
                    // mode restore above would apply the saved index against
                    // whatever mode a mode-forcing segment left the rig in.
                    if let targetFilterWidth {
                        await commandQueue.enqueue(.setFilterWidth(targetFilterWidth))
                    }
                }
            } else if let segment = GeneralCoverageSegments.segment(named: name) {
                let targetHz = BandMemory.lastFrequencyHz(forBand: segment.name) ?? segment.defaultFrequencyHz
                Task {
                    await Self.captureFilterWidth(leaving: departingBand, rigctld: self.rigctld)
                    await commandQueue.enqueue(.setFrequency(hz: targetHz))
                    await commandQueue.enqueue(.setMode(segment.defaultMode))
                }
            }
            return
        }
        // General-coverage segments (SW broadcast, aircraft, etc.) get a
        // conventional receive mode auto-selected the moment the primary
        // VFO crosses into them — edge-triggered against the *previous*
        // frequency's segment so stepping around inside one segment (the
        // ±100Hz/1kHz/10kHz steppers in `FrequencyEntryView`) doesn't
        // resend the same mode change on every step. `generalCoverageSegment`
        // treats an overlapping amateur allocation as taking precedence
        // (see its doc comment), so normal ham-band tuning never matches
        // here at all.
        if case .setFrequency(let hz) = command,
           let newSegment = generalCoverageSegment(at: hz),
           newSegment != generalCoverageSegment(at: rigState.frequencyHz) {
            Task {
                await commandQueue.enqueue(command)
                await commandQueue.enqueue(.setMode(newSegment.defaultMode))
            }
            return
        }
        // Same "app-level knowledge lives here, not in the serializer"
        // reasoning as `.setBand`: restoring the VFO after leaving Memory
        // mode needs `lastVFOState`, which only the hub tracks. Order
        // matters — the rig rejects an "FA" set with "?;" while still in
        // Memory mode (per hamlib's FTX-1 backend source), so the mode
        // flip must go out first; `CommandQueue` is FIFO, so enqueueing in
        // sequence guarantees that.
        if case .setVFOMemoryMode(memory: false) = command, let last = lastVFOState {
            Task {
                await commandQueue.enqueue(command)
                await commandQueue.enqueue(.setFrequency(hz: last.hz))
                await commandQueue.enqueue(.setMode(last.mode))
            }
            return
        }
        if case .setNarrow = command {
            // NAR moves the passband to the mode's narrow preset, so the
            // width the slow tier last read is stale the moment this
            // lands — re-read it right behind the write rather than
            // leaving the Width readout wrong for up to a slow-tier
            // interval (~10s).
            Task {
                await commandQueue.enqueue(command)
                await refreshWidthAfterNarrow()
            }
            return
        }
        Task { await commandQueue.enqueue(command) }
    }

    /// Freshly reads the current "SH" WIDTH index directly (bypassing the
    /// poll cycle entirely) and records it for `band`, if leaving one.
    ///
    /// This exists because relying on `refreshSlowTier()`'s periodic read to
    /// have already captured the right value — the way frequency/mode are
    /// captured on every fast-tier tick (~500ms) — doesn't work for width:
    /// the slow tier only runs every `slowTierInterval`th tick (~3s), so a
    /// band switch that follows a manual width change within that window
    /// left `BandMemory` holding nothing (or a stale value) for the band
    /// being left, and `.setBand`'s restore had no correct width to replay.
    /// A one-off direct read at the exact moment of departure has no such
    /// gap — confirmed against real hardware that a live "w SH0;"/"w
    /// SH00XX;" round trip correctly reads/sets the width, so the bug was
    /// this timing gap, not the raw CAT encoding itself.
    private static func captureFilterWidth(leaving band: Band?, rigctld: RigctldClient) async {
        guard let band, let width = try? await rigctld.getRawInt("SH0") else { return }
        BandMemory.recordFilterWidthIndex(width, forBand: band.name)
    }

    /// The general-coverage segment (SW broadcast, aircraft, marine, etc.)
    /// a frequency falls in, if any — `nil` whenever the frequency is
    /// inside an amateur allocation, even one that geometrically overlaps a
    /// segment (e.g. SW 41m vs. ham 40m), so normal ham-band operation
    /// never gets reinterpreted as tuning into a broadcast segment.
    private func generalCoverageSegment(at hz: Int) -> GeneralCoverageSegment? {
        guard BandPlan.band(containing: hz) == nil else { return nil }
        return GeneralCoverageSegments.segment(containing: hz)
    }

    /// Whether a command actually keys the transmitter (or, for
    /// `.setPTT`/`.setMox`, keys it *on* — the "off" direction is always
    /// safe and must never be blocked, including the force-unkey in
    /// `transmitEnabled`'s `didSet` above). Deliberately an exhaustive
    /// switch with no `default:`, same convention as `applyOptimistically`/
    /// `CommandQueue.apply`'s `RigCommand` switches — so a future new
    /// transmit-capable command forces a compile error here rather than
    /// silently slipping past the `transmitEnabled` gate in `send(_:)`.
    private static func isTransmitCapable(_ command: RigCommand) -> Bool {
        switch command {
        case .setPTT(let on): return on
        case .setMox(let on): return on
        case .playCWMessage, .triggerAntennaTune: return true
        case .setFrequency, .setSecondaryFrequency, .swapActiveVFO, .setMode, .setBand,
             .setPowerLevel, .setBreakIn, .setKeyer, .setCWSpeed, .setCWPitch, .setBreakInDelay,
             .setCWSpot, .triggerZeroIn, .setMoniLevel, .selectCWMessageChannel,
             .setCWMessageRecording, .setAtt, .setPreamp, .setTuner, .setDisplayContrast,
             .setDisplayDimmer, .setDisplayLevel, .setDisplayPeak, .setDisplayMarker, .setMicGain,
             .setAMCLevel, .setVox, .setVoxGain, .setVoxDelay, .setDNF, .setAGC, .setMicEQ,
             .setProcLevel, .setNBLevel, .setDNRLevel, .setFilterWidth, .setIFShift, .setNotch, .setNotchFrequency, .setContour, .setContourFrequency, .setAPF, .setAPFOffset, .setNarrow, .setAntSelect, .setTXW, .setSquelchType,
             .setToneFreq, .setDCSCode, .setRepeaterShift, .setAPRSBeaconType, .setFMChannelStep,
             .setMenuItem, .setVFOMemoryMode, .setMemoryChannel, .stepMemoryChannel:
            return false
        }
    }

    /// Mirrors a just-applied `RigCommand` straight into `rigState`, called
    /// once `CommandQueue` confirms the write reached rigctld (see
    /// `start()`'s `onCommandApplied` wiring, which also broadcasts the
    /// result to WebSocket clients right after this returns — added
    /// 2026-09-13, since until then only the regular poll tiers and
    /// `refreshAfterEnteringMemory()` ever called `server.broadcast`, so an
    /// iPad/remote client saw an app-triggered change only once the next
    /// poll tick republished it, up to `slowTierInterval` ticks later for a
    /// slow-tier field). Without this function at all, the UI has no way to
    /// reflect a change until that poll pickup — during which a control
    /// bound straight to `rigState` would visibly snap back to the
    /// pre-change value before "catching up". This only predicts the
    /// outcome of a command that's already succeeded on the rig — a genuine
    /// mismatch (e.g. the rig clamping an out-of-range value) self-corrects
    /// at the next poll tick, same as any other externally-driven change
    /// (e.g. the front panel).
    private func applyOptimistically(_ command: RigCommand) {
        commandGeneration += 1
        switch command {
        case .setFrequency(let hz): rigState.frequencyHz = hz
        case .setSecondaryFrequency(let hz): rigState.secondaryFrequencyHz = hz
        case .swapActiveVFO:
            let freq = rigState.frequencyHz
            rigState.frequencyHz = rigState.secondaryFrequencyHz ?? freq
            rigState.secondaryFrequencyHz = freq
            if let newMode = rigState.secondaryMode {
                rigState.secondaryMode = rigState.mode
                rigState.mode = newMode
            }
        case .setMode(let mode): rigState.mode = mode
        case .setPTT(let on): rigState.ptt = on
        case .setBand: break // resolved into .setFrequency before reaching CommandQueue — see send(_:)
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
        case .setFilterWidth(let index): rigState.filterWidthIndex = index
        case .setIFShift(let hz): rigState.ifShiftHz = IFShift.snapped(hz)
        case .setNotch(let on): rigState.notchEnabled = on
        case .setNotchFrequency(let hz): rigState.notchHz = IFNotch.snappedHz(hz)
        case .setContour(let on): rigState.contourEnabled = on
        case .setContourFrequency(let hz): rigState.contourHz = IFContour.snappedContourHz(hz)
        case .setAPF(let on): rigState.apfEnabled = on
        case .setAPFOffset(let hz): rigState.apfHz = IFContour.snappedAPFHz(hz)
        case .setNarrow(let on): rigState.narrowEnabled = on
        case .setAntSelect(let mode): rigState.antSelect = mode
        case .setTXW(let on): rigState.txwEnabled = on
        case .setSquelchType(let mode): rigState.squelchType = mode
        case .setToneFreq(let index): rigState.ctcssToneIndex = index
        case .setDCSCode(let index): rigState.dcsCodeIndex = index
        case .setRepeaterShift(let mode): rigState.repeaterShiftMode = mode
        case .setAPRSBeaconType(let mode): rigState.aprsBeaconType = mode
        case .setFMChannelStep(let step): rigState.fmChannelStep = step
        case .setVFOMemoryMode(let memory):
            rigState.vfoMemoryMode = memory ? .memory : .vfo
            if memory { Task { await refreshAfterEnteringMemory() } }
        case .setMemoryChannel(let channel):
            rigState.memoryChannel = channel
            // Cleared rather than left stale — the new channel's tag isn't
            // known until the next poll's getMemoryChannelTag(channel:)
            // read, and showing the *previous* channel's tag against the
            // new number would be actively misleading.
            rigState.memoryChannelTag = nil
        case .stepMemoryChannel(let up):
            // Optimistic ±1, clamped defensively since the real rig's wrap
            // behavior at the ends of the populated range isn't hardware-
            // confirmed yet (see RigCommand.stepMemoryChannel) — a genuine
            // mismatch self-corrects at the next poll, same as any other
            // optimistic value here.
            if rigState.vfoMemoryMode == .memory, let current = rigState.memoryChannel {
                rigState.memoryChannel = max(1, min(99, current + (up ? 1 : -1)))
                rigState.memoryChannelTag = nil
            }
        // Momentary triggers, and CW MESSAGE record/select/play (whose
        // `cwMessageStatus` doesn't map 1:1 from any single command — see
        // RigState.cwMessageStatus) have no direct optimistic value; left
        // to the next poll, same as before.
        case .triggerZeroIn, .triggerAntennaTune, .selectCWMessageChannel,
             .setCWMessageRecording, .playCWMessage, .setMenuItem:
            break
        }
    }

    /// Fast path for the one transition the hub can't predict optimistically:
    /// entering Memory mode recalls a channel whose contents the app doesn't
    /// know until it reads them. Leaving that to the regular poll took ~10s
    /// on real hardware (2026-09-08): the cycle in flight when the command
    /// lands is discarded whole (`commandGeneration` guard), the next one
    /// only publishes at the end of its ~30 reads, and in C4FM every cycle
    /// also eats `GT0`/`PR1`'s 1s timeouts. Leaving Memory mode has no such
    /// lag because `send(_:)` replays `lastVFOState` optimistically.
    ///
    /// Reads just the fields the recall changes, retrying briefly until the
    /// rig has actually switched (frequency differs from the parked VFO's —
    /// the recall isn't instant), then publishes them directly. Bumps
    /// `commandGeneration` so a poll cycle that captured its frequency
    /// before the recall can't overwrite these with stale values at its end.
    private func refreshAfterEnteringMemory() async {
        let parkedHz = lastVFOState?.hz
        let maxAttempts = 10
        for attempt in 0..<maxAttempts {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            guard rigState.vfoMemoryMode == .memory else { return }
            guard let hz = try? await rigctld.getFrequency() else { continue }
            // A channel programmed to the parked frequency is legitimate —
            // accept it on the last attempt rather than spinning forever.
            if hz == parkedHz && attempt < maxAttempts - 1 { continue }
            let modeName = try? await rigctld.getMode().mode
            let isC4FM = modeName == nil ? (try? await rigctld.isActiveModeC4FM()) ?? false : false
            let channel = try? await rigctld.getRawInt("MC0")
            var tag: String?
            if let channel { tag = try? await rigctld.getMemoryChannelTag(channel: channel) }
            guard rigState.vfoMemoryMode == .memory else { return }
            commandGeneration += 1
            rigState.frequencyHz = hz
            rigState.mode = modeName.flatMap(RigMode.init(rawValue:)) ?? (isC4FM ? .c4fm : rigState.mode)
            rigState.memoryChannel = channel
            rigState.memoryChannelTag = tag
            await server.broadcast(rigState)
            return
        }
    }

    /// Fast path after a NARROW write: the rig re-filters to the mode's
    /// preset narrow width (or back), changing "SH0"'s answer, and the
    /// Width readout would otherwise sit on the old value until the slow
    /// tier's next pass (~10s). Same shape as `refreshAfterEnteringMemory`:
    /// give the rig a moment, read just the field that changed, bump
    /// `commandGeneration` so a poll cycle that captured the pre-NAR width
    /// is discarded rather than overwriting this at its end, publish.
    private func refreshWidthAfterNarrow() async {
        for attempt in 0..<2 {
            try? await Task.sleep(for: .milliseconds(300))
            guard let width = try? await rigctld.getRawInt("SH0") else {
                if attempt == 0 { continue } else { return }
            }
            // In SSB/CW/RTTY/DATA "SH0" doesn't move with NARROW — the
            // narrowed bandwidth is the mode's NAR WIDTH preset — so refresh
            // that too, for the Filter Function Display (see
            // NarrowWidthPreset / RigState.narrowWidthHz).
            var presetHz: Int?
            if let item = NarrowWidthPreset.item(for: rigState.mode),
               let raw = try? await rigctld.getMenuItem(p1: item.p1, p2: item.p2, p3: item.p3) {
                presetHz = NarrowWidthPreset.hz(forRawValue: raw, mode: rigState.mode)
            }
            commandGeneration += 1
            rigState.filterWidthIndex = width
            if let presetHz { rigState.narrowWidthHz = presetHz }
            await server.broadcast(rigState)
            return
        }
    }

    /// On-demand read for one Deep Settings item (see DeepSettingsCatalog),
    /// called only while a Deep Settings tab is open — bypasses
    /// `CommandQueue` directly, the same way the poll loop's getters do.
    /// These ~300 rarely-changed settings deliberately aren't part of the
    /// 500ms poll/broadcast cycle alongside VFO/SWR/PTT; they're fetched
    /// straight into the settings screen's own state instead of `rigState`.
    func readMenuItem(p1: Int, p2: Int, p3: Int) async -> String? {
        try? await rigctld.getMenuItem(p1: p1, p2: p2, p3: p3)
    }

    private static let zoomRange: ClosedRange<Float> = 0.25...4
    private static let zoomStepFactor: Float = 1.25

    /// Drives the up/down arrows next to the waterfall/oscilloscope
    /// display — `@Published` here so `ContentView` can show the current
    /// level, and mirrored into `audioCapture` (which can't read
    /// `@Published` state directly — see `AudioCaptureEngine`'s
    /// `waterfallZoom` doc comment) so `process()` picks it up on the next
    /// buffer.
    func stepWaterfallZoom(up: Bool) {
        waterfallZoom = Self.steppedZoom(waterfallZoom, up: up)
        audioCapture.setWaterfallZoom(waterfallZoom)
    }

    func stepOscilloscopeZoom(up: Bool) {
        oscilloscopeZoom = Self.steppedZoom(oscilloscopeZoom, up: up)
        audioCapture.setOscilloscopeZoom(oscilloscopeZoom)
    }

    private static func steppedZoom(_ current: Float, up: Bool) -> Float {
        let factor = up ? zoomStepFactor : 1 / zoomStepFactor
        return min(zoomRange.upperBound, max(zoomRange.lowerBound, current * factor))
    }

    /// Called by `ContentView` whenever the Waterfall/Oscilloscope/Off
    /// selection changes: "Off" tells `AudioCaptureEngine` to skip FFT and
    /// frame rendering entirely (see its `displayEnabled`), not merely to
    /// hide the result. Raw audio keeps flowing to APRS/playback/relay.
    func setScopeDisplayMode(_ mode: ScopeDisplayMode) {
        audioCapture.setDisplayEnabled(mode != .off)
    }

    /// Doesn't stop/start `audioPlayback` itself — muting just gates
    /// whether `onAudioSamples` feeds it (see above), so un-muting resumes
    /// instantly with whatever's currently playing rather than needing the
    /// engine to spin back up.
    func toggleAudioMuted() {
        isAudioMuted.toggle()
        AudioPlaybackSettings.isMuted = isAudioMuted
    }

    /// macOS App Nap throttles background GCD/dispatch scheduling for a
    /// process with no visible, non-occluded window — which the APRS
    /// pipeline leans on at every stage (`AudioCaptureEngine`'s per-buffer
    /// main-actor hop, `APRSDecoder`'s own serial queue, the final hop
    /// back to `APRSStore`). Under App Nap, none of that stops outright,
    /// but it can be delayed long enough to look like decoding "isn't
    /// running" — and opening a new window (e.g. S.LIST) is exactly the
    /// kind of thing that pulls a process out of App Nap, which would
    /// explain decoding appearing to depend on a window being open.
    /// `ProcessInfo.beginActivity` opts out for as long as the token is
    /// held, matching `audioCapture`'s own start/stop lifecycle — this
    /// isn't APRS-specific (the waterfall/scope hop the same way), but
    /// APRS is the first feature in this app where a multi-second delay
    /// is actually noticeable rather than just a dropped animation frame.
    private func beginBackgroundActivity() {
        guard backgroundActivityToken == nil else { return }
        backgroundActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Live rig audio capture and APRS decoding"
        )
    }

    private func endBackgroundActivity() {
        guard let token = backgroundActivityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        backgroundActivityToken = nil
    }

    private func connectRigctld(isFreshStart: Bool = false) {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { await runConnectionLoop(isFreshStart: isFreshStart) }
    }

    private func disconnectRigctld() {
        runLoopTask?.cancel()
        runLoopTask = nil
        connectionState = .disconnected
        audioCapture.stop()
        audioPlayback.stop()
        endBackgroundActivity()
        scopeFrames.clear()
        wpsdMonitor.stop()
        rigState.c4fmCallsign = nil
        rigState.c4fmReflector = nil
        Task { await rigctld.disconnect() }
    }

    /// `isFreshStart` covers just-spawned rigctld's real startup race
    /// (opening the serial device + binding its TCP listener takes longer
    /// than the instant `Process.run()` returns in) — while it's true and
    /// still within `startupGracePeriod`, a failed attempt retries quickly
    /// via `startupRetryInterval` without ever setting `connectionState` to
    /// `.failed`, so a normal startup never visibly flashes an error. Once
    /// the grace period elapses (or this is a later reconnect, e.g. the rig
    /// was unplugged or rigctld crashed after connecting fine once), a
    /// failure surfaces immediately and retries revert to the slower
    /// `reconnectDelay`, exactly as before this fix.
    private func runConnectionLoop(isFreshStart: Bool) async {
        var isFreshStart = isFreshStart
        let startupDeadline = ContinuousClock.now + startupGracePeriod
        while !Task.isCancelled {
            connectionState = .connecting
            do {
                try await rigctld.connect()
                connectionState = .connected
                audioCapture.start(deviceUID: AudioInputSettings.deviceUID)
                audioPlayback.setOutputDevice(AudioOutputDeviceLister.deviceID(forUID: AudioOutputSettings.deviceUID))
                audioPlayback.start()
                beginBackgroundActivity()
                try await pollLoop()
            } catch {
                // A cancelled attempt (e.g. the user switched rigctld off
                // mid-connect) still throws here even with the cancellation
                // handler in RigctldClient.connect() — don't let its error
                // clobber the .disconnected state disconnectRigctld() already set.
                if !Task.isCancelled {
                    if isFreshStart && ContinuousClock.now < startupDeadline {
                        // Still within the post-spawn grace window — treat
                        // this as rigctld not being ready yet, not a real
                        // failure worth surfacing.
                    } else {
                        isFreshStart = false
                        audioCapture.stop()
                        audioPlayback.stop()
                        endBackgroundActivity()
                        scopeFrames.clear()
                        Self.connectionLogger.error("rigctld connection loop failed: \(String(describing: error), privacy: .public)")
                        connectionState = .failed(error.localizedDescription)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: isFreshStart ? startupRetryInterval : reconnectDelay)
        }
    }

    private func pollLoop() async throws {
        // Prime the slow tier so it runs right after the first fast tick of
        // every (re)connection instead of waiting out a full interval.
        // Measured on real hardware 2026-09-13 (rawcat log): fast ticks land
        // ~1.5s apart (roughly a dozen reads plus `pollInterval`), so the
        // first slow tier otherwise started ~8s after connect and finished
        // ~10s in — every menu/settings field (filter width, NB, DNR, AGC,
        // VOX...) sat at "—" for those 10s, which read as the app not
        // reading them at all. Priming costs one ~2s slow tier up front
        // and brings that to ~3s. Also right on a reconnect: anything
        // could have changed while the link was down.
        slowTierTickCounter = Self.slowTierInterval
        while !Task.isCancelled {
            try await refreshFastTier()
            slowTierTickCounter += 1
            if slowTierTickCounter >= Self.slowTierInterval {
                slowTierTickCounter = 0
                try await refreshSlowTier()
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Fast, VFO-critical half of the poll cycle — runs every `pollInterval`
    /// tick. Split from the old single ~30-read `refreshState()`
    /// (2026-09-13, see project memory project-ftx1remote-responsiveness-
    /// ideas) because that cycle published only at its very end: a frequency
    /// change made on the rig's own front panel was captured in this
    /// function's very first read, but sat unpublished behind ~two dozen
    /// menu/settings reads (now `refreshSlowTier()`) that only change on a
    /// button press — routinely adding a second or more of visible lag, far
    /// worse in C4FM where two of those reads (`"GT0"`/`"PR1"`) time out and
    /// force a reconnect every cycle. This tier covers just what changes
    /// moment to moment (frequency, mode, PTT, meters, secondary VFO, and
    /// VFO/Memory mode itself — the last one kept here rather than in the
    /// slow tier specifically so `lastVFOState` tracking below never races a
    /// stale `vfoMemoryMode`), at roughly a dozen round trips instead of
    /// ~30, and broadcasts on its own rather than waiting for the slow tier.
    private func refreshFastTier() async throws {
        // This tier's reads are captured one at a time across its sequential
        // round trips (below), so a command can land via `applyOptimistically`
        // partway through — see the `commandGeneration` guard right before this
        // tier's values are published, below.
        let generationAtStart = commandGeneration
        // Best-effort for an ordinary bad/empty CAT reply (`.badResponse`)
        // — that shouldn't tear down and reconnect the whole session, just
        // fall back to the last known frequency and let the next poll cycle
        // (500ms later) try again. This used to be a hard `try`, which over
        // a real network hop meant an occasional `.badResponse` was
        // repeatedly tearing down and reconnecting the entire session (the
        // connect/disconnect cycling seen during initial Pi validation).
        //
        // `.connectionLost` is deliberately NOT swallowed the same way: it
        // means `RigctldClient` itself already determined the transport is
        // dead (e.g. the Pi TCP-reset the connection), not that the rig
        // gave one bad reply. Catching it here too silently — as every
        // field in this function used to, until that fix — meant a real
        // disconnect was never detected: every read below would also fail
        // the same way, this tier would never throw, and
        // `runConnectionLoop()` never got the chance to reconnect. The
        // symptom was hundreds of failed writes a second forever with no
        // reconnect, confirmed via a real Pi network drop. Rethrowing here
        // propagates through `pollLoop()` into `runConnectionLoop()`'s
        // catch block, which does the normal disconnect/backoff/reconnect
        // dance.
        let frequencyHz: Int
        do {
            frequencyHz = try await rigctld.getFrequency()
        } catch let error as RigctldError where error == .connectionLost || error == .notConnected {
            // `.notConnected` reaches here on the poll tick *after* the one
            // that actually detected the drop and tore the connection down
            // (see RigctldClient.write()/readLine()) — that tick's own
            // failure could have been on any field in either tier, not
            // necessarily this one, so this is the first chance this
            // specific read gets to notice. Treating it the same as
            // `.connectionLost` (rather than falling through to the
            // best-effort fallback) is what actually breaks the "never
            // reconnects" loop, not just the initial detection.
            throw error
        } catch {
            frequencyHz = rigState.frequencyHz
        }
        // Best-effort like the secondary-VFO mode read below: this rig's
        // hamlib backend returns a protocol error (RPRT -8) for "get mode"
        // while the active VFO is in C4FM, rather than a parseable string.
        // A hard `try` here would abort this whole tier before it ever
        // reaches PTT or the secondary VFO — and propagate up into a
        // connection-failure/reconnect loop — every time the active VFO
        // sits in C4FM.
        let modeName = try? await rigctld.getMode().mode
        // hamlib's mode read has no mapping for this rig's two raw C4FM
        // codes (see RigctldClient.isActiveModeC4FM) and fails outright
        // rather than returning a string — only worth checking when the
        // normal read above already came back empty, since it costs an
        // extra two round trips.
        let isC4FM = modeName == nil ? (try? await rigctld.isActiveModeC4FM()) ?? false : false
        // Best-effort, same reasoning as the mode read above: a single
        // dropped byte on the USB-serial link (real, occasional occurrence
        // on actual RF hardware, and rigctld is tuned with retry=0 to fail
        // such a hiccup fast rather than retry it — see
        // RigctldProcessController) shouldn't tear down the whole
        // connection and force a reconnect any more than a raw-CAT field
        // hiccuping should. Falls back to the last known state, like the
        // raw-CAT fields in `refreshSlowTier()`.
        let ptt = try? await rigctld.getPTT()
        // Best-effort like the raw CAT reads in `refreshSlowTier()`, but
        // deliberately NOT carried forward from the previous poll on
        // failure: a live meter should fall to rest, not freeze on a stale
        // reading (e.g. during TX, when the rig has no RX strength to
        // report).
        let swr = try? await rigctld.getLevel("SWR")
        let smeterDb = try? await rigctld.getLevel("STRENGTH")
        let powerWatts = try? await rigctld.getLevel("RFPOWER_METER_WATTS")
        let powerLevel = try? await rigctld.getLevel("RFPOWER")
        let secondaryFrequencyHz = try? await rigctld.getSecondaryFrequency()
        let secondaryModeName = try? await rigctld.getSecondaryMode()
        // Same C4FM gap as the primary mode read above — see `isC4FM`.
        let isSecondaryC4FM = secondaryModeName == nil ? (try? await rigctld.isSecondaryModeC4FM()) ?? false : false
        // "VM0" reads VFO-vs-memory mode with its fixed MAIN-side P1 baked
        // in — see RigState.vfoMemoryMode. Only bother reading the memory
        // channel itself while actually in Memory mode, to avoid a wasted
        // extra round trip on every poll tick otherwise.
        let vfoMemoryModeRaw = try? await rigctld.getRawInt("VM0")
        let memoryChannel = (vfoMemoryModeRaw == 11) ? (try? await rigctld.getRawInt("MC0")) : nil
        // "MT" is addressed by the channel number itself, not a fixed
        // prefix, so this can only run once memoryChannel's own read above
        // has resolved — one more round trip, same "only while relevant"
        // reasoning as memoryChannel itself.
        var memoryChannelTag: String?
        if let memoryChannel {
            memoryChannelTag = try? await rigctld.getMemoryChannelTag(channel: memoryChannel)
        }

        // Every field above has an optimistic-set counterpart in
        // applyOptimistically (frequency, mode, PTT, power level). If a
        // command landed while this tier's reads were still in flight,
        // every value captured after that point is racing the optimistic
        // update. Bail out of the whole tier rather than publish a
        // partially-stale snapshot; the next poll tick starts only after
        // the command has already landed, so it reads the true value
        // without racing.
        guard commandGeneration == generationAtStart else { return }

        // Amateur allocation wins on overlap (see `generalCoverageSegment`) —
        // `bandOrSegmentName` is what the Band picker's selection binds to,
        // so it needs to reflect a general-coverage segment too, not just a
        // ham band, or picking e.g. "FM BCB" would leave the picker showing
        // whatever ham band was last selected.
        let band = BandPlan.band(containing: frequencyHz)
        let segment = band == nil ? GeneralCoverageSegments.segment(containing: frequencyHz) : nil
        let bandOrSegmentName = band?.name ?? segment?.name
        if let band {
            BandMemory.recordFrequencyHz(frequencyHz, forBand: band.name)
            // Segments (NOAA WX, SW broadcast, etc.) always force their own
            // `defaultMode` on selection by design (see `.setBand` above),
            // so there's no "last mode" worth remembering there — only ham
            // bands, where the operator's mode choice should persist.
            if let mode = modeName.flatMap(RigMode.init(rawValue:)) {
                BandMemory.recordMode(mode, forBand: band.name)
            }
        } else if let segment {
            BandMemory.recordFrequencyHz(frequencyHz, forBand: segment.name)
        }

        let aprsActive = APRSSettings.isActive(atFrequencyHz: frequencyHz)
        // Read back as `nil` once 5 seconds have passed since the last
        // decode — see `aprsLastCallsignHeard`'s doc comment for why this
        // doesn't need its own expiry `Timer`.
        let aprsLastCallsign: String? = aprsLastCallsignHeard.flatMap { heard in
            Date().timeIntervalSince(heard.at) < 5 ? heard.callsign : nil
        }

        rigState.frequencyHz = frequencyHz
        rigState.mode = modeName.flatMap(RigMode.init(rawValue:)) ?? (isC4FM ? .c4fm : rigState.mode)
        rigState.band = bandOrSegmentName
        rigState.powerWatts = powerWatts
        rigState.swr = swr
        rigState.ptt = ptt ?? rigState.ptt
        rigState.lastUpdated = Date()
        rigState.secondaryFrequencyHz = secondaryFrequencyHz ?? rigState.secondaryFrequencyHz
        rigState.secondaryMode = secondaryModeName.flatMap(RigMode.init(rawValue:)) ?? (isSecondaryC4FM ? .c4fm : rigState.secondaryMode)
        rigState.powerLevel = powerLevel
        rigState.smeterDb = smeterDb
        rigState.aprsActive = aprsActive
        rigState.aprsLastCallsign = aprsLastCallsign
        rigState.vfoMemoryMode = vfoMemoryModeRaw.map(VFOMemoryMode.init(rawP2:)) ?? rigState.vfoMemoryMode
        // No `?? rigState.memoryChannel`/`memoryChannelTag` fallback: these
        // should go back to nil when out of Memory mode, not hold onto a
        // stale channel number from the last time it was active.
        rigState.memoryChannel = memoryChannel
        rigState.memoryChannelTag = memoryChannelTag

        // Only while genuinely in VFO mode — never from a Memory-mode
        // snapshot, whose frequency/mode are the channel's, not the VFO's.
        if rigState.vfoMemoryMode == .vfo {
            lastVFOState = (rigState.frequencyHz, rigState.mode)
        }
        updateWPSDMonitorState()
        await server.broadcast(rigState)
    }

    /// Slow, menu/settings half of the poll cycle — runs only every
    /// `slowTierInterval`th tick (see `pollLoop()`), covering the roughly
    /// two dozen raw-CAT/menu fields that only change on a button press
    /// (front panel or app). See `refreshFastTier`'s doc comment for why
    /// the cycle is split this way.
    private func refreshSlowTier() async throws {
        let generationAtStart = commandGeneration
        // Best-effort: these go through rigctld's raw CAT passthrough (see
        // RigctldClient.sendRawCommand), not hamlib's own func/level
        // abstraction, so a hiccup (e.g. hamlib's internal serial read
        // timing out before the rig replies) shouldn't take down the main
        // poll loop any more than a secondary-VFO read failing should.
        let breakIn = try? await rigctld.getRawBool("BI")
        let keyerEnabled = try? await rigctld.getRawBool("KR")
        let cwSpeedWpm = try? await rigctld.getRawInt("KS")
        // "KP" reports pitch as 00-75 steps above a 300Hz floor, not Hz
        // directly — see RigState.cwPitchHz.
        let cwPitchStep = try? await rigctld.getRawInt("KP")
        // "SD" reports delay as a non-linear 00-33 code, not milliseconds
        // directly — see RigDelayCode.
        let bkDelayCode = try? await rigctld.getRawInt("SD")
        let cwSpot = try? await rigctld.getRawBool("CS")
        // "ML1" reads MONI level specifically — "ML0" would read MONI
        // on/off instead, since both share the "ML" mnemonic under a P1
        // sub-selector. See RigState.moniLevel.
        let moniLevel = try? await rigctld.getRawInt("ML1")
        let cwMessageStatusRaw = try? await rigctld.getCWMessageStatus()
        let moxEnabled = try? await rigctld.getRawBool("MX")
        let attEnabled = try? await rigctld.getRawBool("RA0")
        let preampMode = try? await rigctld.getRawInt("PA0")
        let tunerEnabled = try? await rigctld.getTunerEnabled()
        let displaySettings = try? await rigctld.getDisplaySettings()
        let displayLevel = try? await rigctld.getSpectrumScopeLevel()
        // "SS01"/"SS02" address PEAK/MARKER's fixed P1/P2 prefix — see
        // RigctldClient.getRawDigit() for why a plain getRawInt/getRawBool
        // wouldn't parse these correctly.
        let displayPeak = try? await rigctld.getRawDigit("SS01")
        let displayMarker = try? await rigctld.getRawBool("SS02")
        let micGain = try? await rigctld.getRawInt("MG")
        let amcLevel = try? await rigctld.getRawInt("AO")
        let voxEnabled = try? await rigctld.getRawBool("VX")
        let voxGain = try? await rigctld.getRawInt("VG")
        // "VD" reports delay as the same non-linear 00-33 code as "SD" — see
        // RigDelayCode.
        let voxDelayCode = try? await rigctld.getRawInt("VD")
        // "BC0" reads AUTO NOTCH (DNF) with its fixed MAIN-side P1 baked in,
        // same shape as "RA0"/"MX" above.
        let dnfEnabled = try? await rigctld.getRawBool("BC0")
        // "GT0" reads AGC with its fixed MAIN-side P1 baked in — unlike the
        // Set side (0-4 only), the Answer's value digit can come back 0-6;
        // see RigState.agcMode for why that's still fine to store as-is.
        // "GT0"/"PR1" get no reply at all while the active VFO is in C4FM
        // (AGC/mic EQ don't apply to digital voice), confirmed on real
        // hardware — each attempt costs `sendRawCommand`'s full 1s timeout
        // plus a reconnect (see its catch path), so skip both outright
        // instead of paying that tax every slow-tier cycle. `rigState.mode`
        // is fresh as of the fast tier that always runs immediately before
        // this one.
        let agcMode: Int?
        let micEQEnabled: Bool?
        if rigState.mode == .c4fm {
            agcMode = nil
            micEQEnabled = nil
        } else {
            // "GT0" reads AGC with its fixed MAIN-side P1 baked in — unlike
            // the Set side (0-4 only), the Answer's value digit can come
            // back 0-6; see RigState.agcMode for why that's still fine to
            // store as-is.
            agcMode = try? await rigctld.getRawInt("GT0")
            // "PR1" reads MIC EQ with its fixed P1=1 (Parametric Microphone
            // Equalizer) baked in — plain getRawBool now that its P2 is
            // confirmed to be an ordinary 0/1, not the manual's claimed 1/2
            // (see CommandQueue's .setMicEQ case for how that was confirmed).
            micEQEnabled = try? await rigctld.getRawBool("PR1")
        }
        let procLevel = try? await rigctld.getRawInt("PL")
        // "NL0"/"RL0" read NOISE BLANKER LEVEL/NOISE REDUCTION LEVEL (DNR)
        // with their fixed MAIN-side P1 baked in, same shape as "PA0"/"GT0"
        // above.
        let nbLevel = try? await rigctld.getRawInt("NL0")
        let dnrLevel = try? await rigctld.getRawInt("RL0")
        // "SH0" reads WIDTH with its fixed MAIN-side P1 baked in, same shape
        // as "NL0"/"RL0" above. The reply's P2 (always "0") lands as this
        // value's leading digit, but since the real P3 value is always
        // 0-23, `Int(...)` parsing that combined 3-digit string discards
        // the leading zero for free — see RigState.filterWidthIndex.
        let filterWidthIndex = try? await rigctld.getRawInt("SH0")
        // "IS" answers with a signed value ("IS00-0240;"), which getRawInt
        // can't parse — dedicated helper, see RigctldClient.getIFShiftHz().
        let ifShiftHz = try? await rigctld.getIFShiftHz()
        // "BP00"/"BP01" read the manual notch's on/off and frequency
        // sub-functions. Both answer with a 3-digit field ("BP00001;",
        // "BP01124;"), so on/off goes through getRawInt (!= 0) rather than
        // getRawBool, which would see only the leading "0" of "001" and
        // report the notch off every time — see IFNotch.
        let notchRaw = try? await rigctld.getRawInt("BP00")
        let notchCode = try? await rigctld.getRawInt("BP01")
        // "CO00".."CO03" read CONTOUR on/off + frequency and APF on/off +
        // offset — all 4-digit fields, so the on/off ones go through
        // getRawInt (!= 0) for the same reason as "BP00" above; see
        // IFContour for the APF offset's 0000-0050 code.
        let contourRaw = try? await rigctld.getRawInt("CO00")
        let contourHzRaw = try? await rigctld.getRawInt("CO01")
        let apfRaw = try? await rigctld.getRawInt("CO02")
        let apfCode = try? await rigctld.getRawInt("CO03")
        // "NA0" reads NARROW with its fixed MAIN-side P1 baked in — a plain
        // single-digit boolean like "BC0", so getRawBool is right here.
        let narrowEnabled = try? await rigctld.getRawBool("NA0")
        // The current mode's NAR WIDTH preset (Deep Settings item, generic
        // "EX" passthrough like HF ANT SELECT below) — what the rig really
        // filters at while NARROW is on in SSB/CW/RTTY/DATA, since "SH0"
        // keeps reporting the wide setting there. See NarrowWidthPreset.
        var narrowWidthHz: Int?
        if let presetItem = NarrowWidthPreset.item(for: rigState.mode),
           let raw = try? await rigctld.getMenuItem(p1: presetItem.p1, p2: presetItem.p2, p3: presetItem.p3) {
            narrowWidthHz = NarrowWidthPreset.hz(forRawValue: raw, mode: rigState.mode)
        }
        // No dedicated mnemonic for HF ANT SELECT — reads through the same
        // generic "EX" passthrough Deep Settings uses, just at this one
        // fixed address (see RigState.antSelect/RigCommand.setAntSelect).
        let antSelectRaw = try? await rigctld.getMenuItem(p1: 3, p2: 7, p3: 4)
        let antSelect = antSelectRaw.flatMap(Int.init)
        let txwEnabled = try? await rigctld.getRawBool("TS")
        // "ST" reads SPLIT with no P1 selector at all, same bare-boolean
        // shape as "TS" above — see RigState.splitEnabled.
        let splitEnabled = try? await rigctld.getRawBool("ST")
        // "CT0" reads SQL TYPE with its fixed MAIN-side P1 baked in, same
        // shape as "GT0"/"BC0" above.
        let squelchType = try? await rigctld.getRawDigit("CT0")
        // "CN00"/"CN01" read the current CTCSS tone index / DCS code index
        // with their fixed MAIN-side P1 and CTCSS-vs-DCS P2 baked in — these
        // are indices into RigCTCSSTone/RigDCSCode's fixed tables, not Hz/
        // codes directly, same non-linear-code reasoning as "SD"/"VD" above.
        let ctcssToneIndex = try? await rigctld.getRawInt("CN00")
        let dcsCodeIndex = try? await rigctld.getRawInt("CN01")
        // "OS0" reads OFFSET/REPEATER SHIFT with its fixed MAIN-side P1
        // baked in, same shape as "CT0" above. The manual notes "OS" only
        // activates in an FM mode — best-effort like every other raw field.
        let repeaterShiftMode = try? await rigctld.getRawDigit("OS0")
        // No dedicated mnemonic for BEACON TYPE — reads through the same
        // generic "EX" passthrough Deep Settings uses, just at this one
        // fixed address (see RigState.aprsBeaconType/RigCommand.
        // setAPRSBeaconType).
        let aprsBeaconTypeRaw = try? await rigctld.getMenuItem(p1: 7, p2: 1, p3: 1)
        let aprsBeaconType = aprsBeaconTypeRaw.flatMap(Int.init)
        // No dedicated mnemonic for FM CH STEP either — same generic "EX"
        // passthrough reasoning as aprsBeaconType above.
        let fmChannelStepRaw = try? await rigctld.getMenuItem(p1: 3, p2: 6, p3: 6)
        let fmChannelStep = fmChannelStepRaw.flatMap(Int.init)

        // Every field above has an optimistic-set counterpart in
        // applyOptimistically (all the menu toggles/levels). If a command
        // landed while this tier's sequential reads were still in flight,
        // every value captured after that point is racing the optimistic
        // update, and the raw-CAT fields' `?? rigState.field` fallback below
        // only guards a *failed* read — not a *stale-but-successful* one —
        // so it wouldn't catch this. Bail out of the whole tier rather than
        // publish a partially-stale snapshot; the next slow-tier tick starts
        // only after the command has already landed, so it reads the true
        // value without racing.
        guard commandGeneration == generationAtStart else { return }

        rigState.breakIn = breakIn ?? rigState.breakIn
        rigState.keyerEnabled = keyerEnabled ?? rigState.keyerEnabled
        rigState.cwSpeedWpm = cwSpeedWpm ?? rigState.cwSpeedWpm
        rigState.cwPitchHz = cwPitchStep.map { 300 + $0 * 10 } ?? rigState.cwPitchHz
        rigState.bkDelayMs = (bkDelayCode.flatMap(RigDelayCode.milliseconds(forCode:))) ?? rigState.bkDelayMs
        rigState.cwSpot = cwSpot ?? rigState.cwSpot
        rigState.moniLevel = moniLevel ?? rigState.moniLevel
        rigState.cwMessageStatus = cwMessageStatusRaw.flatMap(CWMessageStatus.init(rawValue:)) ?? rigState.cwMessageStatus
        rigState.moxEnabled = moxEnabled ?? rigState.moxEnabled
        rigState.attEnabled = attEnabled ?? rigState.attEnabled
        rigState.preampMode = preampMode ?? rigState.preampMode
        rigState.tunerEnabled = tunerEnabled ?? rigState.tunerEnabled
        rigState.displayContrast = (displaySettings.map { $0.contrast }) ?? rigState.displayContrast
        rigState.displayDimmer = (displaySettings.map { $0.brightness }) ?? rigState.displayDimmer
        rigState.displayLevel = displayLevel ?? rigState.displayLevel
        rigState.displayPeak = displayPeak ?? rigState.displayPeak
        rigState.displayMarker = displayMarker ?? rigState.displayMarker
        rigState.micGain = micGain ?? rigState.micGain
        rigState.amcLevel = amcLevel ?? rigState.amcLevel
        rigState.voxEnabled = voxEnabled ?? rigState.voxEnabled
        rigState.voxGain = voxGain ?? rigState.voxGain
        rigState.voxDelayMs = (voxDelayCode.flatMap(RigDelayCode.milliseconds(forCode:))) ?? rigState.voxDelayMs
        rigState.dnfEnabled = dnfEnabled ?? rigState.dnfEnabled
        // `agcMode`/`micEQEnabled` are nil (not a failed read) whenever this
        // tier skipped them for being in C4FM — falls back to the last known
        // value either way, same as a genuine read failure would.
        rigState.agcMode = agcMode ?? rigState.agcMode
        rigState.micEQEnabled = micEQEnabled ?? rigState.micEQEnabled
        rigState.procLevel = procLevel ?? rigState.procLevel
        rigState.nbLevel = nbLevel ?? rigState.nbLevel
        rigState.dnrLevel = dnrLevel ?? rigState.dnrLevel
        rigState.filterWidthIndex = filterWidthIndex ?? rigState.filterWidthIndex
        rigState.ifShiftHz = ifShiftHz ?? rigState.ifShiftHz
        rigState.notchEnabled = notchRaw.map { $0 != 0 } ?? rigState.notchEnabled
        rigState.notchHz = notchCode.flatMap(IFNotch.hz(forCode:)) ?? rigState.notchHz
        rigState.contourEnabled = contourRaw.map { $0 != 0 } ?? rigState.contourEnabled
        rigState.contourHz = contourHzRaw.flatMap { IFContour.contourRangeHz.contains($0) ? $0 : nil } ?? rigState.contourHz
        rigState.apfEnabled = apfRaw.map { $0 != 0 } ?? rigState.apfEnabled
        rigState.apfHz = apfCode.flatMap(IFContour.apfHz(forCode:)) ?? rigState.apfHz
        rigState.narrowEnabled = narrowEnabled ?? rigState.narrowEnabled
        // Cleared (not held over) when the mode has no preset, so AM/FM
        // never inherit an SSB value; otherwise the usual failed-read
        // fallback.
        rigState.narrowWidthHz = NarrowWidthPreset.item(for: rigState.mode) == nil ? nil : (narrowWidthHz ?? rigState.narrowWidthHz)
        rigState.antSelect = antSelect ?? rigState.antSelect
        rigState.txwEnabled = txwEnabled ?? rigState.txwEnabled
        rigState.splitEnabled = splitEnabled ?? rigState.splitEnabled
        rigState.squelchType = squelchType ?? rigState.squelchType
        rigState.ctcssToneIndex = ctcssToneIndex ?? rigState.ctcssToneIndex
        rigState.dcsCodeIndex = dcsCodeIndex ?? rigState.dcsCodeIndex
        rigState.repeaterShiftMode = repeaterShiftMode ?? rigState.repeaterShiftMode
        rigState.aprsBeaconType = aprsBeaconType ?? rigState.aprsBeaconType
        rigState.fmChannelStep = fmChannelStep ?? rigState.fmChannelStep

        await server.broadcast(rigState)
    }

    /// Starts/stops `wpsdMonitor` to match current settings + rig mode —
    /// checked every poll tick (~500ms) rather than only on
    /// connect/disconnect, so toggling the C4FM Settings tab or changing
    /// mode takes effect quickly with no reconnect needed. `start(host:)`/
    /// `stop()` are both no-ops when already in the target state.
    private func updateWPSDMonitorState() {
        guard WPSDSettings.enabled, !WPSDSettings.host.isEmpty, rigState.mode == .c4fm else {
            wpsdMonitor.stop()
            rigState.c4fmCallsign = nil
            rigState.c4fmReflector = nil
            return
        }
        wpsdMonitor.start(host: WPSDSettings.host)
    }
}

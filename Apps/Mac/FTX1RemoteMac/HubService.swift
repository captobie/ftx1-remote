import Combine
import CoreGraphics
import FTX1Core
import Foundation

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

    @Published private(set) var rigState = RigState()
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var rigctldProcessState: RigctldProcessController.State = .stopped
    @Published private(set) var waterfallImage: CGImage?

    private let rigctld: RigctldClient
    private let commandQueue: CommandQueue
    private let server: RigWebSocketServer
    private let rigctldProcess = RigctldProcessController()
    private let audioCapture = AudioCaptureEngine()
    private let webSocketPort: UInt16
    private let rigctldHost: String
    private let rigctldPort: UInt16
    private var runLoopTask: Task<Void, Never>?

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
        audioCapture.onNewFrame = { [weak self] image in
            self?.waterfallImage = image
        }
    }

    /// App-launch lifecycle: starts the WebSocket server. Independent of
    /// the rigctld link — mobile/local clients can connect immediately and
    /// see "rig offline" rather than being unable to reach the Mac at all.
    func start() {
        Task { [weak self, commandQueue] in
            await commandQueue.setOnCommandApplied { command in
                Task { @MainActor in self?.applyOptimistically(command) }
            }
        }

        let port = webSocketPort
        Task { [weak self, server] in
            try? await server.start(port: port) { command in
                Task { @MainActor in self?.send(command) }
            }
        }
    }

    /// App-termination lifecycle: stops the WebSocket server and ensures
    /// rigctld isn't left running as an orphaned child process.
    func stop() {
        stopRigctld()
        Task { [server] in await server.stop() }
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
        disconnectRigctld()
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
        if case .setBand(let name) = command {
            guard let band = BandPlan.band(named: name) else { return }
            let targetHz = BandMemory.lastFrequencyHz(forBand: band.name) ?? band.defaultFrequencyHz
            Task { await commandQueue.enqueue(.setFrequency(hz: targetHz)) }
            return
        }
        Task { await commandQueue.enqueue(command) }
    }

    /// Mirrors a just-applied `RigCommand` straight into `rigState`, called
    /// once `CommandQueue` confirms the write reached rigctld (see
    /// `start()`'s `onCommandApplied` wiring). Without this, the UI has no
    /// way to reflect a change until the next full `refreshState()` poll
    /// picks it up — and since that poll is ~20 sequential rigctld round
    /// trips, that's routinely a second or two, during which a control
    /// bound straight to `rigState` (e.g. `MenuPageView`'s RF POWER slider)
    /// visibly snaps back to the pre-change value before "catching up".
    /// This only predicts the outcome of a command that's already
    /// succeeded on the rig — a genuine mismatch (e.g. the rig clamping an
    /// out-of-range value) self-corrects at the next poll tick, same as any
    /// other externally-driven change (e.g. the front panel).
    private func applyOptimistically(_ command: RigCommand) {
        switch command {
        case .setFrequency(let hz): rigState.frequencyHz = hz
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
        // Momentary triggers, and CW MESSAGE record/select/play (whose
        // `cwMessageStatus` doesn't map 1:1 from any single command — see
        // RigState.cwMessageStatus) have no direct optimistic value; left
        // to the next poll, same as before.
        case .triggerZeroIn, .triggerAntennaTune, .selectCWMessageChannel,
             .setCWMessageRecording, .playCWMessage, .setMenuItem:
            break
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

    private func connectRigctld(isFreshStart: Bool = false) {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { await runConnectionLoop(isFreshStart: isFreshStart) }
    }

    private func disconnectRigctld() {
        runLoopTask?.cancel()
        runLoopTask = nil
        connectionState = .disconnected
        audioCapture.stop()
        waterfallImage = nil
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
                        waterfallImage = nil
                        connectionState = .failed(error.localizedDescription)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: isFreshStart ? startupRetryInterval : reconnectDelay)
        }
    }

    private func pollLoop() async throws {
        while !Task.isCancelled {
            try await refreshState()
            try await Task.sleep(for: pollInterval)
        }
    }

    private func refreshState() async throws {
        let frequencyHz = try await rigctld.getFrequency()
        let (modeName, _) = try await rigctld.getMode()
        let ptt = try await rigctld.getPTT()
        let swr = try await rigctld.getLevel("SWR")
        // Best-effort like the raw CAT reads below, but deliberately NOT
        // carried forward from the previous poll on failure: a live meter
        // should fall to rest, not freeze on a stale reading (e.g. during
        // TX, when the rig has no RX strength to report).
        let smeterDb = try? await rigctld.getLevel("STRENGTH")
        let powerWatts = try await rigctld.getLevel("RFPOWER_METER_WATTS")
        let powerLevel = try await rigctld.getLevel("RFPOWER")
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
        let secondaryFrequencyHz = try? await rigctld.getSecondaryFrequency()
        let secondaryModeName = try? await rigctld.getSecondaryMode()

        let band = BandPlan.band(containing: frequencyHz)
        if let band {
            BandMemory.recordFrequencyHz(frequencyHz, forBand: band.name)
        }

        rigState = RigState(
            frequencyHz: frequencyHz,
            mode: RigMode(rawValue: modeName) ?? .unknown,
            band: band?.name,
            powerWatts: powerWatts,
            swr: swr,
            ptt: ptt,
            lastUpdated: Date(),
            secondaryFrequencyHz: secondaryFrequencyHz ?? rigState.secondaryFrequencyHz,
            secondaryMode: secondaryModeName.flatMap(RigMode.init(rawValue:)) ?? rigState.secondaryMode,
            powerLevel: powerLevel,
            breakIn: breakIn ?? rigState.breakIn,
            keyerEnabled: keyerEnabled ?? rigState.keyerEnabled,
            cwSpeedWpm: cwSpeedWpm ?? rigState.cwSpeedWpm,
            cwPitchHz: cwPitchStep.map { 300 + $0 * 10 } ?? rigState.cwPitchHz,
            bkDelayMs: (bkDelayCode.flatMap(RigDelayCode.milliseconds(forCode:))) ?? rigState.bkDelayMs,
            cwSpot: cwSpot ?? rigState.cwSpot,
            moniLevel: moniLevel ?? rigState.moniLevel,
            cwMessageStatus: cwMessageStatusRaw.flatMap(CWMessageStatus.init(rawValue:)) ?? rigState.cwMessageStatus,
            moxEnabled: moxEnabled ?? rigState.moxEnabled,
            attEnabled: attEnabled ?? rigState.attEnabled,
            preampMode: preampMode ?? rigState.preampMode,
            tunerEnabled: tunerEnabled ?? rigState.tunerEnabled,
            displayContrast: (displaySettings.map { $0.contrast }) ?? rigState.displayContrast,
            displayDimmer: (displaySettings.map { $0.brightness }) ?? rigState.displayDimmer,
            displayLevel: displayLevel ?? rigState.displayLevel,
            displayPeak: displayPeak ?? rigState.displayPeak,
            displayMarker: displayMarker ?? rigState.displayMarker,
            micGain: micGain ?? rigState.micGain,
            amcLevel: amcLevel ?? rigState.amcLevel,
            voxEnabled: voxEnabled ?? rigState.voxEnabled,
            voxGain: voxGain ?? rigState.voxGain,
            voxDelayMs: (voxDelayCode.flatMap(RigDelayCode.milliseconds(forCode:))) ?? rigState.voxDelayMs,
            smeterDb: smeterDb ?? nil
        )
        await server.broadcast(rigState)
    }
}

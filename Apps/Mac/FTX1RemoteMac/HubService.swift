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

    @Published private(set) var rigState = RigState()
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var rigctldProcessState: RigctldProcessController.State = .stopped
    @Published private(set) var waterfallImage: CGImage?
    @Published private(set) var oscilloscopeImage: CGImage?
    @Published private(set) var waterfallZoom: Float = 1
    @Published private(set) var oscilloscopeZoom: Float = 1

    private let rigctld: RigctldClient
    private let commandQueue: CommandQueue
    private let server: RigWebSocketServer
    private let rigctldProcess = RigctldProcessController()
    private let audioCapture = AudioCaptureEngine()
    private let wpsdMonitor = WPSDCallsignMonitor()
    private let aprsDecoder = APRSDecoder()
    let aprsStore = APRSStore()
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

    /// Bumped by `applyOptimistically` every time a command lands. `refreshState`
    /// checks this before and after its ~30 sequential reads to detect whether a
    /// command was optimistically applied mid-cycle — see its use below for why
    /// that matters.
    private var commandGeneration = 0

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
        audioCapture.onNewFrame = { [weak self] frame in
            self?.waterfallImage = frame.waterfall
            self?.oscilloscopeImage = frame.oscilloscope
        }
        audioCapture.onAudioSamples = { [weak self] samples, sampleRate in
            guard let self else { return }
            let isActive = APRSSettings.isActive(atFrequencyHz: self.rigState.frequencyHz)
            if isActive != self.aprsGateWasActive {
                self.aprsGateWasActive = isActive
                Self.aprsGateLogger.debug("APRS gate \(isActive ? "opened" : "closed", privacy: .public) at \(self.rigState.frequencyHz) Hz")
            }
            guard isActive else { return }
            self.aprsDecoder.process(samples: samples, sampleRate: sampleRate)
        }
        aprsDecoder.onStation = { [weak self] callsign, latitude, longitude, symbolTable, symbolCode, comment in
            self?.aprsStore.recordStation(callsign: callsign, latitude: latitude, longitude: longitude, symbolTable: symbolTable, symbolCode: symbolCode, comment: comment, heardAt: Date())
        }
        aprsDecoder.onMessage = { [weak self] from, to, text, messageID in
            self?.aprsStore.recordMessage(from: from, to: to, text: text, messageID: messageID, receivedAt: Date())
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
                Task { @MainActor in self?.applyOptimistically(command) }
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
        webSocketServerTask?.cancel()
        webSocketServerTask = nil
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
        case .setAntSelect(let mode): rigState.antSelect = mode
        case .setTXW(let on): rigState.txwEnabled = on
        case .setSquelchType(let mode): rigState.squelchType = mode
        case .setToneFreq(let index): rigState.ctcssToneIndex = index
        case .setDCSCode(let index): rigState.dcsCodeIndex = index
        case .setRepeaterShift(let mode): rigState.repeaterShiftMode = mode
        case .setAPRSBeaconType(let mode): rigState.aprsBeaconType = mode
        case .setFMChannelStep(let step): rigState.fmChannelStep = step
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
        endBackgroundActivity()
        waterfallImage = nil
        oscilloscopeImage = nil
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
                        endBackgroundActivity()
                        waterfallImage = nil
                        oscilloscopeImage = nil
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
        // This cycle's reads are captured one at a time across ~30 sequential
        // round trips (below), so a command can land via `applyOptimistically`
        // partway through — see the `commandGeneration` guard right before this
        // cycle's values are published, below.
        let generationAtStart = commandGeneration
        let frequencyHz = try await rigctld.getFrequency()
        // Best-effort like the secondary-VFO mode read below: this rig's
        // hamlib backend returns a protocol error (RPRT -8) for "get mode"
        // while the active VFO is in C4FM, rather than a parseable string.
        // A hard `try` here would abort this whole ~30-read cycle before it
        // ever reaches PTT, the secondary VFO, or any raw-CAT field below —
        // and propagate up into a connection-failure/reconnect loop — every
        // time the active VFO sits in C4FM.
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
        // hiccuping should. Falls back to the last known state, like
        // breakIn/keyerEnabled below.
        let ptt = try? await rigctld.getPTT()
        // Best-effort like the raw CAT reads below, but deliberately NOT
        // carried forward from the previous poll on failure: a live meter
        // should fall to rest, not freeze on a stale reading (e.g. during
        // TX, when the rig has no RX strength to report).
        let swr = try? await rigctld.getLevel("SWR")
        let smeterDb = try? await rigctld.getLevel("STRENGTH")
        let powerWatts = try? await rigctld.getLevel("RFPOWER_METER_WATTS")
        let powerLevel = try? await rigctld.getLevel("RFPOWER")
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
        let agcMode = try? await rigctld.getRawInt("GT0")
        // "PR1" reads MIC EQ with its fixed P1=1 (Parametric Microphone
        // Equalizer) baked in — plain getRawBool now that its P2 is
        // confirmed to be an ordinary 0/1, not the manual's claimed 1/2
        // (see CommandQueue's .setMicEQ case for how that was confirmed).
        let micEQEnabled = try? await rigctld.getRawBool("PR1")
        let procLevel = try? await rigctld.getRawInt("PL")
        // "NL0"/"RL0" read NOISE BLANKER LEVEL/NOISE REDUCTION LEVEL (DNR)
        // with their fixed MAIN-side P1 baked in, same shape as "PA0"/"GT0"
        // above.
        let nbLevel = try? await rigctld.getRawInt("NL0")
        let dnrLevel = try? await rigctld.getRawInt("RL0")
        // No dedicated mnemonic for HF ANT SELECT — reads through the same
        // generic "EX" passthrough Deep Settings uses, just at this one
        // fixed address (see RigState.antSelect/RigCommand.setAntSelect).
        let antSelectRaw = try? await rigctld.getMenuItem(p1: 3, p2: 7, p3: 4)
        let antSelect = antSelectRaw.flatMap(Int.init)
        let txwEnabled = try? await rigctld.getRawBool("TS")
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
        let secondaryFrequencyHz = try? await rigctld.getSecondaryFrequency()
        let secondaryModeName = try? await rigctld.getSecondaryMode()
        // Same C4FM gap as the primary mode read above — see `isC4FM`.
        let isSecondaryC4FM = secondaryModeName == nil ? (try? await rigctld.isSecondaryModeC4FM()) ?? false : false

        // Almost every field above has an optimistic-set counterpart in
        // applyOptimistically (frequency, mode, PTT, power level, and all the
        // menu toggles/levels). If a command landed while this cycle's ~30
        // sequential reads were still in flight, every value captured after
        // that point is racing the optimistic update, and even the raw-CAT
        // fields' `?? rigState.field` fallback only guards a *failed* read —
        // not a *stale-but-successful* one — so it wouldn't catch this. Bail
        // out of the whole cycle rather than publish a partially-stale
        // snapshot; the next poll cycle starts only after the command has
        // already landed, so it reads the true value without racing.
        guard commandGeneration == generationAtStart else { return }

        let band = BandPlan.band(containing: frequencyHz)
        if let band {
            BandMemory.recordFrequencyHz(frequencyHz, forBand: band.name)
        }

        rigState = RigState(
            frequencyHz: frequencyHz,
            mode: modeName.flatMap(RigMode.init(rawValue:)) ?? (isC4FM ? .c4fm : rigState.mode),
            band: band?.name,
            powerWatts: powerWatts,
            swr: swr,
            ptt: ptt ?? rigState.ptt,
            lastUpdated: Date(),
            secondaryFrequencyHz: secondaryFrequencyHz ?? rigState.secondaryFrequencyHz,
            secondaryMode: secondaryModeName.flatMap(RigMode.init(rawValue:)) ?? (isSecondaryC4FM ? .c4fm : rigState.secondaryMode),
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
            smeterDb: smeterDb ?? nil,
            dnfEnabled: dnfEnabled ?? rigState.dnfEnabled,
            agcMode: agcMode ?? rigState.agcMode,
            micEQEnabled: micEQEnabled ?? rigState.micEQEnabled,
            procLevel: procLevel ?? rigState.procLevel,
            nbLevel: nbLevel ?? rigState.nbLevel,
            dnrLevel: dnrLevel ?? rigState.dnrLevel,
            antSelect: antSelect ?? rigState.antSelect,
            txwEnabled: txwEnabled ?? rigState.txwEnabled,
            squelchType: squelchType ?? rigState.squelchType,
            ctcssToneIndex: ctcssToneIndex ?? rigState.ctcssToneIndex,
            dcsCodeIndex: dcsCodeIndex ?? rigState.dcsCodeIndex,
            repeaterShiftMode: repeaterShiftMode ?? rigState.repeaterShiftMode,
            aprsBeaconType: aprsBeaconType ?? rigState.aprsBeaconType,
            fmChannelStep: fmChannelStep ?? rigState.fmChannelStep,
            c4fmCallsign: rigState.c4fmCallsign,
            c4fmReflector: rigState.c4fmReflector
        )
        updateWPSDMonitorState()
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

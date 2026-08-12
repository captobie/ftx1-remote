import Combine
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

    private let rigctld: RigctldClient
    private let commandQueue: CommandQueue
    private let server: RigWebSocketServer
    private let rigctldProcess = RigctldProcessController()
    private let webSocketPort: UInt16
    private let rigctldHost: String
    private let rigctldPort: UInt16
    private var runLoopTask: Task<Void, Never>?

    private let pollInterval: Duration
    private let reconnectDelay: Duration

    init(
        rigctldHost: String = "127.0.0.1",
        rigctldPort: UInt16 = 4532,
        webSocketPort: UInt16 = 8765,
        pollInterval: Duration = .milliseconds(500),
        reconnectDelay: Duration = .seconds(3)
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

        rigctldProcess.onStateChange = { [weak self] state in
            self?.rigctldProcessState = state
        }
    }

    /// App-launch lifecycle: starts the WebSocket server. Independent of
    /// the rigctld link — mobile/local clients can connect immediately and
    /// see "rig offline" rather than being unable to reach the Mac at all.
    func start() {
        Task { [weak self, commandQueue] in
            await commandQueue.setOnCommandApplied { _ in
                Task { @MainActor in try? await self?.refreshState() }
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
    /// `RigctldProcessController`), then starts the polling loop. The
    /// loop's existing retry-every-`reconnectDelay` behavior already
    /// tolerates rigctld taking a moment to bind its port after being
    /// spawned, so no extra readiness check is needed here.
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
            self?.connectRigctld()
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

    private func connectRigctld() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { await runConnectionLoop() }
    }

    private func disconnectRigctld() {
        runLoopTask?.cancel()
        runLoopTask = nil
        connectionState = .disconnected
        Task { await rigctld.disconnect() }
    }

    private func runConnectionLoop() async {
        while !Task.isCancelled {
            connectionState = .connecting
            do {
                try await rigctld.connect()
                connectionState = .connected
                try await pollLoop()
            } catch {
                // A cancelled attempt (e.g. the user switched rigctld off
                // mid-connect) still throws here even with the cancellation
                // handler in RigctldClient.connect() — don't let its error
                // clobber the .disconnected state disconnectRigctld() already set.
                if !Task.isCancelled {
                    connectionState = .failed(error.localizedDescription)
                }
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: reconnectDelay)
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
        // directly — see BreakInDelay.
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
            bkDelayMs: (bkDelayCode.flatMap(BreakInDelay.milliseconds(forCode:))) ?? rigState.bkDelayMs,
            cwSpot: cwSpot ?? rigState.cwSpot,
            moniLevel: moniLevel ?? rigState.moniLevel,
            cwMessageStatus: cwMessageStatusRaw.flatMap(CWMessageStatus.init(rawValue:)) ?? rigState.cwMessageStatus,
            moxEnabled: moxEnabled ?? rigState.moxEnabled,
            attEnabled: attEnabled ?? rigState.attEnabled,
            preampMode: preampMode ?? rigState.preampMode
        )
        await server.broadcast(rigState)
    }
}

import Combine
import FTX1Core
import Foundation
import os

/// Tools → Straight Key: the Arduino key interface keying the rig over
/// RTS/DTR on its second USB port — on this Mac in Local mode
/// (`CWKeyingDriver`), on the Pi in Remote mode (`CWRemoteKeyingDriver`
/// forwarding to `Pi/ftx1-cwkey.py`). Picked once at launch from
/// `activeConnectionMode`, like the rest of the hub. Owns the serial
/// source and the driver, feeds the driver the transmit gate from the
/// hub's state, and publishes what the window shows. Its own object,
/// like `cwSender`, so key presses never re-render the main window.
///
/// Runs from launch whether or not the window is open (the indicator
/// works while disarmed, for practice); arming is never remembered.
final class StraightKeyController: ObservableObject {
    @Published private(set) var snapshot = CWKeyingDriver.Snapshot()
    /// Why the last arm was refused before reaching the driver.
    @Published private(set) var armRefusal: String?
    /// What blocks keying on the hub's side (mode, port clash, rig link,
    /// Enable Transmit, band) — nil when keying may go ahead.
    @Published private(set) var blockReason: String?
    /// Shown, not enforced: the transmitting side isn't in CW.
    @Published private(set) var modeWarning: String?

    @Published var interfacePort = StraightKeySettings.interfacePort {
        didSet {
            guard interfacePort != oldValue else { return }
            StraightKeySettings.interfacePort = interfacePort
            restartSource()
        }
    }
    @Published var keyingPort = StraightKeySettings.keyingPort {
        didSet { keyingSettingChanged { StraightKeySettings.keyingPort = keyingPort } }
    }
    @Published var keyingLine = StraightKeySettings.keyingLine {
        didSet { keyingSettingChanged { StraightKeySettings.keyingLine = keyingLine } }
    }
    @Published var invertedPolarity = StraightKeySettings.invertedPolarity {
        didSet { keyingSettingChanged { StraightKeySettings.invertedPolarity = invertedPolarity } }
    }
    /// Local and Remote keep their own delay (Remote needs room for
    /// Tailscale's jitter); this is the active mode's.
    @Published var playoutDelayMs = StraightKeySettings.playoutDelayMs(remote: StraightKeyController.isRemote) {
        didSet {
            StraightKeySettings.setPlayoutDelayMs(playoutDelayMs, remote: Self.isRemote)
            driver.setPlayoutDelay(Double(StraightKeySettings.playoutDelayMs(remote: Self.isRemote)) / 1000)
        }
    }
    /// Remote only: how long the Pi waits without hearing from the hub
    /// before it keys up.
    @Published var remoteHeartbeatTimeoutMs = StraightKeySettings.remoteHeartbeatTimeoutMs {
        didSet {
            StraightKeySettings.remoteHeartbeatTimeoutMs = remoteHeartbeatTimeoutMs
            remoteDriver?.setSettings(Self.remoteSettings())
        }
    }
    @Published var maxKeyDownSeconds = StraightKeySettings.maxKeyDownSeconds {
        didSet {
            StraightKeySettings.maxKeyDownSeconds = maxKeyDownSeconds
            driver.setMaxKeyDown(Double(StraightKeySettings.maxKeyDownSeconds))
        }
    }

    /// Remote mode: the keying line is on the Pi.
    static let isRemote = RigctldSettings.activeConnectionMode == .remote
    /// Where the Pi keyer is, for the window.
    let piKeyerAddress = "\(RigctldSettings.activeRemoteHost):\(CWRemoteKeyingDriver.defaultPort)"

    private let source: SerialCWKeySource
    private let driver: CWKeyingDriving
    private let remoteDriver: CWRemoteKeyingDriver?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "cw-key")

    init(rigState: some Publisher<RigState, Never>, connection: some Publisher<HubService.ConnectionState, Never>) {
        let source = SerialCWKeySource(path: StraightKeySettings.interfacePort, logSubsystem: "com.ftx1remote.mac")
        self.source = source
        let relay = SnapshotRelay()
        let onSnapshot: @Sendable (CWKeyingDriver.Snapshot) -> Void = { snapshot in
            // FIFO onto main, so snapshots can't land out of order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { relay.target?.snapshot = snapshot }
            }
        }
        if Self.isRemote {
            let remote = CWRemoteKeyingDriver(
                source: source, host: RigctldSettings.activeRemoteHost,
                clientID: Host.current().localizedName ?? "Mac",
                settings: Self.remoteSettings(), logSubsystem: "com.ftx1remote.mac",
                onSnapshot: onSnapshot)
            remoteDriver = remote
            driver = remote
        } else {
            remoteDriver = nil
            driver = CWKeyingDriver(
                source: source,
                engine: CWStraightKeyEngine(
                    playoutDelay: Double(StraightKeySettings.playoutDelayMs(remote: false)) / 1000,
                    maxKeyDown: Double(StraightKeySettings.maxKeyDownSeconds)),
                logSubsystem: "com.ftx1remote.mac",
                makeKeyer: {
                    let path = StraightKeySettings.keyingPort
                    guard !path.isEmpty else { return nil }
                    return ModemLineCWKeyer(path: path, line: StraightKeySettings.keyingLine,
                                            invertedPolarity: StraightKeySettings.invertedPolarity)
                },
                onSnapshot: onSnapshot)
        }
        relay.target = self

        rigState.combineLatest(connection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, connection in self?.rigChanged(state, connection: connection) }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        driver.start()
    }

    /// App quit: unkeys and closes both ports before returning.
    func shutdown() {
        driver.shutdown()
    }

    /// The Armed toggle.
    func setArmed(_ armed: Bool) {
        armRefusal = nil
        if armed, let refusal = armRefusalReason() {
            armRefusal = refusal
            return
        }
        Self.logger.notice("\(armed ? "arm" : "disarm", privacy: .public) requested")
        driver.setArmed(armed)
    }

    func availablePorts() -> [String] {
        POSIXSerialPort.availablePorts()
    }

    // MARK: - Private

    /// What the Pi needs for a session (sent in `cw_hello`).
    nonisolated private static func remoteSettings() -> CWRemoteKeyingDriver.Settings {
        CWRemoteKeyingDriver.Settings(
            line: StraightKeySettings.keyingLine,
            invertedPolarity: StraightKeySettings.invertedPolarity,
            playoutDelay: Double(StraightKeySettings.playoutDelayMs(remote: true)) / 1000,
            heartbeatTimeout: Double(StraightKeySettings.remoteHeartbeatTimeoutMs) / 1000,
            maxKeyDown: Double(StraightKeySettings.maxKeyDownSeconds))
    }

    private func armRefusalReason() -> String? {
        if interfacePort.isEmpty { return "Pick the key interface's port first" }
        if Self.isRemote { return nil }   // the keying port is the Pi's
        if keyingPort.isEmpty { return "Pick the rig's keying port first" }
        if StraightKeySettings.sameDevice(keyingPort, RigctldSettings.devicePath)
            || StraightKeySettings.sameDevice(keyingPort, RigctldSettings.pttPort) {
            return "\(keyingPort) is rigctld's port — pick the rig's other USB port"
        }
        if StraightKeySettings.sameDevice(keyingPort, interfacePort) {
            return "The keying port can't be the key interface's port"
        }
        return nil
    }

    private func keyingSettingChanged(_ persist: () -> Void) {
        persist()
        remoteDriver?.setSettings(Self.remoteSettings())
        // A different port/line/polarity applies at the next arm; never
        // swap the keyer under a live line.
        if snapshot.armed {
            driver.setArmed(false)
            armRefusal = "Disarmed: keying settings changed"
        }
    }

    private func restartSource() {
        source.setPath(interfacePort)   // reopens by itself once started
    }

    private func rigChanged(_ state: RigState, connection: HubService.ConnectionState) {
        let reason: String?
        if connection != .connected {
            reason = "Rig not connected"
        } else {
            reason = TransmitGate.blockReason(transmitEnabled: state.transmitEnabled, state: state)
        }
        if reason != blockReason {
            blockReason = reason
            driver.setBlockReason(reason)
        }

        let transmitsOnSub = state.splitEnabled == true || state.txSide == .sub
        let mode = transmitsOnSub ? state.secondaryMode : state.mode
        let warning = (connection == .connected && mode != nil && mode != .cw)
            ? "\(transmitsOnSub ? "SUB" : "MAIN") (transmitting) is in \(mode!.displayName), not CW — PC KEYING keys CW only"
            : nil
        if warning != modeWarning { modeWarning = warning }
    }
}

/// Hands driver snapshots (from its queue) to the controller on main.
private nonisolated final class SnapshotRelay: @unchecked Sendable {
    @MainActor weak var target: StraightKeyController?
}

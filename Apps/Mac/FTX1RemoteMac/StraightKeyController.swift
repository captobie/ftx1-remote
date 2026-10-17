import Combine
import FTX1Core
import Foundation
import os

/// Tools → Straight Key: the Arduino key interface keying the rig over
/// RTS/DTR on its second USB port. Owns the serial source and the keying
/// driver (`FTX1Core/CWKey/`), feeds the driver the transmit gate from
/// the hub's state, and publishes what the window shows. Its own object,
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
    @Published var playoutDelayMs = StraightKeySettings.playoutDelayMs {
        didSet {
            StraightKeySettings.playoutDelayMs = playoutDelayMs
            driver.setPlayoutDelay(Double(StraightKeySettings.playoutDelayMs) / 1000)
        }
    }
    @Published var maxKeyDownSeconds = StraightKeySettings.maxKeyDownSeconds {
        didSet {
            StraightKeySettings.maxKeyDownSeconds = maxKeyDownSeconds
            driver.setMaxKeyDown(Double(StraightKeySettings.maxKeyDownSeconds))
        }
    }

    private let source: SerialCWKeySource
    private let driver: CWKeyingDriver
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "cw-key")

    init(rigState: some Publisher<RigState, Never>, connection: some Publisher<HubService.ConnectionState, Never>) {
        let source = SerialCWKeySource(path: StraightKeySettings.interfacePort, logSubsystem: "com.ftx1remote.mac")
        self.source = source
        let relay = SnapshotRelay()
        driver = CWKeyingDriver(
            source: source,
            engine: CWStraightKeyEngine(
                playoutDelay: Double(StraightKeySettings.playoutDelayMs) / 1000,
                maxKeyDown: Double(StraightKeySettings.maxKeyDownSeconds)),
            logSubsystem: "com.ftx1remote.mac",
            makeKeyer: {
                let path = StraightKeySettings.keyingPort
                guard !path.isEmpty else { return nil }
                return ModemLineCWKeyer(path: path, line: StraightKeySettings.keyingLine,
                                        invertedPolarity: StraightKeySettings.invertedPolarity)
            },
            onSnapshot: { snapshot in
                // FIFO onto main, so snapshots can't land out of order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { relay.target?.snapshot = snapshot }
                }
            })
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

    private func armRefusalReason() -> String? {
        if keyingPort.isEmpty { return "Pick the rig's keying port first" }
        if RigctldSettings.activeConnectionMode != .local {
            return "The straight key works in Local mode only — the rig's USB is on the Pi"
        }
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
        if RigctldSettings.activeConnectionMode != .local {
            reason = "Local mode only — the rig's USB is on the Pi"
        } else if connection != .connected {
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

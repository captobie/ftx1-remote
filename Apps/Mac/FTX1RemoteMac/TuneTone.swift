import Combine
import FTX1Core
import FTX1Digi
import Foundation
import os

/// The main window's TUNE button: switches the rig to CW, keys a plain
/// carrier so an external auto-tuner such as the ATU-100 Plus sees RF and
/// tunes, and on the next press (or after `timeout`) unkeys and puts the
/// previous mode back. Keys through `HubService.send(.setPTT)`, so the
/// transmit gate and memory-scan stop apply. No audio is sent; the power is
/// the rig's RF POWER, so set it low for tuning.
@MainActor
final class TuneTone: ObservableObject {
    static let timeout: TimeInterval = 20

    private static let tick: TimeInterval = 0.1
    private static let keyLossGrace: TimeInterval = 2.0
    private static let keyLossLimit: TimeInterval = 1.0

    @Published private(set) var isTuning = false
    /// Whole seconds left while tuning (published only when it changes).
    @Published private(set) var secondsLeft = Int(TuneTone.timeout)
    /// Why the last run ended early or couldn't start; cleared on the next start.
    @Published private(set) var message: String?

    private weak var hub: HubService?
    private var loop: Task<Void, Never>?
    private var previousMode: RigMode?
    private let logger = Logger(subsystem: "com.ftx1remote.mac", category: "tune")

    init(hub: HubService) {
        self.hub = hub
    }

    /// Why TUNE would be refused right now, nil when it would start.
    var blockReason: String? {
        guard let hub else { return nil }
        if isTuning { return nil }
        guard hub.connectionState == .connected else { return String(localized: "digiLink.notConnected") }
        if hub.rigState.ptt || hub.rigState.moxEnabled == true || hub.digiSender.isTransmitting {
            return String(localized: "digiLink.alreadyTransmitting")
        }
        if hub.rigState.splitEnabled != true, hub.rigState.txSide == .sub {
            return String(localized: "tune.txOnSub")
        }
        // The gate judges the transmission as it will be: in CW.
        var cwState = hub.rigState
        cwState.mode = .cw
        return TransmitGate.blockReason(transmitEnabled: hub.transmitEnabled, state: cwState, privileges: hub.activePrivileges)
    }

    func toggle() {
        if isTuning { stop() } else { start() }
    }

    func start() {
        guard !isTuning, let hub else { return }
        if let reason = blockReason {
            message = reason
            return
        }
        message = nil
        secondsLeft = Int(Self.timeout)
        previousMode = hub.rigState.mode
        isTuning = true
        // Queued in order: mode, then key.
        if previousMode != .cw { hub.send(.setMode(.cw)) }
        hub.send(.setPTT(true))
        logger.notice("tune started (was \(self.previousMode?.displayName ?? "?", privacy: .public))")
        loop = Task { [weak self] in await self?.run() }
    }

    /// Unkeys and restores the mode. `reason` is shown as the button's help text.
    func stop(reason: String? = nil) {
        guard isTuning else { return }
        loop?.cancel()
        loop = nil
        isTuning = false
        message = reason
        hub?.send(.setPTT(false))
        // Only if the operator hasn't changed the mode meanwhile.
        if let previous = previousMode, previous != .cw, hub?.rigState.mode == .cw {
            hub?.send(.setMode(previous))
        }
        logger.notice("tune stopped\(reason.map { ": " + $0 } ?? "", privacy: .public)")
        previousMode = nil
    }

    private func run() async {
        let start = ProcessInfo.processInfo.systemUptime
        var keyLostAt: TimeInterval?
        while !Task.isCancelled, let hub {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - start
            if elapsed >= Self.timeout {
                stop(reason: String(localized: "tune.timeout \(Int(Self.timeout))"))
                return
            }
            let left = Int((Self.timeout - elapsed).rounded(.up))
            if left != secondsLeft { secondsLeft = left }
            if hub.connectionState != .connected {
                stop(reason: String(localized: "digiLink.notConnected"))
                return
            }
            if !hub.transmitEnabled {
                stop(reason: String(localized: "tune.transmitOff"))
                return
            }
            if elapsed > Self.keyLossGrace, !hub.rigState.ptt {
                if let lostAt = keyLostAt {
                    if now - lostAt > Self.keyLossLimit {
                        stop(reason: String(localized: "tune.keyingEnded"))
                        return
                    }
                } else {
                    keyLostAt = now
                }
            } else {
                keyLostAt = nil
            }
            try? await Task.sleep(for: .seconds(Self.tick))
        }
    }
}

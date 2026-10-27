import Combine
import FTX1Core
import Foundation
import os

/// Wavelog CAT: reports the rig's transmit frequency, mode and RF power
/// setting to Wavelog as a radio (`Wavelog.reportRadio`, API v2's
/// `radio` resource), so Wavelog's QSO form and bandmap follow the rig the
/// way WaveLogGate makes them (user request, 2026-10-25). Settings →
/// Logbook → Wavelog's "Send rig frequency and mode" toggle; off by
/// default; the token needs `radio:write`.
///
/// Sent when what's reported changes, at most every `minimumInterval`,
/// and again every `keepAliveInterval` while it doesn't (Wavelog shows how
/// many minutes ago a radio last reported). Nothing is sent while the rig
/// isn't connected. After a failure it waits `retryInterval` before the
/// next try, so a bad token doesn't send a request per tuning step.
///
/// Runs from `HubService.start()` to `stop()` whatever the window state,
/// like the rest of the hub; settings are read at each send.
@MainActor
final class WavelogRadioReporter: ObservableObject {
    static let minimumInterval: TimeInterval = 2
    static let keepAliveInterval: TimeInterval = 60
    static let retryInterval: TimeInterval = 30

    /// The last send's outcome, for Settings.
    @Published private(set) var lastResult: (at: Date, error: String?)?

    private let logger = Logger(subsystem: "com.ftx1remote.mac", category: "wavelog")
    private let statuses: AnyPublisher<Wavelog.RadioStatus?, Never>
    private var cancellable: AnyCancellable?
    private var current: Wavelog.RadioStatus?
    private var task: Task<Void, Never>?
    private var lastSent: (status: Wavelog.RadioStatus, radio: String, generation: Int, at: Date)?
    /// Bumped by `resend()`, so a send already out when the settings
    /// changed doesn't count as sent with the new ones.
    private var generation = 0
    private var lastAttemptAt: Date?
    private var lastFailedAt: Date?
    /// A request is out: a change then waits for it (the loop picks up
    /// the newest status afterwards) rather than cancelling it.
    private var isSending = false

    init(rigState: some Publisher<RigState, Never>, connection: some Publisher<HubService.ConnectionState, Never>) {
        statuses = rigState.combineLatest(connection)
            .map { rig, connection in connection == .connected ? Self.status(of: rig) : nil }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = statuses.sink { [weak self] status in
            self?.current = status
            self?.wake()
        }
        wake()
    }

    func stop() {
        cancellable = nil
        task?.cancel()
        task = nil
    }

    /// Sends now, skipping the wait after a failure — Settings calls this
    /// when the toggle, URL, token or radio name changes.
    func resend() {
        generation += 1
        lastFailedAt = nil
        lastResult = nil
        wake()
    }

    /// What Wavelog is told: the transmitting side (the Log pane's rule),
    /// and the other side as RX while it isn't the one transmitting.
    static func status(of rig: RigState) -> Wavelog.RadioStatus? {
        let tx = rig.transmitter
        guard let frequency = tx.frequencyHz, frequency > 0 else { return nil }
        var status = Wavelog.RadioStatus(
            frequencyHz: frequency,
            mode: tx.mode.flatMap(Wavelog.catMode(for:)),
            powerWatts: rig.powerLevel.map { ($0 * 100).rounded() }
        )
        if rig.splitEnabled == true || rig.txSide == .sub, rig.frequencyHz > 0, rig.frequencyHz != frequency || rig.mode != tx.mode {
            status.frequencyRxHz = rig.frequencyHz
            status.modeRx = Wavelog.catMode(for: rig.mode)
        }
        return status
    }

    // MARK: Sending

    /// One loop at a time: it sends whatever's newest when it gets there,
    /// then sleeps until the next keep-alive or the next change.
    private func wake() {
        guard !isSending else { return }
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let delay = nextSendDelay() else { return }
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                continue
            }
            await send()
        }
    }

    /// Seconds until the next send is due, 0 for now, nil for nothing to
    /// send until something changes.
    private func nextSendDelay() -> TimeInterval? {
        guard LogbookSettings.wavelogCATEnabled, let status = current else { return nil }
        let now = Date.now
        var due = now
        if let lastSent, lastSent.status == status, lastSent.radio == LogbookSettings.wavelogRadioName, lastSent.generation == generation {
            due = lastSent.at.addingTimeInterval(Self.keepAliveInterval)
        }
        if let lastAttemptAt { due = max(due, lastAttemptAt.addingTimeInterval(Self.minimumInterval)) }
        if let lastFailedAt { due = max(due, lastFailedAt.addingTimeInterval(Self.retryInterval)) }
        return max(0, due.timeIntervalSince(now))
    }

    private func send() async {
        guard let status = current else { return }
        let radio = LogbookSettings.wavelogRadioName
        let generation = generation
        lastAttemptAt = .now
        let url = LogbookSettings.wavelogURL.trimmingCharacters(in: .whitespaces)
        let token = WavelogToken.read()
        guard !url.isEmpty, !token.isEmpty else {
            fail(String(localized: "wavelogRadioReporter.wavelogNeedsAUrl"))
            return
        }
        isSending = true
        defer { isSending = false }
        do throws(Wavelog.APIError) {
            try await Wavelog.reportRadio(status, radio: radio, base: url, token: token)
            lastSent = (status, radio, generation, .now)
            lastFailedAt = nil
            if lastResult?.error != nil { logger.notice("radio updates working again") }
            lastResult = (.now, nil)
        } catch {
            fail(error.description)
        }
    }

    private func fail(_ message: String) {
        if lastResult?.error != message {
            logger.error("radio update failed: \(message, privacy: .public)")
        }
        lastFailedAt = .now
        lastResult = (.now, message)
    }
}

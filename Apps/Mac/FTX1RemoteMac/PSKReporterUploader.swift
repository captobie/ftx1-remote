import Combine
import FTX1Core
import Foundation
import Network
import os

/// Uploads the FT8 window's decodes to PSK Reporter (the FT8 window's
/// "Upload to PSK Reporter" toggle) — packets built by `FTX1Core`'s
/// `PSKReporterPacket`. Runs only while the FT8 window decodes
/// (`start()`/`stop()` from `HubService.startFT8Decoding()`/
/// `stopFT8Decoding()`) *and* the toggle is on; the toggle is remembered,
/// off by default (user decision, 2026-10-18).
///
/// Follows pskdev.html's rules: a callsign at most once per hour per band
/// unless it newly carries a grid; one datagram every 5 minutes, timed from
/// when uploading started plus random jitter (never aligned to the clock),
/// or sooner once a full datagram's worth is waiting; the record
/// descriptors in the first 3 datagrams of a connection and hourly after;
/// one UDP flow (one source port) kept for the whole app session.
///
/// Its own object rather than `@Published` on `HubService` — only the FT8
/// window observes it, and it changes about once per decode cycle.
@MainActor
final class PSKReporterUploader: ObservableObject {
    static let enabledKey = "ft8.pskReporterEnabled"
    /// Debug builds only: send to this host (port 4739) instead, e.g.
    /// "127.0.0.1" for a local listener.
    static let hostOverrideKey = "pskReporter.hostOverride"

    static let flushInterval: TimeInterval = 5 * 60
    static let flushJitter: ClosedRange<TimeInterval> = 0...30
    static let repeatWindow: TimeInterval = 60 * 60
    static let templateInterval: TimeInterval = 60 * 60
    static let templatePackets = 3

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            SettingsStore.defaults.set(isEnabled, forKey: Self.enabledKey)
            logger.notice("upload \(self.isEnabled ? "on" : "off", privacy: .public)")
            if isEnabled {
                scheduleFlush()
            } else {
                // The connection stays: closing it right after a send can
                // drop that datagram, and the same source port is wanted
                // for the rest of the session anyway.
                flush()
                flushTask?.cancel()
                flushTask = nil
            }
        }
    }

    @Published private(set) var pendingCount = 0
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var nextUploadAt: Date?
    @Published private(set) var sentThisSession = 0
    @Published private(set) var lastError: String?

    /// Callsign and grid from Settings → Station; nothing is sent without both.
    static var stationIsSet: Bool {
        !StationSettings.callsign.trimmingCharacters(in: .whitespaces).isEmpty
            && !StationSettings.gridSquare.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private let logger = Logger(subsystem: "com.ftx1remote.mac", category: "pskreporter")
    private let queue = DispatchQueue(label: "com.ftx1remote.mac.pskreporter")
    private var isRunning = false
    private var pending: [PSKReporterPacket.Report] = []
    /// "CALL band" → when last queued, and whether that one had a grid.
    private var lastQueued: [String: (at: Date, hadGrid: Bool)] = [:]
    private var flushTask: Task<Void, Never>?

    private var connection: NWConnection?
    private var datagramsOnConnection = 0
    private var lastTemplatesAt: Date?
    private var sequence: UInt32 = 0
    private let domainID = UInt32.random(in: 1...UInt32.max)

    /// Last time PTT changed either way, so a slot the rig transmitted in
    /// can be skipped (its audio isn't off-air reception).
    private var isTransmitting = false
    private var lastPTTChangeAt: Date?
    private var pttCancellable: AnyCancellable?

    init(rigState: Published<RigState>.Publisher) {
        isEnabled = SettingsStore.defaults.bool(forKey: Self.enabledKey)
        pttCancellable = rigState.map(\.ptt).removeDuplicates().sink { [weak self] ptt in
            guard let self else { return }
            // The initial "not transmitting" isn't a change.
            if ptt || self.lastPTTChangeAt != nil || self.isTransmitting { self.lastPTTChangeAt = Date() }
            self.isTransmitting = ptt
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if isEnabled { scheduleFlush() }
    }

    /// The FT8 window closed (or the app quits): what's queued goes out now.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        flushTask?.cancel()
        flushTask = nil
        nextUploadAt = nil
        flush()
    }

    /// One decode cycle's spots, all from the slot starting `slotStart`.
    func enqueue(_ spots: [FT8Spot]) {
        guard isRunning, isEnabled, Self.stationIsSet, let first = spots.first else { return }
        let slotStart = first.utcTimestamp
        if isTransmitting || (lastPTTChangeAt.map { $0 >= slotStart } ?? false) {
            logger.debug("slot \(slotStart.timeIntervalSince1970, privacy: .public): rig transmitted, not reported")
            return
        }
        let myCall = StationSettings.callsign.trimmingCharacters(in: .whitespaces).uppercased()
        for spot in spots {
            guard let report = Self.report(from: spot), report.callsign != myCall else { continue }
            let band = BandPlan.band(containing: Int(report.frequencyHz))?.name ?? "\(report.frequencyHz / 1_000_000)MHz"
            let key = "\(report.callsign) \(band)"
            if let previous = lastQueued[key],
               report.time.timeIntervalSince(previous.at) < Self.repeatWindow,
               previous.hadGrid || report.locator == nil {
                continue
            }
            lastQueued[key] = (report.time, report.locator != nil)
            pending.append(report)
        }
        lastQueued = lastQueued.filter { Date().timeIntervalSince($0.value.at) < Self.repeatWindow }
        pendingCount = pending.count

        // A full datagram waiting goes out now rather than at the timer.
        if encode(includeTemplates: needsTemplates).count > 1 { flush() }
    }

    /// Only spots with a real, unhashed sender callsign on a known dial
    /// frequency; the grid only when it's a 4-character Maidenhead square.
    static func report(from spot: FT8Spot) -> PSKReporterPacket.Report? {
        guard spot.dialFrequencyHz > 0,
              let call = spot.spottedCallsign?.uppercased(),
              call.count >= 3, !call.contains("<"),
              call.contains(where: \.isNumber), call.contains(where: \.isLetter),
              call.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") })
        else { return nil }
        let frequency = spot.absoluteFrequencyHz.rounded()
        guard frequency > 0, frequency < Double(UInt32.max) else { return nil }
        return PSKReporterPacket.Report(
            callsign: call,
            frequencyHz: UInt32(frequency),
            mode: spot.mode,
            locator: spot.spottedGrid.flatMap(validGrid),
            time: spot.utcTimestamp
        )
    }

    private static func validGrid(_ grid: String) -> String? {
        let chars = Array(grid.uppercased())
        guard chars.count == 4,
              ("A"..."R").contains(chars[0]), ("A"..."R").contains(chars[1]),
              chars[2].isNumber, chars[3].isNumber, grid != "RR73"
        else { return nil }
        return String(chars)
    }

    private var needsTemplates: Bool {
        datagramsOnConnection < Self.templatePackets
            || lastTemplatesAt.map { Date().timeIntervalSince($0) >= Self.templateInterval } ?? true
    }

    private func receiver() -> PSKReporterPacket.Receiver {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return PSKReporterPacket.Receiver(
            callsign: StationSettings.callsign.trimmingCharacters(in: .whitespaces).uppercased(),
            locator: StationSettings.gridSquare.trimmingCharacters(in: .whitespaces),
            software: "FTX1Remote \(version)"
        )
    }

    private func encode(includeTemplates: Bool) -> [PSKReporterPacket.Datagram] {
        PSKReporterPacket.encode(
            receiver: receiver(), reports: pending, includeTemplates: includeTemplates,
            sequence: sequence, domainID: domainID, exportTime: Date())
    }

    private func scheduleFlush() {
        guard isRunning, isEnabled else { return }
        flushTask?.cancel()
        let delay = Self.flushInterval + TimeInterval.random(in: Self.flushJitter)
        nextUploadAt = Date().addingTimeInterval(delay)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.flush()
            self.scheduleFlush()
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        guard Self.stationIsSet else {
            pending = []
            pendingCount = 0
            return
        }
        let connection = openConnection()
        var reports = 0
        // Each datagram decides templates for itself, so a split batch on a
        // fresh connection still carries them in its first three.
        while !pending.isEmpty {
            let withTemplates = needsTemplates
            guard let datagram = encode(includeTemplates: withTemplates).first else { break }
            connection.send(content: datagram.data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.sendFailed(error) }
            })
            logger.notice("sent \(datagram.reportCount) report(s), \(datagram.data.count) bytes, seq \(self.sequence), templates \(withTemplates)")
            if withTemplates { lastTemplatesAt = Date() }
            datagramsOnConnection += 1
            sequence &+= UInt32(datagram.reportCount)
            pending.removeFirst(datagram.reportCount)
            reports += datagram.reportCount
        }
        pendingCount = pending.count
        sentThisSession += reports
        lastUploadAt = Date()
        lastError = nil
    }

    private func openConnection() -> NWConnection {
        if let connection { return connection }
        var host = PSKReporterPacket.host
        #if DEBUG
        if let override = SettingsStore.defaults.string(forKey: Self.hostOverrideKey), !override.isEmpty {
            host = override
        }
        #endif
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: PSKReporterPacket.port)!, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                Task { @MainActor in self?.sendFailed(error) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        datagramsOnConnection = 0
        logger.notice("connection to \(host, privacy: .public):\(PSKReporterPacket.port)")
        return connection
    }

    /// UDP gets no reply, so this only sees local failures (no route, DNS).
    /// The connection is dropped; the next upload opens a new one, with the
    /// descriptors again since the source port changes.
    private func sendFailed(_ error: Error) {
        logger.error("upload failed: \(error.localizedDescription, privacy: .public)")
        lastError = error.localizedDescription
        closeConnection()
    }

    private func closeConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        datagramsOnConnection = 0
    }
}

import Combine
import Foundation
import FTX1Core
import os

/// FreeDV Reporter (qso.freedv.org): reports this station — frequency,
/// transmitting or not, its status message, the callsigns it hears — and
/// keeps the live list of every other station on it.
///
/// Connected only while `enabled` (the window's checkbox, saved, off by
/// default), `active` (the FreeDV window is open) and Settings → Station
/// has a callsign and a grid. Reconnects with a growing delay; our state
/// is sent again on every (re)connect. Its own object, observed only by
/// the window's reporter views.
@MainActor
public final class FreeDVReporter: ObservableObject {
    public enum Status: Equatable, Sendable {
        case off
        /// Enabled, but Settings → Station lacks a callsign or grid.
        case needsStation
        case connecting
        case connected
        /// Lost or refused; retrying.
        case retrying(String)
    }

    @Published public private(set) var status: Status = .off
    /// Every station on FreeDV Reporter, most recently updated first.
    @Published public private(set) var stations: [FreeDVReporterStation] = []
    @Published public var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Key.enabled)
            reconsider()
        }
    }
    /// Shown next to our call on the site. Sent when it changes.
    @Published public var message: String {
        didSet {
            guard message != oldValue else { return }
            defaults.set(message, forKey: Key.message)
            send(FreeDVReporterProtocol.message(message))
        }
    }

    private let version: String
    private let host: String
    private let stationProvider: () -> (callsign: String, grid: String)
    private let logger: Logger
    private let defaults = SettingsStore.defaults
    private let session: URLSession

    private var active = false
    private var frequencyHz: Int?
    private var transmitting = false
    private var table = FreeDVReporterStations()
    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var fullyConnected = false
    private var pingDeadline = Date.distantFuture
    private var publishScheduled = false

    private enum Key {
        static let enabled = "freedv.reporter.enabled"
        static let message = "freedv.reporter.message"
    }

    /// Reconnect delays, growing; the last repeats.
    static let retryDelays: [TimeInterval] = [5, 10, 30, 60]

    /// - Parameters:
    ///   - version: what the site shows as our software ("FTX1Remote 0.14").
    ///   - station: our callsign and grid, read at each connect.
    public init(version: String, logSubsystem: String, host: String = FreeDVReporterProtocol.defaultHost,
                station: @escaping () -> (callsign: String, grid: String) = {
                    (StationSettings.callsign, StationSettings.gridSquare)
                }) {
        self.version = version
        self.host = host
        stationProvider = station
        logger = Logger(subsystem: logSubsystem, category: "freedv-reporter")
        session = URLSession(configuration: .ephemeral)
        let defaults = SettingsStore.defaults
        enabled = defaults.bool(forKey: Key.enabled)
        message = defaults.string(forKey: Key.message) ?? ""
    }

    // MARK: - Inputs

    /// The FreeDV window opened or closed.
    public func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        reconsider()
    }

    /// Settings → Station may have changed: connect or reconnect as needed.
    public func stationChanged() {
        if runTask != nil { stopConnection() }
        reconsider()
    }

    /// Where we listen (and would transmit). nil = unknown, sent as 0.
    public func setFrequency(_ hz: Int?) {
        guard hz != frequencyHz else { return }
        frequencyHz = hz
        send(FreeDVReporterProtocol.frequencyChange(hz ?? 0))
    }

    public func setTransmitting(_ transmitting: Bool) {
        guard transmitting != self.transmitting else { return }
        self.transmitting = transmitting
        send(FreeDVReporterProtocol.transmitReport(transmitting: transmitting))
    }

    /// A callsign decoded from an end-of-over, live (not from a file).
    public func reportHeard(callsign: String, snrDB: Float?) {
        send(FreeDVReporterProtocol.receiveReport(callsign: callsign, snrDB: Int((snrDB ?? 0).rounded())))
    }

    // MARK: - Connection

    private var station: (callsign: String, grid: String)? {
        let station = stationProvider()
        let call = station.callsign.trimmingCharacters(in: .whitespaces).uppercased()
        let grid = station.grid.trimmingCharacters(in: .whitespaces)
        return call.isEmpty || grid.count < 4 ? nil : (call, grid)
    }

    private func reconsider() {
        guard enabled, active else {
            stopConnection()
            status = .off
            return
        }
        guard station != nil else {
            stopConnection()
            status = .needsStation
            return
        }
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    private func stopConnection() {
        runTask?.cancel()
        runTask = nil
        closeSocket()
        clearStations()
    }

    private func closeSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        fullyConnected = false
    }

    /// Connects, reads until the connection ends, waits, repeats.
    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            guard let station else { status = .needsStation; return }
            status = .connecting
            let reason = await connectAndRead(callsign: station.callsign, grid: station.grid)
            closeSocket()
            clearStations()
            guard !Task.isCancelled else { return }
            if fullyConnectedOnce { attempt = 0 }
            fullyConnectedOnce = false
            let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
            attempt += 1
            status = .retrying(reason)
            logger.notice("disconnected (\(reason, privacy: .public)), retrying in \(delay, privacy: .public) s")
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private var fullyConnectedOnce = false

    /// One connection, until it drops; returns why.
    private func connectAndRead(callsign: String, grid: String) async -> String {
        let task = session.webSocketTask(with: FreeDVReporterProtocol.url(host: host))
        socket = task
        task.resume()
        pingDeadline = Date().addingTimeInterval(30)
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if Date() > self.pingDeadline {
                    self.logger.notice("no ping from the server in time")
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                return error.localizedDescription
            }
            guard case .string(let frame) = message else { continue }
            switch FreeDVReporterProtocol.parse(frame) {
            case .open(let interval, let timeout):
                pingDeadline = Date().addingTimeInterval(interval + timeout)
                pingAllowance = interval + timeout
                write(FreeDVReporterProtocol.connectFrame(
                    callsign: callsign, gridSquare: grid, version: version, receiveOnly: false, os: "macOS"), on: task)
            case .ping:
                pingDeadline = Date().addingTimeInterval(pingAllowance)
                write(FreeDVReporterProtocol.pong, on: task)
            case .connected:
                logger.notice("connected to \(self.host, privacy: .public) as \(callsign, privacy: .public)")
            case .event(let name, let payload):
                handle(event: name, payload: payload, task: task)
            case .connectError(let text):
                return text
            case .close, .disconnected:
                return String(localized: "freeDVReporter.closedByServer", bundle: .module)
            case .unknown:
                break
            }
        }
        return String(localized: "freeDVReporter.closedByServer", bundle: .module)
    }

    private var pingAllowance: TimeInterval = 45

    private func handle(event name: String, payload: Any?, task: URLSessionWebSocketTask) {
        if name == "connection_successful" {
            fullyConnected = true
            fullyConnectedOnce = true
            status = .connected
            // Our state, as freedv-backend sends it once fully connected.
            write(FreeDVReporterProtocol.frequencyChange(frequencyHz ?? 0), on: task)
            write(FreeDVReporterProtocol.transmitReport(transmitting: transmitting), on: task)
            write(FreeDVReporterProtocol.message(message), on: task)
            return
        }
        if table.apply(event: name, payload: payload) { schedulePublish() }
    }

    private func send(_ frame: String) {
        guard fullyConnected, let socket else { return }
        write(frame, on: socket)
    }

    private func write(_ frame: String, on task: URLSessionWebSocketTask) {
        task.send(.string(frame)) { [logger] error in
            if let error { logger.debug("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Station list

    /// A bulk update or a busy band can bring dozens of events at once:
    /// the list is republished at most twice a second.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.publishScheduled = false
            self.stations = Self.sorted(self.table)
        }
    }

    private func clearStations() {
        table.removeAll()
        if !stations.isEmpty { stations = [] }
    }

    static func sorted(_ table: FreeDVReporterStations) -> [FreeDVReporterStation] {
        table.stations.values.sorted {
            ($0.lastUpdate ?? .distantPast, $1.callsign) > ($1.lastUpdate ?? .distantPast, $0.callsign)
        }
    }
}

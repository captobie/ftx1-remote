import Combine
import FTX1Core
import Foundation
import os

private let workedLogger = Logger(subsystem: "com.ftx1remote.mac", category: "logbook")

/// "Worked before?" for the CW window: MacLoggerDX's log read once into a
/// `WorkedStations` index (read-only, off the main actor), plus the band
/// the rig transmits on, which decides "this band" vs "other band".
///
/// Runs only while a view needs it (`start()`/`stop()`, from the CW
/// window): then it checks the log file's modification date every few
/// seconds and rebuilds the index when it changed — MacLoggerDX writes
/// with a rollback journal (`journal_mode = delete`), so a new QSO
/// changes the main file's date. A `let`/`lazy var` on `HubService` and
/// its own object, so neither a reload nor a band change re-renders
/// anything that doesn't show worked-before.
@MainActor
final class WorkedStationsStore: ObservableObject {
    @Published private(set) var worked = WorkedStations.empty
    /// The transmitting side's band ("40m"), nil outside the amateur bands
    /// or while the frequency is unknown.
    @Published private(set) var band: String?
    /// Why there's no index, for the Log pane; nil when it loaded.
    @Published private(set) var problem: String?

    static let checkInterval: TimeInterval = 5

    private var users = 0
    private var timer: Timer?
    /// Path + modification date of what `worked` was built from.
    private var loadedStamp: Stamp?
    private var isLoading = false
    private var bandCancellable: AnyCancellable?

    private struct Stamp: Equatable, Sendable {
        var path: String
        var modified: Date?
    }

    init(rigState: Published<RigState>.Publisher) {
        bandCancellable = rigState
            .map { rig in rig.transmitter.frequencyHz.flatMap { BandPlan.band(containing: $0)?.name } }
            .removeDuplicates()
            .sink { [weak self] band in self?.band = band }
    }

    func start() {
        users += 1
        guard users == 1 else { return }
        reloadIfChanged()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    func stop() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads the log now, e.g. right after logging a QSO.
    func reload() {
        loadedStamp = nil
        reloadIfChanged()
    }

    private func reloadIfChanged() {
        guard LogbookSettings.logger == .macLoggerDX else {
            loadedStamp = nil
            worked = .empty
            problem = "No logbook selected"
            return
        }
        guard let path = LogbookSettings.macLoggerDXLogPath else {
            loadedStamp = nil
            worked = .empty
            problem = "MacLoggerDX's log file wasn't found"
            return
        }
        guard !isLoading else { return }
        isLoading = true
        let loaded = loadedStamp
        // Everything that touches the file runs off the main actor: the
        // log is in ~/Documents, and the first access waits on macOS's
        // "access files in your Documents folder" prompt — on the main
        // thread that froze the app until it was answered (2026-10-07).
        Task {
            let (stamp, result) = await Task.detached { () -> (Stamp, Result<[WorkedStations.QSO], MacLoggerDX.LogError>?) in
                let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                let stamp = Stamp(path: path, modified: modified)
                guard stamp != loaded else { return (stamp, nil) }
                return (stamp, Result { () throws(MacLoggerDX.LogError) in
                    try MacLoggerDX.readWorkedQSOs(path: path)
                })
            }.value
            isLoading = false
            switch result {
            case nil:
                break
            case .success(let qsos):
                worked = WorkedStations(qsos: qsos)
                problem = nil
                loadedStamp = stamp
                workedLogger.notice("Worked-before index: \(qsos.count) QSOs, \(self.worked.stationCount) stations")
            case .failure(let error):
                worked = .empty
                problem = error.description
                // Leave loadedStamp alone so the next check tries again.
                workedLogger.error("Worked-before index: \(error.description, privacy: .public)")
            }
        }
    }
}

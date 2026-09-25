import FTX1Core
import SwiftUI

/// The WebSDR window's "Stations…" sheet: a searchable, sortable table of
/// public KiwiSDRs (`KiwiSDRDirectory`). Choosing a station only fills the
/// host field (`WebSDRFollowModel.select`) — connecting stays a separate,
/// explicit Connect in the window itself.
struct KiwiSDRDirectoryView: View {
    @ObservedObject var directory: KiwiSDRDirectory
    /// The rig frequency being followed, for the "Covers rig frequency"
    /// filter; nil/0 disables it.
    let rigFrequencyHz: Int?
    /// `WebSDRFavorite.id`s, for the star column and "Favorites only".
    let favoriteIDs: Set<String>
    let onToggleFavorite: (KiwiSDRStation) -> Void
    let onChoose: (KiwiSDRStation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var coversRigFrequency = false
    @State private var hideFull = false
    @State private var favoritesOnly = false
    @State private var selection: KiwiSDRStation.ID?
    /// Nearest first when the operator's grid square is set; otherwise
    /// every distance is "—", so sort by name instead.
    @State private var sortOrder: [KeyPathComparator<Row>] =
        Maidenhead.coordinates(of: StationSettings.gridSquare) != nil
            ? [KeyPathComparator(\Row.distanceSortKey)]
            : [KeyPathComparator(\Row.name)]

    /// One table row: the station plus its distance from the operator's
    /// grid square, precomputed so it can be a sortable column.
    struct Row: Identifiable {
        let station: KiwiSDRStation
        let distanceKm: Double?

        var id: String { station.id }
        var name: String { station.name }
        var location: String { station.location }
        var distanceSortKey: Double { distanceKm ?? .infinity }
        var users: Int { station.users }
        var snrSortKey: Int { station.snr ?? -1 }
        var bandsSortKey: Int { station.bands.map(\.upperBound).max() ?? 0 }
        var antenna: String { station.antenna }
    }

    private var home: (latitude: Double, longitude: Double)? {
        Maidenhead.coordinates(of: StationSettings.gridSquare)
    }

    private var rigFrequencyUsable: Int? {
        guard let rigFrequencyHz, rigFrequencyHz > 0 else { return nil }
        return rigFrequencyHz
    }

    private var rows: [Row] {
        let home = home
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filterFrequency = coversRigFrequency ? rigFrequencyUsable : nil
        return directory.stations
            .filter { station in
                if favoritesOnly, !isFavorite(station) { return false }
                if hideFull, station.isFull { return false }
                if let filterFrequency, !station.covers(frequencyHz: filterFrequency) { return false }
                if query.isEmpty { return true }
                return [station.name, station.location, station.grid, station.antenna, station.hostPort]
                    .contains { $0.lowercased().contains(query) }
            }
            .map { station in
                var distance: Double?
                if let home, let lat = station.latitude, let lon = station.longitude {
                    distance = Maidenhead.distanceKm(from: home, to: (lat, lon))
                }
                return Row(station: station, distanceKm: distance)
            }
            .sorted(using: sortOrder)
    }

    private func isFavorite(_ station: KiwiSDRStation) -> Bool {
        favoriteIDs.contains(WebSDRFavorite.key(station.hostPort))
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            filterBar
                .padding(10)
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                // Not sortable ("Favorites only" covers that); starring
                // doesn't choose the station or close the sheet.
                TableColumn("") { row in
                    let starred = isFavorite(row.station)
                    Button { onToggleFavorite(row.station) } label: {
                        Image(systemName: starred ? "star.fill" : "star")
                            .foregroundStyle(starred ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(starred ? "Remove from Favorites" : "Add to Favorites")
                }
                .width(22)
                TableColumn("Name", value: \.name) { row in
                    Text(row.name).help(row.name)
                }
                .width(min: 200, ideal: 280)
                TableColumn("Location", value: \.location) { row in
                    Text(row.location).help(row.location)
                }
                .width(min: 120, ideal: 180)
                TableColumn("Distance", value: \.distanceSortKey) { row in
                    Text(row.distanceKm.map { "\(Int($0.rounded())) km" } ?? "—")
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn("Users", value: \.users) { row in
                    Text("\(row.station.users)/\(row.station.usersMax)")
                        .monospacedDigit()
                        .foregroundStyle(row.station.isFull ? .red : .primary)
                }
                .width(min: 45, ideal: 50)
                TableColumn("SNR", value: \.snrSortKey) { row in
                    Text(row.station.snr.map { "\($0) dB" } ?? "—").monospacedDigit()
                }
                .width(min: 45, ideal: 55)
                TableColumn("Range", value: \.bandsSortKey) { row in
                    Text(row.station.bandsDescription)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Antenna", value: \.antenna) { row in
                    Text(row.antenna).help(row.antenna)
                }
                .width(min: 120, ideal: 200)
            }
            // Double-click chooses too — it still only fills the host field.
            .contextMenu(forSelectionType: KiwiSDRStation.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { choose(id) }
            }
            .overlay { emptyState(rowCount: rows.count) }
            Divider()
            footer(rowCount: rows.count)
                .padding(10)
        }
        .frame(minWidth: 900, minHeight: 520)
        .onAppear { directory.loadIfNeeded() }
    }

    private var filterBar: some View {
        HStack(spacing: 14) {
            TextField("Search name, location, grid, antenna", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Toggle(coversFrequencyLabel, isOn: $coversRigFrequency)
                .disabled(rigFrequencyUsable == nil)
                .help(rigFrequencyUsable == nil
                      ? "Available once the rig's frequency is known."
                      : "Only stations whose receive range includes the rig's current frequency.")
            Toggle("Hide full", isOn: $hideFull)
            Toggle("Favorites only", isOn: $favoritesOnly)
            Spacer()
            if home == nil {
                Text("Set your grid square in Settings → Station to sort by distance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var coversFrequencyLabel: String {
        guard let hz = rigFrequencyUsable else { return "Covers rig frequency" }
        return String(format: "Covers %.3f MHz", Double(hz) / 1_000_000)
    }

    @ViewBuilder
    private func emptyState(rowCount: Int) -> some View {
        if directory.stations.isEmpty {
            switch directory.state {
            case .loading, .idle:
                ProgressView("Loading KiwiSDR list…")
            case let .failed(message):
                ContentUnavailableView("Station List Unavailable",
                                       systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text(message))
            }
        } else if rowCount == 0 {
            ContentUnavailableView.search
        }
    }

    private func footer(rowCount: Int) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary(rowCount: rowCount))
                if case let .failed(message) = directory.state, !directory.stations.isEmpty {
                    Text(message).foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Refresh", systemImage: "arrow.clockwise", action: directory.refresh)
                .labelStyle(.titleAndIcon)
                .disabled(directory.state == .loading)
            if directory.state == .loading, !directory.stations.isEmpty {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Use Station") {
                if let selection { choose(selection) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
    }

    private func summary(rowCount: Int) -> String {
        var parts = ["\(rowCount) of \(directory.stations.count) stations"]
        if let fetchedAt = directory.fetchedAt {
            parts.append("updated " + fetchedAt.formatted(.relative(presentation: .named)))
        }
        parts.append("list from rx.linkfanel.net")
        return parts.joined(separator: " · ")
    }

    private func choose(_ id: KiwiSDRStation.ID) {
        guard let station = directory.stations.first(where: { $0.id == id }) else { return }
        onChoose(station)
        dismiss()
    }
}

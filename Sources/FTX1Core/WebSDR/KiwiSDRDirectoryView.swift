import SwiftUI

/// The WebSDR window's "Stations…" sheet: a searchable, sortable table of
/// public KiwiSDRs (`KiwiSDRDirectory`). Choosing a station only fills the
/// host field (`WebSDRFollowModel.select`) — connecting stays a separate,
/// explicit Connect in the window itself.
public struct KiwiSDRDirectoryView: View {
    @ObservedObject public var directory: KiwiSDRDirectory
    /// The rig frequency being followed, for the "Covers rig frequency"
    /// filter; nil/0 disables it.
    public let rigFrequencyHz: Int?
    /// `WebSDRFavorite.id`s, for the star column and "Favorites only".
    public let favoriteIDs: Set<String>
    public let onToggleFavorite: (KiwiSDRStation) -> Void
    public let onChoose: (KiwiSDRStation) -> Void

    public init(directory: KiwiSDRDirectory, rigFrequencyHz: Int?, favoriteIDs: Set<String>,
                onToggleFavorite: @escaping (KiwiSDRStation) -> Void,
                onChoose: @escaping (KiwiSDRStation) -> Void) {
        self.directory = directory
        self.rigFrequencyHz = rigFrequencyHz
        self.favoriteIDs = favoriteIDs
        self.onToggleFavorite = onToggleFavorite
        self.onChoose = onChoose
    }

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

    public var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            filterBar
                .padding(10)
            Divider()
            stationList(rows)
                .overlay { emptyState(rowCount: rows.count) }
            Divider()
            footer(rowCount: rows.count)
                .padding(10)
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 520)
        #endif
        .onAppear { directory.loadIfNeeded() }
    }

    #if os(macOS)
    private func stationList(_ rows: [Row]) -> some View {
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
                    .help(starred ? String(localized: "common.removeFromFavorites", bundle: .module) : String(localized: "kiwiSDRDirectory.addToFavorites", bundle: .module))
                }
                .width(22)
                TableColumn(String(localized: "common.name", bundle: .module), value: \.name) { row in
                    Text(row.name).help(row.name)
                }
                .width(min: 200, ideal: 280)
                TableColumn(String(localized: "kiwiSDRDirectory.location", bundle: .module), value: \.location) { row in
                    Text(row.location).help(row.location)
                }
                .width(min: 120, ideal: 180)
                TableColumn(String(localized: "kiwiSDRDirectory.distance", bundle: .module), value: \.distanceSortKey) { row in
                    Text(row.distanceKm.map { "\(Int($0.rounded())) km" } ?? "—")
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn(String(localized: "kiwiSDRDirectory.users", bundle: .module), value: \.users) { row in
                    Text("\(row.station.users)/\(row.station.usersMax)")
                        .monospacedDigit()
                        .foregroundStyle(row.station.isFull ? .red : .primary)
                }
                .width(min: 45, ideal: 50)
                TableColumn("SNR", value: \.snrSortKey) { row in
                    Text(row.station.snr.map { "\($0) dB" } ?? "—").monospacedDigit()
                }
                .width(min: 45, ideal: 55)
                TableColumn(String(localized: "kiwiSDRDirectory.range", bundle: .module), value: \.bandsSortKey) { row in
                    Text(row.station.bandsDescription)
                }
                .width(min: 80, ideal: 100)
                TableColumn(String(localized: "kiwiSDRDirectory.antenna", bundle: .module), value: \.antenna) { row in
                    Text(row.antenna).help(row.antenna)
                }
                .width(min: 120, ideal: 200)
            }
            // Double-click chooses too — it still only fills the host field.
            .contextMenu(forSelectionType: KiwiSDRStation.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { choose(id) }
            }
    }
    #else
    /// The iPad's list: a sheet there is horizontally compact, where a
    /// `Table` shows only its first column. A tap chooses the station (it
    /// still only fills the host field); the star stars it.
    private func stationList(_ rows: [Row]) -> some View {
        List(rows) { row in
            HStack(spacing: 12) {
                let starred = isFavorite(row.station)
                Button { onToggleFavorite(row.station) } label: {
                    Image(systemName: starred ? "star.fill" : "star")
                        .foregroundStyle(starred ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(starred ? String(localized: "common.removeFromFavorites", bundle: .module)
                                    : String(localized: "kiwiSDRDirectory.addToFavorites", bundle: .module))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .lineLimit(1)
                    Text(verbatim: [row.location,
                                    row.distanceKm.map { "\(Int($0.rounded())) km" },
                                    "\(row.station.users)/\(row.station.usersMax)",
                                    row.station.snr.map { "SNR \($0) dB" },
                                    row.station.bandsDescription]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(row.station.isFull ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { choose(row.id) }
        }
        .listStyle(.plain)
    }
    #endif

    private var filterBar: some View {
        #if os(macOS)
        filterControls
        #else
        // The iPad's sheet is narrower: search on its own line.
        VStack(alignment: .leading, spacing: 10) {
            TextField(String(localized: "kiwiSDRDirectory.searchNameLocationGrid", bundle: .module), text: $search)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { filterToggles }
                VStack(alignment: .leading, spacing: 8) { filterToggles }
            }
            if home == nil {
                Text(String(localized: "kiwiSDRDirectory.setYourGridSquare", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #endif
    }

    @ViewBuilder
    private var filterToggles: some View {
        Toggle(coversFrequencyLabel, isOn: $coversRigFrequency)
            .disabled(rigFrequencyUsable == nil)
            .fixedSize()
        Toggle(String(localized: "kiwiSDRDirectory.hideFull", bundle: .module), isOn: $hideFull)
            .fixedSize()
        Toggle(String(localized: "kiwiSDRDirectory.favoritesOnly", bundle: .module), isOn: $favoritesOnly)
            .fixedSize()
    }

    private var filterControls: some View {
        HStack(spacing: 14) {
            TextField(String(localized: "kiwiSDRDirectory.searchNameLocationGrid", bundle: .module), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Toggle(coversFrequencyLabel, isOn: $coversRigFrequency)
                .disabled(rigFrequencyUsable == nil)
                .help(rigFrequencyUsable == nil
                      ? String(localized: "kiwiSDRDirectory.availableOnceTheRigs", bundle: .module)
                      : String(localized: "kiwiSDRDirectory.onlyStationsWhoseReceive", bundle: .module))
            Toggle(String(localized: "kiwiSDRDirectory.hideFull", bundle: .module), isOn: $hideFull)
            Toggle(String(localized: "kiwiSDRDirectory.favoritesOnly", bundle: .module), isOn: $favoritesOnly)
            Spacer()
            if home == nil {
                Text(String(localized: "kiwiSDRDirectory.setYourGridSquare", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var coversFrequencyLabel: String {
        guard let hz = rigFrequencyUsable else { return String(localized: "kiwiSDRDirectory.coversRigFrequency", bundle: .module) }
        return String(localized: "kiwiSDRDirectory.coversMHz \(FrequencyFormat.mhz(hz, fractionDigits: 3))", bundle: .module)
    }

    @ViewBuilder
    private func emptyState(rowCount: Int) -> some View {
        if directory.stations.isEmpty {
            switch directory.state {
            case .loading, .idle:
                ProgressView(String(localized: "kiwiSDRDirectory.loadingKiwiSDRList", bundle: .module))
            case let .failed(message):
                ContentUnavailableView(String(localized: "kiwiSDRDirectory.stationListUnavailable", bundle: .module),
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
            Button(String(localized: "common.refresh", bundle: .module), systemImage: "arrow.clockwise", action: directory.refresh)
                .labelStyle(.titleAndIcon)
                .disabled(directory.state == .loading)
            if directory.state == .loading, !directory.stations.isEmpty {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(String(localized: "common.cancel", bundle: .module)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            #if os(macOS)
            Button(String(localized: "kiwiSDRDirectory.useStation", bundle: .module)) {
                if let selection { choose(selection) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
            #endif
        }
    }

    private func summary(rowCount: Int) -> String {
        let total = directory.stations.count
        guard let fetchedAt = directory.fetchedAt else {
            return String(localized: "kiwiSDRDirectory.summary \(rowCount) \(total)", bundle: .module)
        }
        return String(localized: "kiwiSDRDirectory.summaryUpdated \(rowCount) \(total) \(fetchedAt.formatted(.relative(presentation: .named)))", bundle: .module)
    }

    private func choose(_ id: KiwiSDRStation.ID) {
        guard let station = directory.stations.first(where: { $0.id == id }) else { return }
        onChoose(station)
        dismiss()
    }
}

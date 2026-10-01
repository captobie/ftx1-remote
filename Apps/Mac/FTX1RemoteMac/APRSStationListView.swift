import FTX1Core
import SwiftUI

/// The FM/C4FM menu page's APRS S.LIST button opens this in its own
/// window (`aprs-stations`, declared in `FTX1RemoteMacApp`) rather than a
/// sheet — meant to be left open alongside the main window while
/// operating.
struct APRSStationListView: View {
    @EnvironmentObject private var store: APRSStore
    @State private var sourceFilter: APRSSource?
    @State private var searchText = ""
    @State private var heardWindow: APRSHeardWindow = .any
    @State private var positionOnly = false

    var body: some View {
        Table(filteredStations) {
            TableColumn("Callsign") { station in
                Text(station.callsign).fontDesign(.monospaced)
            }
            TableColumn("Source") { station in
                Text(station.source == .main ? "Main" : "Sub")
            }
            TableColumn("Position") { station in
                Text(Self.positionString(station))
            }
            TableColumn("Symbol") { station in
                Text([station.symbolTable, station.symbolCode].compactMap { $0 }.joined())
            }
            TableColumn("Comment") { station in
                Text(station.comment ?? "")
            }
            TableColumn("Last Heard") { station in
                Text(station.lastHeardAt, style: .relative)
            }
        }
        .navigationTitle("APRS Stations")
        .frame(minWidth: 520, minHeight: 300)
        .toolbar {
            ToolbarItem {
                APRSSourcePicker(selection: $sourceFilter)
            }
            ToolbarItem {
                Menu {
                    Picker("Heard Within", selection: $heardWindow) {
                        ForEach(APRSHeardWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("With Position Only", isOn: $positionOnly)
                } label: {
                    Label("Filter", systemImage: isFiltering
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .help("Filter by time heard and position")
            }
        }
        .searchable(text: $searchText, prompt: "Callsign or comment")
        .overlay {
            if store.stations.isEmpty {
                ContentUnavailableView("No Stations Heard", systemImage: "antenna.radiowaves.left.and.right", description: Text("Decoded APRS stations will appear here while tuned to the configured APRS frequency."))
            } else if filteredStations.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var isFiltering: Bool { heardWindow != .any || positionOnly }

    private var filteredStations: [APRSStation] {
        store.stations
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .filter { heardWindow.includes($0.lastHeardAt) }
            .filter { !positionOnly || ($0.latitude != nil && $0.longitude != nil) }
            .filter { APRSListFilter.matches(searchText, $0.callsign, $0.comment) }
            .sorted { $0.lastHeardAt > $1.lastHeardAt }
    }

    private static func positionString(_ station: APRSStation) -> String {
        guard let latitude = station.latitude, let longitude = station.longitude else { return "—" }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }
}

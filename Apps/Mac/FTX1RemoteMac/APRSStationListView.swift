import FTX1Core
import SwiftUI

/// The FM/C4FM menu page's APRS S.LIST button opens this in its own
/// window (`aprs-stations`, declared in `FTX1RemoteMacApp`) rather than a
/// sheet — meant to be left open alongside the main window while
/// operating.
struct APRSStationListView: View {
    @EnvironmentObject private var store: APRSStore
    @State private var sourceFilter: APRSSource?

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
                Picker("Source", selection: $sourceFilter) {
                    Text("All").tag(APRSSource?.none)
                    Text("Main").tag(APRSSource?.some(.main))
                    Text("Sub").tag(APRSSource?.some(.sub))
                }
                .pickerStyle(.segmented)
            }
        }
        .overlay {
            if store.stations.isEmpty {
                ContentUnavailableView("No Stations Heard", systemImage: "antenna.radiowaves.left.and.right", description: Text("Decoded APRS stations will appear here while tuned to the configured APRS frequency."))
            }
        }
    }

    private var filteredStations: [APRSStation] {
        store.stations
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .sorted { $0.lastHeardAt > $1.lastHeardAt }
    }

    private static func positionString(_ station: APRSStation) -> String {
        guard let latitude = station.latitude, let longitude = station.longitude else { return "—" }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }
}

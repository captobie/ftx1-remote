import FTX1Core
import MapKit
import SwiftUI

/// Plots decoded APRS position reports (`APRSStore.stations`) on an Apple
/// Maps view. Opened from the View menu (`FTX1RemoteMacApp`'s `.commands`)
/// into its own window (`aprs-map`), same pattern as the S.LIST/M.LIST
/// windows.
struct APRSMapView: View {
    @EnvironmentObject private var store: APRSStore
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedCallsign: String?

    private var plottedStations: [APRSStation] {
        store.stations.filter { $0.latitude != nil && $0.longitude != nil }
    }

    var body: some View {
        Map(position: $cameraPosition, selection: $selectedCallsign) {
            ForEach(plottedStations) { station in
                Marker(station.callsign, coordinate: CLLocationCoordinate2D(latitude: station.latitude!, longitude: station.longitude!))
                    .tag(station.callsign)
                    .tint(station.source == .main ? .blue : .orange)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .navigationTitle("APRS Map")
        .frame(minWidth: 520, minHeight: 400)
        .overlay(alignment: .bottomLeading) {
            if let selectedCallsign, let station = plottedStations.first(where: { $0.callsign == selectedCallsign }) {
                detailPanel(for: station)
            }
        }
        .overlay {
            if plottedStations.isEmpty {
                ContentUnavailableView("No Positions Heard", systemImage: "map", description: Text("Decoded APRS position reports will appear here while tuned to the configured APRS frequency."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    fitAllStations()
                } label: {
                    Label("Fit All Stations", systemImage: "scope")
                }
                .disabled(plottedStations.isEmpty)
            }
        }
        .onAppear { fitAllStations() }
    }

    @ViewBuilder
    private func detailPanel(for station: APRSStation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(station.callsign).font(.headline).fontDesign(.monospaced)
                Spacer()
                Button {
                    selectedCallsign = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let latitude = station.latitude, let longitude = station.longitude {
                Text(String(format: "%.4f, %.4f", latitude, longitude))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let comment = station.comment, !comment.isEmpty {
                Text(comment).font(.caption)
            }
            Text(station.lastHeardAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    /// Fits the camera to every plotted station — called once when the
    /// window opens, and again on demand via the toolbar button, but never
    /// automatically on later updates so a live-updating map doesn't yank
    /// the view out from under someone panning/zooming to look at it.
    private func fitAllStations() {
        let coordinates = plottedStations.compactMap { station -> CLLocationCoordinate2D? in
            guard let latitude = station.latitude, let longitude = station.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        guard !coordinates.isEmpty else { return }
        if coordinates.count == 1, let only = coordinates.first {
            cameraPosition = .region(MKCoordinateRegion(center: only, latitudinalMeters: 20_000, longitudinalMeters: 20_000))
            return
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min()!
        let maxLatitude = latitudes.max()!
        let minLongitude = longitudes.min()!
        let maxLongitude = longitudes.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLatitude - minLatitude) * 1.4, 0.5),
            longitudeDelta: max((maxLongitude - minLongitude) * 1.4, 0.5)
        )
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }
}

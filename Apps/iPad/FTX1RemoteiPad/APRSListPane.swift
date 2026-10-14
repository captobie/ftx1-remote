import FTX1Core
import SwiftUI

/// The FM page's APRS S.LIST/M.LIST on the iPad: shown in place of the
/// MENU grid (`MenuPageView`'s `onShowAPRSList`), over the grid's own
/// frame, until Close puts the grid back. The grid stays underneath,
/// hidden, so it comes back on the FM page it was left on.
///
/// The same columns and filters as the Mac's `APRSStationListView`/
/// `APRSMessageListView` windows, fed by whichever route is connected:
/// Pi direct decodes on this iPad (`PiDirectViewModel.aprsStore`); the hub
/// route shows the Mac's lists (`RigClientViewModel.aprsList`).
struct APRSListPane: View {
    @Binding var kind: APRSListKind?
    let stations: [APRSStation]
    let messages: [APRSMessage]
    /// Pi direct: this iPad decodes, so it offers the decoder's settings
    /// and Clear History. Nil on the hub route (the Mac's Settings → APRS).
    let onClearHistory: (() -> Void)?

    @State private var sourceFilter: APRSSource?
    @State private var searchText = ""
    @State private var heardWindow: APRSHeardWindow = .any
    @State private var positionOnly = false
    @State private var addressedToMe = false
    @State private var hideBulletins = false
    @State private var hideTelemetry = false
    @State private var showingSettings = false
    @AppStorage(StationSettings.callsignKey) private var myCallsign = ""
    @AppStorage(APRSSettings.enabledKey) private var decodeEnabled = false
    @AppStorage(APRSSettings.frequencyHzKey) private var frequencyHz = APRSSettings.defaultFrequencyHz

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TextField(kind == .messages ? "Search callsign or message text" : "Search callsign or comment", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            if kind == .messages {
                messageTable
            } else {
                stationTable
            }
            footnote
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("List", selection: $kind) {
                Text("S.LIST").tag(APRSListKind?.some(.stations))
                Text("M.LIST").tag(APRSListKind?.some(.messages))
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            APRSSourcePicker(selection: $sourceFilter)
                .frame(maxWidth: 200)

            filterMenu

            Spacer()

            if onClearHistory != nil {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("APRS decoder settings")
                .popover(isPresented: $showingSettings) { decoderSettings }
            }

            Button {
                kind = nil
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(kind == .messages ? "Received Within" : "Heard Within", selection: $heardWindow) {
                ForEach(APRSHeardWindow.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if kind == .messages {
                Toggle(myBaseCallsign.isEmpty ? "Addressed to Me" : "Addressed to \(myBaseCallsign)",
                       isOn: $addressedToMe)
                    .disabled(myBaseCallsign.isEmpty)
                Toggle("Hide Bulletins", isOn: $hideBulletins)
                Toggle("Hide Telemetry Definitions", isOn: $hideTelemetry)
            } else {
                Toggle("With Position Only", isOn: $positionOnly)
            }
        } label: {
            Image(systemName: isFiltering
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter")
    }

    // MARK: - Lists

    private var stationTable: some View {
        Table(filteredStations) {
            TableColumn("Callsign") { station in
                Text(station.callsign).fontDesign(.monospaced)
            }
            TableColumn("Source") { station in
                Text(station.source == .main ? "Main" : "Sub")
            }
            .width(60)
            TableColumn("Position") { station in
                Text(Self.positionString(station))
            }
            TableColumn("Comment") { station in
                Text(station.comment ?? "")
            }
            TableColumn("Last Heard") { station in
                Text(station.lastHeardAt, style: .relative)
            }
        }
        .overlay {
            if stations.isEmpty {
                ContentUnavailableView("No Stations Heard", systemImage: "antenna.radiowaves.left.and.right", description: Text(emptyDescription(for: "stations")))
            } else if filteredStations.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var messageTable: some View {
        Table(filteredMessages) {
            TableColumn("From") { message in
                Text(message.from).fontDesign(.monospaced)
            }
            TableColumn("To") { message in
                Text(message.to).fontDesign(.monospaced)
            }
            TableColumn("Source") { message in
                Text(message.source == .main ? "Main" : "Sub")
            }
            .width(60)
            TableColumn("Message") { message in
                Text(message.text)
            }
            TableColumn("Received") { message in
                Text(message.receivedAt, style: .relative)
            }
        }
        .overlay {
            if messages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "envelope", description: Text(emptyDescription(for: "messages")))
            } else if filteredMessages.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func emptyDescription(for what: String) -> String {
        "Decoded APRS \(what) will appear here while tuned to \(Self.megahertz(frequencyHz)) MHz."
    }

    @ViewBuilder
    private var footnote: some View {
        if onClearHistory != nil {
            if !decodeEnabled {
                Text("APRS decoding is off — turn it on with the gear button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Decoded by the Mac — its Settings → APRS sets the frequency.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Decoder settings (Pi direct)

    private var decoderSettings: some View {
        Form {
            Toggle("Decode APRS", isOn: $decodeEnabled)
            LabeledContent("Frequency (MHz)") {
                TextField("MHz", value: megahertzBinding, format: .number.precision(.fractionLength(3)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            Text("Decodes MAIN or SUB while tuned within \(APRSSettings.toleranceHz / 1000) kHz of this frequency.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Clear History", role: .destructive) {
                onClearHistory?()
                showingSettings = false
            }
        }
        .frame(width: 380, height: 330)
    }

    private var megahertzBinding: Binding<Double> {
        Binding(
            get: { Double(frequencyHz) / 1_000_000 },
            set: { if $0 > 0 { frequencyHz = Int(($0 * 1_000_000).rounded()) } }
        )
    }

    private static func megahertz(_ hz: Int) -> String {
        String(format: "%.3f", Double(hz) / 1_000_000)
    }

    // MARK: - Filtering (as the Mac's list windows)

    private var myBaseCallsign: String {
        APRSListFilter.baseCallsign(myCallsign.trimmingCharacters(in: .whitespaces))
    }

    private var isFiltering: Bool {
        if kind == .messages {
            return heardWindow != .any || (addressedToMe && !myBaseCallsign.isEmpty) || hideBulletins || hideTelemetry
        }
        return heardWindow != .any || positionOnly
    }

    private var filteredStations: [APRSStation] {
        stations
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .filter { heardWindow.includes($0.lastHeardAt) }
            .filter { !positionOnly || ($0.latitude != nil && $0.longitude != nil) }
            .filter { APRSListFilter.matches(searchText, $0.callsign, $0.comment) }
            .sorted { $0.lastHeardAt > $1.lastHeardAt }
    }

    private var filteredMessages: [APRSMessage] {
        messages
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .filter { heardWindow.includes($0.receivedAt) }
            .filter { !addressedToMe || myBaseCallsign.isEmpty || APRSListFilter.baseCallsign($0.to) == myBaseCallsign }
            .filter { !hideBulletins || !APRSListFilter.isBulletin($0) }
            .filter { !hideTelemetry || !APRSListFilter.isTelemetryDefinition($0) }
            .filter { APRSListFilter.matches(searchText, $0.from, $0.to, $0.text) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    private static func positionString(_ station: APRSStation) -> String {
        guard let latitude = station.latitude, let longitude = station.longitude else { return "—" }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }
}

extension View {
    /// Shows `APRSListPane` over this view (the MENU grid) while `kind` is
    /// set, hiding — not removing — the view underneath so its page
    /// survives.
    func aprsListPane(kind: Binding<APRSListKind?>, stations: [APRSStation], messages: [APRSMessage], onClearHistory: (() -> Void)?) -> some View {
        let showing = kind.wrappedValue != nil
        return self
            .opacity(showing ? 0 : 1)
            .allowsHitTesting(!showing)
            .accessibilityHidden(showing)
            .overlay {
                if showing {
                    APRSListPane(kind: kind, stations: stations, messages: messages, onClearHistory: onClearHistory)
                }
            }
    }
}

/// Re-renders `content` whenever `store` changes — `APRSStore` is its own
/// `ObservableObject`, not part of the Pi-direct model's published state.
struct ObservingAPRSStore<Content: View>: View {
    @ObservedObject var store: APRSStore
    @ViewBuilder let content: (APRSStore) -> Content

    var body: some View {
        content(store)
    }
}

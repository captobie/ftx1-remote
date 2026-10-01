import FTX1Core
import SwiftUI

/// The FM/C4FM menu page's APRS M.LIST button opens this in its own
/// window (`aprs-messages`, declared in `FTX1RemoteMacApp`) — see
/// `APRSStationListView`'s doc comment for why a window rather than a
/// sheet.
struct APRSMessageListView: View {
    @EnvironmentObject private var store: APRSStore
    @State private var sourceFilter: APRSSource?
    @State private var searchText = ""
    @State private var heardWindow: APRSHeardWindow = .any
    @State private var addressedToMe = false
    @State private var hideBulletins = false
    @State private var hideTelemetry = false
    @AppStorage(StationSettings.callsignKey) private var myCallsign = ""

    var body: some View {
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
            TableColumn("Message") { message in
                Text(message.text)
            }
            TableColumn("Received") { message in
                Text(message.receivedAt, style: .relative)
            }
        }
        .navigationTitle("APRS Messages")
        .frame(minWidth: 520, minHeight: 300)
        .toolbar {
            ToolbarItem {
                APRSSourcePicker(selection: $sourceFilter)
            }
            ToolbarItem {
                Menu {
                    Picker("Received Within", selection: $heardWindow) {
                        ForEach(APRSHeardWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle(myBaseCallsign.isEmpty ? "Addressed to Me" : "Addressed to \(myBaseCallsign)",
                           isOn: $addressedToMe)
                        .disabled(myBaseCallsign.isEmpty)
                    Toggle("Hide Bulletins", isOn: $hideBulletins)
                    Toggle("Hide Telemetry Definitions", isOn: $hideTelemetry)
                    if myBaseCallsign.isEmpty {
                        Divider()
                        Text("Set your callsign in Settings → Station to filter messages addressed to you.")
                    }
                } label: {
                    Label("Filter", systemImage: isFiltering
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .help("Filter by time received, addressee, bulletins, and telemetry")
            }
        }
        .searchable(text: $searchText, prompt: "Callsign or message text")
        .overlay {
            if store.messages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "envelope", description: Text("Decoded APRS messages will appear here while tuned to the configured APRS frequency."))
            } else if filteredMessages.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var myBaseCallsign: String {
        APRSListFilter.baseCallsign(myCallsign.trimmingCharacters(in: .whitespaces))
    }

    private var isFiltering: Bool {
        heardWindow != .any || (addressedToMe && !myBaseCallsign.isEmpty) || hideBulletins || hideTelemetry
    }

    /// Any SSID of the operator's callsign counts — a message to N0CALL-7
    /// is still for this operator.
    private func isAddressedToMe(_ message: APRSMessage) -> Bool {
        !myBaseCallsign.isEmpty && APRSListFilter.baseCallsign(message.to) == myBaseCallsign
    }

    /// APRS bulletins and announcements are addressed "BLN0"–"BLNZ" plus
    /// optional group name (APRS 1.0.1, ch. 14).
    private static func isBulletin(_ message: APRSMessage) -> Bool {
        message.to.uppercased().hasPrefix("BLN")
    }

    /// Telemetry metadata ("PARM.", "UNIT.", "EQNS.", "BITS.") that a
    /// station sends as a message, usually to itself, to label its
    /// telemetry channels (APRS 1.0.1, ch. 13) — not a message for a human.
    private static func isTelemetryDefinition(_ message: APRSMessage) -> Bool {
        ["PARM.", "UNIT.", "EQNS.", "BITS."].contains { message.text.hasPrefix($0) }
    }

    private var filteredMessages: [APRSMessage] {
        store.messages
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .filter { heardWindow.includes($0.receivedAt) }
            .filter { !addressedToMe || myBaseCallsign.isEmpty || isAddressedToMe($0) }
            .filter { !hideBulletins || !Self.isBulletin($0) }
            .filter { !hideTelemetry || !Self.isTelemetryDefinition($0) }
            .filter { APRSListFilter.matches(searchText, $0.from, $0.to, $0.text) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }
}

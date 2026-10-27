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
            TableColumn("common.from") { message in
                Text(message.from).fontDesign(.monospaced)
            }
            TableColumn("common.to") { message in
                Text(message.to).fontDesign(.monospaced)
            }
            TableColumn("common.source") { message in
                Text(message.source == .main ? "Main" : "Sub")
            }
            TableColumn("common.message") { message in
                Text(message.text)
            }
            TableColumn("common.received") { message in
                Text(message.receivedAt, style: .relative)
            }
        }
        .navigationTitle("aprsMessageList.aprsMessages")
        .frame(minWidth: 520, minHeight: 300)
        .toolbar {
            ToolbarItem {
                APRSSourcePicker(selection: $sourceFilter)
            }
            ToolbarItem {
                Menu {
                    Picker("common.receivedWithin", selection: $heardWindow) {
                        ForEach(APRSHeardWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle(myBaseCallsign.isEmpty ? "common.addressedToMe" : "aprsMessageList.addressedTo \(myBaseCallsign)",
                           isOn: $addressedToMe)
                        .disabled(myBaseCallsign.isEmpty)
                    Toggle("common.hideBulletins", isOn: $hideBulletins)
                    Toggle("common.hideTelemetryDefinitions", isOn: $hideTelemetry)
                    if myBaseCallsign.isEmpty {
                        Divider()
                        Text("aprsMessageList.setYourCallsignIn")
                    }
                } label: {
                    Label("common.filter", systemImage: isFiltering
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .help("aprsMessageList.filterByTimeReceived")
            }
        }
        .searchable(text: $searchText, prompt: "aprsMessageList.callsignOrMessageText")
        .overlay {
            if store.messages.isEmpty {
                ContentUnavailableView("common.noMessages", systemImage: "envelope", description: Text("aprsMessageList.decodedAprsMessagesWill"))
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

    private var filteredMessages: [APRSMessage] {
        store.messages
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .filter { heardWindow.includes($0.receivedAt) }
            .filter { !addressedToMe || myBaseCallsign.isEmpty || isAddressedToMe($0) }
            .filter { !hideBulletins || !APRSListFilter.isBulletin($0) }
            .filter { !hideTelemetry || !APRSListFilter.isTelemetryDefinition($0) }
            .filter { APRSListFilter.matches(searchText, $0.from, $0.to, $0.text) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }
}

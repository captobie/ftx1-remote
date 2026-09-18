import FTX1Core
import SwiftUI

/// The FM/C4FM menu page's APRS M.LIST button opens this in its own
/// window (`aprs-messages`, declared in `FTX1RemoteMacApp`) — see
/// `APRSStationListView`'s doc comment for why a window rather than a
/// sheet.
struct APRSMessageListView: View {
    @EnvironmentObject private var store: APRSStore
    @State private var sourceFilter: APRSSource?

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
                Picker("Source", selection: $sourceFilter) {
                    Text("All").tag(APRSSource?.none)
                    Text("Main").tag(APRSSource?.some(.main))
                    Text("Sub").tag(APRSSource?.some(.sub))
                }
                .pickerStyle(.segmented)
            }
        }
        .overlay {
            if store.messages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "envelope", description: Text("Decoded APRS messages will appear here while tuned to the configured APRS frequency."))
            }
        }
    }

    private var filteredMessages: [APRSMessage] {
        store.messages
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .sorted { $0.receivedAt > $1.receivedAt }
    }
}

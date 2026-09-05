import FTX1Core
import SwiftUI

/// The FM/C4FM menu page's APRS M.LIST button opens this in its own
/// window (`aprs-messages`, declared in `FTX1RemoteMacApp`) — see
/// `APRSStationListView`'s doc comment for why a window rather than a
/// sheet.
struct APRSMessageListView: View {
    @EnvironmentObject private var store: APRSStore

    var body: some View {
        Table(store.messages.sorted { $0.receivedAt > $1.receivedAt }) {
            TableColumn("From") { message in
                Text(message.from).fontDesign(.monospaced)
            }
            TableColumn("To") { message in
                Text(message.to).fontDesign(.monospaced)
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
        .overlay {
            if store.messages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "envelope", description: Text("Decoded APRS messages will appear here while tuned to the configured APRS frequency."))
            }
        }
    }
}

import FTX1Core
import SwiftUI

/// The bottom bar of the APRS S.LIST/M.LIST windows: Beacon Now, the last
/// beacon's outcome, the next interval beacon, and whether a packet is
/// going out. Observes only the messaging and transmitter objects.
struct APRSTransmitBar: View {
    @EnvironmentObject private var messaging: APRSMessaging
    @EnvironmentObject private var transmitter: APRSTransmitter
    @AppStorage(APRSTransmitSettings.enabledKey) private var transmitOn = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            Button("aprsTransmit.beaconNow", systemImage: "dot.radiowaves.left.and.right") {
                messaging.beaconNow()
            }
            .disabled(!transmitOn)
            .help("aprsTransmit.beaconNowHelp")

            if transmitter.isTransmitting {
                Text("aprsTransmit.sending")
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
            }
            if !transmitOn {
                Text("aprsTransmit.offHint")
                    .foregroundStyle(.secondary)
                Button("aprsTransmit.openSettings") { openSettings() }
                    .buttonStyle(.link)
            } else if let status = messaging.beaconStatus {
                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(status)
            }
            Spacer()
            if transmitOn, let next = messaging.nextBeaconAt {
                Text("aprsTransmit.nextBeacon \(Text(next, style: .relative))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// New Message / Reply: addressee, text with a character count; Send
/// queues it through `APRSMessaging` (retried until acked).
struct APRSComposeSheet: View {
    @EnvironmentObject private var messaging: APRSMessaging
    @Environment(\.dismiss) private var dismiss
    @State var to: String
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("aprsCompose.title").font(.headline)
            Form {
                TextField("common.to", text: $to, prompt: Text(verbatim: "N0CALL-9"))
                    .fontDesign(.monospaced)
                    .onChange(of: to) { _, new in
                        let upper = String(new.uppercased().prefix(9))
                        if upper != new { to = upper }
                    }
                TextField("common.message", text: $text, axis: .vertical)
                    .lineLimit(2...4)
                    .focused($textFocused)
                    .onChange(of: text) { _, new in
                        if new.count > APRSOutgoing.maxMessageLength {
                            text = String(new.prefix(APRSOutgoing.maxMessageLength))
                        }
                    }
            }
            HStack {
                Text("aprsCompose.count \(text.count) \(APRSOutgoing.maxMessageLength)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
                Spacer()
                Button("common.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("aprsCompose.send") {
                    if let failure = messaging.send(text: text, to: to) {
                        problem = failure.message
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(to.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("aprsCompose.retryNote")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 440)
        .onAppear { if !to.isEmpty { textFocused = true } }
    }
}

extension APRSDelivery {
    /// The M.LIST Status column.
    var label: String {
        switch state {
        case .pending:
            if let note { return String(localized: "aprsDelivery.waiting \(note)") }
            return attempts == 0
                ? String(localized: "aprsDelivery.queued")
                : String(localized: "aprsDelivery.sent \(attempts) \(APRSMessaging.retryDelays.count)")
        case .acked: return String(localized: "aprsDelivery.acked")
        case .rejected: return String(localized: "aprsDelivery.rejected")
        case .failed:
            if let note { return String(localized: "aprsDelivery.failedReason \(note)") }
            return String(localized: "aprsDelivery.failed")
        case .cancelled: return String(localized: "aprsDelivery.cancelled")
        }
    }

    var color: Color {
        switch state {
        case .pending: .orange
        case .acked: .green
        case .rejected, .failed: .red
        case .cancelled: .secondary
        }
    }
}

/// Who a compose sheet is for (empty: New Message).
struct APRSComposeTarget: Identifiable {
    let id = UUID()
    var to: String
}

import FTX1Core
import SwiftUI

/// The Digital menu's "FT8" item opens this in its own window (`ft8`,
/// declared in `FTX1RemoteMacApp`), same pattern as the APRS S.LIST/M.LIST
/// windows. Unlike those, decoding is tied to this view's own lifecycle —
/// `.onAppear`/`.onDisappear` are the start/stop switch (see
/// `FT8DecodeCoordinator`'s doc comment for why FT8 can't reuse APRS's
/// always-on frequency gate).
struct FT8ListView: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var store: FT8Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            Table(store.spots.sorted { $0.utcTimestamp > $1.utcTimestamp }) {
                TableColumn("Time") { spot in
                    Text(spot.utcTimestamp, style: .time)
                }
                TableColumn("Freq (MHz)") { spot in
                    Text(String(format: "%.4f", spot.absoluteFrequencyHz / 1_000_000))
                        .fontDesign(.monospaced)
                }
                TableColumn("SNR") { spot in
                    Text(spot.snrDb > 0 ? "+\(spot.snrDb)" : "\(spot.snrDb)")
                }
                TableColumn("DT") { spot in
                    Text(String(format: "%+.1f", spot.dtSeconds))
                }
                TableColumn("Message") { spot in
                    Text(spot.messageText).fontDesign(.monospaced)
                }
                TableColumn("Callsign") { spot in
                    Text(spot.spottedCallsign ?? "")
                }
                TableColumn("Grid") { spot in
                    Text(spot.spottedGrid ?? "")
                }
            }
        }
        .navigationTitle("FT8")
        .frame(minWidth: 640, minHeight: 360)
        .overlay {
            if store.spots.isEmpty {
                ContentUnavailableView(
                    "No Decodes Yet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Decoded FT8 messages will appear here once tuned to an active FT8 sub-band.")
                )
            }
        }
        .onAppear { hub.startFT8Decoding() }
        .onDisappear { hub.stopFT8Decoding() }
    }

    /// `TimelineView` rather than a separate `Timer`/`@State` refresh loop
    /// — the idiomatic way to show a ticking countdown without extra
    /// plumbing.
    private var statusHeader: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                statusLabel
                Spacer()
                if let lastCycleCompletedAt = store.lastCycleCompletedAt {
                    Text("Last cycle \(lastCycleCompletedAt, style: .time)")
                        .foregroundStyle(.secondary)
                }
                Text("Next in \(Self.secondsUntilNextSlot(from: context.date))s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(8)
        }
    }

    private var statusLabel: some View {
        let text: String
        let color: Color
        switch store.cycleStatus {
        case .idle:
            text = "Idle"
            color = .secondary
        case .accumulating:
            text = "Receiving…"
            color = .blue
        case .decoding:
            text = "Decoding…"
            color = .orange
        }
        return Label(text, systemImage: "waveform").foregroundStyle(color)
    }

    private static func secondsUntilNextSlot(from date: Date, slotSeconds: Double = 15) -> Int {
        let phase = date.timeIntervalSince1970.truncatingRemainder(dividingBy: slotSeconds)
        return Int((slotSeconds - phase).rounded())
    }
}

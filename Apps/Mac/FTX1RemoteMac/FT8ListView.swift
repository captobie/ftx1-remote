import FTX1Core
import SwiftUI

/// The Tools menu's "FT8" item opens this in its own window (`ft8`,
/// declared in `FTX1RemoteMacApp`), same pattern as the APRS S.LIST/M.LIST
/// windows. Unlike those, decoding is tied to this view's own lifecycle —
/// `.onAppear`/`.onDisappear` are the start/stop switch (see
/// `FT8DecodeCoordinator`'s doc comment for why FT8 can't reuse APRS's
/// always-on frequency gate).
struct FT8ListView: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var store: FT8Store
    @EnvironmentObject private var pskReporter: PSKReporterUploader
    @AppStorage(StationSettings.callsignKey) private var myCallsign = ""
    @AppStorage(StationSettings.gridSquareKey) private var myGrid = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            pskReporterBar
            Divider()
            Table(store.spots.sorted { $0.utcTimestamp > $1.utcTimestamp }) {
                TableColumn("ft8List.time") { spot in
                    Text(spot.utcTimestamp, style: .time)
                }
                TableColumn("ft8List.freqMHz") { spot in
                    Text(FrequencyFormat.mhz(spot.absoluteFrequencyHz, fractionDigits: 4))
                        .fontDesign(.monospaced)
                }
                TableColumn("SNR") { spot in
                    Text(spot.snrDb > 0 ? "+\(spot.snrDb)" : "\(spot.snrDb)")
                }
                TableColumn("DT") { spot in
                    Text(String(format: "%+.1f", spot.dtSeconds))
                }
                TableColumn("common.message") { spot in
                    Text(spot.messageText).fontDesign(.monospaced)
                }
                TableColumn("common.callsign") { spot in
                    Text(spot.spottedCallsign ?? "")
                }
                TableColumn("ft8List.grid") { spot in
                    Text(spot.spottedGrid ?? "")
                }
            }
        }
        .navigationTitle("FT8")
        .frame(minWidth: 640, minHeight: 360)
        .overlay {
            if store.spots.isEmpty {
                ContentUnavailableView(
                    "ft8List.noDecodesYet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("ft8List.decodedFt8MessagesWill")
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
                    Text("ft8List.lastCycle \(lastCycleCompletedAt, style: .time)")
                        .foregroundStyle(.secondary)
                }
                Text("ft8List.nextInS \(Self.secondsUntilNextSlot(from: context.date))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(8)
        }
    }

    private var stationIsSet: Bool {
        !myCallsign.trimmingCharacters(in: .whitespaces).isEmpty
            && !myGrid.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The upload toggle and what it's doing. Without a callsign and grid
    /// in Settings → Station there's nothing to report as, so the toggle
    /// is disabled and says why.
    private var pskReporterBar: some View {
        HStack(spacing: 12) {
            Toggle("ft8List.uploadToPskReporter", isOn: $pskReporter.isEnabled)
                .toggleStyle(.checkbox)
                .disabled(!stationIsSet)
            Group {
                if !stationIsSet {
                    Text("ft8List.setYourCallsignAnd")
                } else if let error = pskReporter.lastError {
                    Text("ft8List.uploadFailed \(error)").foregroundStyle(.red)
                } else if pskReporter.isEnabled {
                    pskReporterStatus
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            if stationIsSet, let url = pskReporterMapURL {
                Link("ft8List.viewOnPskReporter", destination: url)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var pskReporterStatus: some View {
        var text = String(localized: "ft8List.pskQueuedSent \(pskReporter.pendingCount) \(pskReporter.sentThisSession)")
        if let last = pskReporter.lastUploadAt {
            text = String(localized: "ft8List.pskWithLastUpload \(text) \(last.formatted(date: .omitted, time: .shortened))")
        }
        if let next = pskReporter.nextUploadAt {
            text = String(localized: "ft8List.pskWithNextUpload \(text) \(next.formatted(date: .omitted, time: .shortened))")
        }
        return Text(text)
    }

    private var pskReporterMapURL: URL? {
        var components = URLComponents(string: "https://pskreporter.info/pskmap.html")
        components?.queryItems = [URLQueryItem(name: "callsign", value: myCallsign.trimmingCharacters(in: .whitespaces).uppercased())]
        return components?.url
    }

    private var statusLabel: some View {
        let text: String
        let color: Color
        switch store.cycleStatus {
        case .idle:
            text = String(localized: "ft8List.idle")
            color = .secondary
        case .accumulating:
            text = String(localized: "ft8List.receiving")
            color = .blue
        case .decoding:
            text = String(localized: "ft8List.decoding")
            color = .orange
        }
        return Label(text, systemImage: "waveform").foregroundStyle(color)
    }

    private static func secondsUntilNextSlot(from date: Date, slotSeconds: Double = 15) -> Int {
        let phase = date.timeIntervalSince1970.truncatingRemainder(dividingBy: slotSeconds)
        return Int((slotSeconds - phase).rounded())
    }
}

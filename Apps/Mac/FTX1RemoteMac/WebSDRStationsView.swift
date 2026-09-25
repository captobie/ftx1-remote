import SwiftUI

/// The WebSDR window's "Stations…" sheet: the public KiwiSDR list
/// (`KiwiSDRDirectoryView`, a native table) and classic WebSDRs
/// (`WebSDROrgBrowserView`, websdr.org itself — see there for why it isn't
/// a table). Either way, choosing a station only fills the host field;
/// connecting stays a separate, explicit Connect.
struct WebSDRStationsView: View {
    @ObservedObject var directory: KiwiSDRDirectory
    let rigFrequencyHz: Int?
    let favoriteIDs: Set<String>
    let onToggleFavorite: (KiwiSDRStation) -> Void
    let onChooseKiwi: (KiwiSDRStation) -> Void
    /// A station URL clicked in the websdr.org tab.
    let onChooseWebSDR: (URL) -> Void

    @AppStorage("webSDR.stationsTab") private var tab: SDRPlatform = .kiwiSDR

    var body: some View {
        VStack(spacing: 0) {
            Picker("Stations", selection: $tab) {
                ForEach(SDRPlatform.allCases, id: \.self) { platform in
                    Text(platform.displayName).tag(platform)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 10)
            .padding(.horizontal, 10)

            switch tab {
            case .kiwiSDR:
                KiwiSDRDirectoryView(directory: directory,
                                     rigFrequencyHz: rigFrequencyHz,
                                     favoriteIDs: favoriteIDs,
                                     onToggleFavorite: onToggleFavorite,
                                     onChoose: onChooseKiwi)
            case .webSDR:
                WebSDROrgTab(onChoose: onChooseWebSDR)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

/// websdr.org plus the sheet's footer for that tab.
private struct WebSDROrgTab: View {
    let onChoose: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reloadID = 0
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.top, 10)
            WebSDROrgBrowserView(reloadID: reloadID,
                                 onPick: { url in
                                     onChoose(url)
                                     dismiss()
                                 },
                                 onLoadFailure: { loadError = $0 })
            .overlay {
                if let loadError {
                    ContentUnavailableView("websdr.org Unavailable",
                                           systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text(loadError))
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("Click a station to use it · list shown by websdr.org")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reload", systemImage: "arrow.clockwise") {
                    loadError = nil
                    reloadID += 1
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
    }
}

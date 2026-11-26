import SwiftUI

/// The WebSDR window's "Stations…" sheet: the public KiwiSDR list
/// (`KiwiSDRDirectoryView`, a native table) and classic WebSDRs
/// (`WebSDROrgBrowserView`, websdr.org itself — see there for why it isn't
/// a table). Either way, choosing a station only fills the host field;
/// connecting stays a separate, explicit Connect.
public struct WebSDRStationsView: View {
    @ObservedObject public var directory: KiwiSDRDirectory
    public let rigFrequencyHz: Int?
    public let favoriteIDs: Set<String>
    public let onToggleFavorite: (KiwiSDRStation) -> Void
    public let onChooseKiwi: (KiwiSDRStation) -> Void
    /// A station URL clicked in the websdr.org tab.
    public let onChooseWebSDR: (URL) -> Void

    public init(directory: KiwiSDRDirectory, rigFrequencyHz: Int?, favoriteIDs: Set<String>,
                onToggleFavorite: @escaping (KiwiSDRStation) -> Void,
                onChooseKiwi: @escaping (KiwiSDRStation) -> Void,
                onChooseWebSDR: @escaping (URL) -> Void) {
        self.directory = directory
        self.rigFrequencyHz = rigFrequencyHz
        self.favoriteIDs = favoriteIDs
        self.onToggleFavorite = onToggleFavorite
        self.onChooseKiwi = onChooseKiwi
        self.onChooseWebSDR = onChooseWebSDR
    }

    @AppStorage("webSDR.stationsTab") private var tab: SDRPlatform = .kiwiSDR

    public var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "webSDRStations.stations", bundle: .module), selection: $tab) {
                // OpenWebRX has no public directory to browse — its host
                // (in practice the operator's own) is typed or a favorite.
                ForEach([SDRPlatform.kiwiSDR, .webSDR], id: \.self) { platform in
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
            case .webSDR, .openWebRX:
                WebSDROrgTab(onChoose: onChooseWebSDR)
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 560)
        #endif
    }
}

/// websdr.org plus the sheet's footer for that tab.
private struct WebSDROrgTab: View {
    public let onChoose: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reloadID = 0
    @State private var loadError: String?

    public var body: some View {
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
                    ContentUnavailableView(String(localized: "webSDRStations.websdrOrgUnavailable", bundle: .module),
                                           systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text(loadError))
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text(String(localized: "webSDRStations.clickAStationTo", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(String(localized: "webSDRStations.reload", bundle: .module), systemImage: "arrow.clockwise") {
                    loadError = nil
                    reloadID += 1
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                Button(String(localized: "common.cancel", bundle: .module)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
    }
}

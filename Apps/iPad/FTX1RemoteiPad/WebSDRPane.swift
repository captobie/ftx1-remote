import FTX1Core
import SwiftUI

/// The SDR pane's WebSDR side: the Mac's Tools → WebSDR window on the
/// shared `WebSDRFollowModel` — an embedded KiwiSDR, classic WebSDR or
/// OpenWebRX page (`KiwiWebView`, here a `UIViewRepresentable`) that
/// follows the rig and, with Tune rig, tunes it from the page. The rig side
/// goes through the route's view model (`SDRRigHost`), so MAIN is muted
/// while the page is audible, as on the Mac.
///
/// Same rules as the Mac window: opens disconnected (explicit Connect), a
/// station pick only fills the host, the Stations sheet's Kiwi list and
/// websdr.org tab and the favorites are the shared ones (this iPad's own
/// saved settings). No Record or Play here (the page's recorder saves into
/// the Mac's Recordings folder), and the page's audio can't be captured on
/// iOS, so nothing decodes it.
struct WebSDRPaneContent: View {
    @ObservedObject var model: WebSDRFollowModel
    @ObservedObject var directory: KiwiSDRDirectory

    /// The host field's edit, committed to `model.hostPort` on Return or
    /// Connect so a half-typed host never loads.
    @State private var hostDraft = ""
    @State private var showingDirectory = false
    @State private var showingManageFavorites = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hostRow
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            Divider()
            // Hidden rather than removed while disconnected: it has to stay
            // in the hierarchy to see `pageRequest` go nil and unload the
            // page (which closes the receiver's session).
            KiwiWebView(request: model.pageRequest,
                        pageBridge: model.pageBridge,
                        onLoadFailure: model.reportLoadFailure,
                        onPageLoaded: model.pageDidLoad)
                .opacity(model.isConnected ? 1 : 0)
                .overlay {
                    if !model.isConnected {
                        ContentUnavailableView(
                            "webSDRFollow.notConnected",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("webSDRFollow.pickAStationOr")
                        )
                    }
                }
                .frame(minHeight: 260, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                controlsRow
                Text(verbatim: model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
        }
        .sheet(isPresented: $showingDirectory) {
            NavigationStack {
                WebSDRStationsView(directory: directory,
                                   rigFrequencyHz: model.rigFrequencyHz,
                                   favoriteIDs: Set(model.favorites.map(\.id)),
                                   onToggleFavorite: model.toggleFavorite,
                                   onChooseKiwi: { model.select($0) },
                                   onChooseWebSDR: { model.selectWebSDR(hostPort: WebSDRFavorite.hostPort(from: $0)) })
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showingManageFavorites) {
            NavigationStack { WebSDRFavoritesView(model: model) }
        }
        .onAppear { hostDraft = model.hostPort }
        // A pick sets the committed host; mirror it into the field.
        .onChange(of: model.hostPort) { _, newHost in hostDraft = newHost }
        .onChange(of: directory.stations) { _, stations in model.fillInFavorites(from: stations) }
    }

    // MARK: - Rows

    private var hostRow: some View {
        HStack(spacing: 10) {
            Button {
                showingDirectory = true
            } label: {
                Label("webSDRFollow.stations", systemImage: "list.bullet")
            }
            .labelStyle(.iconOnly)
            favoritesMenu
            TextField("webSDRFollow.kiwiSDRWebSDROrOpenWebRX", text: $hostDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .fontDesign(.monospaced)
                .frame(maxWidth: 360)
                .onSubmit(commitHostAndConnect)
            favoriteToggle
            if model.isConnected {
                Button("common.disconnect", systemImage: "stop.circle", action: model.disconnect)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            } else {
                Button("common.connect", systemImage: "play.circle", action: commitHostAndConnect)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .disabled(KiwiSDRURLBuilder.baseURL(from: hostDraft) == nil)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .lineLimit(1)
    }

    /// Follow / Tune rig / Mute on TX and Mute: one row, or two in a
    /// narrower pane (the split screen).
    private var controlsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                toggles
                Spacer(minLength: 0)
                muteButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    followToggles
                }
                HStack(spacing: 18) {
                    muteOnTransmitToggle
                    Spacer(minLength: 0)
                    muteButton
                }
            }
        }
        .toggleStyle(.switch)
        .font(.callout)
    }

    @ViewBuilder
    private var toggles: some View {
        followToggles
        muteOnTransmitToggle
    }

    @ViewBuilder
    private var followToggles: some View {
        Toggle("webSDRFollow.followRig", isOn: $model.followRig)
            .fixedSize()
        Toggle("webSDRFollow.tuneRig", isOn: $model.tuneRig)
            .fixedSize()
    }

    private var muteOnTransmitToggle: some View {
        Toggle("webSDRFollow.muteOnTx", isOn: $model.muteOnTransmit)
            .fixedSize()
    }

    /// Mutes the page. While it's audible (connected, not muted) MAIN's
    /// audio is muted; muting here brings MAIN back.
    private var muteButton: some View {
        Button(action: model.toggleMuted) {
            Label(model.isMuted ? "webSDRFollow.muted" : "webSDRFollow.mute",
                  systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                .foregroundStyle(model.isMuted ? Color.white : Color.primary)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .tint(model.isMuted ? .red : nil)
        .fixedSize()
    }

    /// A saved station (fills the host, never connects), and Manage.
    private var favoritesMenu: some View {
        Menu {
            if model.favorites.isEmpty {
                Text("webSDRFollow.noFavoritesYetStar")
            } else {
                ForEach(model.favorites) { favorite in
                    Button {
                        model.select(favorite)
                    } label: {
                        if favorite.id == WebSDRFavorite.key(model.hostPort) {
                            Label(favorite.name, systemImage: "checkmark")
                        } else {
                            Text(verbatim: favorite.name)
                        }
                    }
                }
            }
            Divider()
            Button("webSDRFollow.manageFavorites") { showingManageFavorites = true }
                .disabled(model.favorites.isEmpty)
        } label: {
            Label("webSDRFollow.favorites", systemImage: "star")
        }
        .labelStyle(.iconOnly)
    }

    /// Saves or removes the committed host (what Connect would load).
    private var favoriteToggle: some View {
        let isFavorite = model.isFavorite(hostPort: model.hostPort)
        return Button {
            model.toggleFavoriteForCurrentHost(directoryStations: directory.stations)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(model.hostPort.isEmpty || hostDraft != model.hostPort)
        .accessibilityLabel(isFavorite ? "webSDRFollow.removeThisStationFrom" : "webSDRFollow.addThisStationTo")
    }

    /// Return in the field and Connect both land here, so an edited host
    /// is never ignored; Return while connected reloads.
    private func commitHostAndConnect() {
        hostDraft = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.hostPort = hostDraft
        model.connect()
    }
}

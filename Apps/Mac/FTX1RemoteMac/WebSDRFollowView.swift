import SwiftUI

/// The Digital menu's "WebSDR" item opens this in its own window
/// (`websdr-follow`, declared in `FTX1RemoteMacApp`): an embedded KiwiSDR
/// or classic WebSDR that retunes to follow the rig. Mac-only — see `WebSDRFollowModel` for
/// how it follows rig state and what's deliberately left for v1.1.
struct WebSDRFollowView: View {
    @StateObject private var model: WebSDRFollowModel
    /// The text field's in-progress edit; committed to `model.hostPort` on
    /// Return so a half-typed host never triggers a load.
    @State private var hostDraft: String
    /// Owned here (not per sheet presentation) so reopening the sheet shows
    /// the already-loaded list; its disk cache outlives the window anyway.
    @StateObject private var directory = KiwiSDRDirectory()
    @State private var showingDirectory = false
    @State private var showingManageFavorites = false
    @Environment(\.openWindow) private var openWindow

    init(hub: HubService) {
        let model = WebSDRFollowModel(hub: hub)
        _model = StateObject(wrappedValue: model)
        _hostDraft = State(initialValue: model.hostPort)
    }

    /// Return in the host field and the Connect button both land here, so
    /// an edited-but-uncommitted host is never silently ignored by Connect.
    /// Return while already connected reloads (e.g. to retry after an error).
    private func commitHostAndConnect() {
        hostDraft = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.hostPort = hostDraft
        model.connect()
    }

    /// Mutes the receiver page. While it's audible (connected, not muted here)
    /// the rig's Main audio is muted; muting here brings Main back — see
    /// `WebSDRFollowModel.isMuted`. Usable while disconnected too, to pick
    /// how the next connection starts.
    private var muteButton: some View {
        Button(action: model.toggleMuted) {
            Label(model.isMuted ? "Muted" : "Mute",
                  systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(model.isMuted ? .red : .primary)
        .help(model.isMuted
              ? "Unmute the WebSDR (mutes the rig's Main audio while connected)"
              : "Mute the WebSDR and bring back the rig's Main audio")
    }

    /// Picks a saved station (fills the host, never connects — same as a
    /// directory pick). Disabled-looking but still openable when empty, so
    /// Manage stays reachable.
    private var favoritesMenu: some View {
        Menu {
            if model.favorites.isEmpty {
                Text("No favorites yet — star a station")
            } else {
                // A Toggle is how a macOS menu item gets its checkmark (a
                // Label's icon is dropped); unchecking does nothing.
                ForEach(model.favorites) { favorite in
                    Toggle(favorite.name, isOn: Binding(
                        get: { favorite.id == WebSDRFavorite.key(model.hostPort) },
                        set: { _ in model.select(favorite) }
                    ))
                }
            }
            Divider()
            Button("Manage Favorites…") { showingManageFavorites = true }
                .disabled(model.favorites.isEmpty)
        } label: {
            Label("Favorites", systemImage: "star")
        }
        .fixedSize()
        .help("Choose a saved station")
    }

    /// Saves or removes the current host. Uses the committed host, not the
    /// field's draft, so it matches what Connect would load.
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
        .help(isFavorite ? "Remove this station from Favorites"
              : hostDraft != model.hostPort ? "Press Return to use this host, then add it to Favorites"
              : "Add this station to Favorites")
    }

    /// Record while connected; Stop (red, with the current file's elapsed
    /// time) while recording. The time is blank between files — saving,
    /// reloading after a retune, or waiting for the Kiwi's audio.
    @ViewBuilder
    private var recordButton: some View {
        if model.isRecording {
            Button(action: model.toggleRecording) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                    Text("Stop")
                    if let started = model.segmentStartedAt {
                        Text(started, style: .timer).monospacedDigit()
                    }
                }
            }
            .tint(.red)
            .foregroundStyle(.red)
            .help("Stop recording and save to Recordings")
        } else {
            Button("Record", systemImage: "record.circle", action: model.toggleRecording)
                .labelStyle(.titleAndIcon)
                .disabled(!model.isConnected)
                .help(model.isConnected ? "Record the WebSDR's audio" : "Connect to a station to record")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Stations…", systemImage: "list.bullet") { showingDirectory = true }
                    .labelStyle(.titleAndIcon)
                    .help("Choose a public KiwiSDR or WebSDR")
                favoritesMenu
                TextField("KiwiSDR or WebSDR host:port", text: $hostDraft)
                    .textFieldStyle(.roundedBorder)
                    .fontDesign(.monospaced)
                    .frame(maxWidth: 360)
                    .onSubmit(commitHostAndConnect)
                favoriteToggle
                if model.isConnected {
                    Button("Disconnect", systemImage: "stop.circle", action: model.disconnect)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Connect", systemImage: "play.circle", action: commitHostAndConnect)
                        .labelStyle(.titleAndIcon)
                        .disabled(KiwiSDRURLBuilder.baseURL(from: hostDraft) == nil)
                }
                Toggle("Follow rig", isOn: $model.followRig)
                    .toggleStyle(.switch)
                    .help("Retune the WebSDR when the rig's Main VFO changes")
                Toggle("Tune rig", isOn: $model.tuneRig)
                    .toggleStyle(.switch)
                    .help("Tune the rig's Main VFO when you tune in the WebSDR page (click the waterfall, enter a frequency, pick a mode)")
                Spacer()
                muteButton
                recordButton
                // Same window as the CW page's PLAY button: WebSDR/KiwiSDR
                // recordings are saved alongside the rig's own.
                Button("Play", systemImage: "waveform") { openWindow(id: "recordings") }
                    .labelStyle(.titleAndIcon)
                    .help("Open Recordings")
            }
            .padding(10)

            Divider()

            // Hidden rather than removed while disconnected: it has to stay in
            // the hierarchy to see `pageRequest` go nil and unload the Kiwi.
            KiwiWebView(request: model.pageRequest,
                        pageBridge: model.pageBridge,
                        onLoadFailure: model.reportLoadFailure,
                        onPageLoaded: model.pageDidLoad)
            .opacity(model.isConnected ? 1 : 0)
            .overlay {
                if !model.isConnected {
                    ContentUnavailableView(
                        "Not Connected",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Pick a station or enter a KiwiSDR or WebSDR host:port, then press Connect.")
                    )
                }
            }

            Divider()

            HStack(spacing: 12) {
                Text(model.status)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note = model.recordingNote {
                    Text(note)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .navigationTitle("WebSDR")
        .sheet(isPresented: $showingDirectory) {
            WebSDRStationsView(directory: directory,
                               rigFrequencyHz: model.rigFrequencyHz,
                               favoriteIDs: Set(model.favorites.map(\.id)),
                               onToggleFavorite: model.toggleFavorite,
                               onChooseKiwi: { model.select($0) },
                               onChooseWebSDR: { model.selectWebSDR(hostPort: WebSDRFavorite.hostPort(from: $0)) })
        }
        .sheet(isPresented: $showingManageFavorites) {
            WebSDRFavoritesView(model: model)
        }
        // `select` sets the committed host; mirror it into the field.
        .onChange(of: model.hostPort) { _, newHost in hostDraft = newHost }
        .onChange(of: directory.stations) { _, stations in model.fillInFavorites(from: stations) }
        // Closing the window ends the receiver session (see also
        // `KiwiWebView.dismantleNSView`, the backstop for the same thing).
        .onDisappear(perform: model.disconnect)
        .frame(minWidth: 800, minHeight: 560)
    }
}

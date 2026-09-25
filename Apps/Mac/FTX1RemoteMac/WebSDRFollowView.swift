import SwiftUI

/// The Digital menu's "WebSDR" item opens this in its own window
/// (`websdr-follow`, declared in `FTX1RemoteMacApp`): an embedded KiwiSDR
/// that retunes to follow the rig. Mac-only — see `WebSDRFollowModel` for
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
                .help(model.isConnected ? "Record the KiwiSDR's audio" : "Connect to a KiwiSDR to record")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Stations…", systemImage: "list.bullet") { showingDirectory = true }
                    .labelStyle(.titleAndIcon)
                    .help("Choose a public KiwiSDR from the directory")
                TextField("KiwiSDR host:port", text: $hostDraft)
                    .textFieldStyle(.roundedBorder)
                    .fontDesign(.monospaced)
                    .frame(maxWidth: 360)
                    .onSubmit(commitHostAndConnect)
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
                Spacer()
                recordButton
                // Same window as the CW page's PLAY button: KiwiSDR
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
                        recordingBridge: model.recordingBridge,
                        onLoadFailure: model.reportLoadFailure,
                        onPageLoaded: model.pageDidLoad)
            .opacity(model.isConnected ? 1 : 0)
            .overlay {
                if !model.isConnected {
                    ContentUnavailableView(
                        "Not Connected",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Pick a station or enter a KiwiSDR host:port, then press Connect.")
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
            KiwiSDRDirectoryView(directory: directory, rigFrequencyHz: model.rigFrequencyHz) { station in
                model.select(station)
            }
        }
        // `select` sets the committed host; mirror it into the field.
        .onChange(of: model.hostPort) { _, newHost in hostDraft = newHost }
        // Closing the window ends the Kiwi session (see also
        // `KiwiWebView.dismantleNSView`, the backstop for the same thing).
        .onDisappear(perform: model.disconnect)
        .frame(minWidth: 800, minHeight: 560)
    }
}

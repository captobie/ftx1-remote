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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
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
            }
            .padding(10)

            Divider()

            // Hidden rather than removed while disconnected: it has to stay in
            // the hierarchy to see `pageRequest` go nil and unload the Kiwi.
            KiwiWebView(request: model.pageRequest) { message in
                model.reportLoadFailure(message)
            }
            .opacity(model.isConnected ? 1 : 0)
            .overlay {
                if !model.isConnected {
                    ContentUnavailableView(
                        "Not Connected",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Enter a KiwiSDR host:port and press Connect.")
                    )
                }
            }

            Divider()

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .navigationTitle("WebSDR")
        // Closing the window ends the Kiwi session (see also
        // `KiwiWebView.dismantleNSView`, the backstop for the same thing).
        .onDisappear(perform: model.disconnect)
        .frame(minWidth: 800, minHeight: 560)
    }
}

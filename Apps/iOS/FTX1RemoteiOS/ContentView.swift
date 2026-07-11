import FTX1Core
import SwiftUI

/// Focused single-rig-control view (see repo root CLAUDE.md) — no attempt
/// to cram the Mac's dense multi-pane layout in here. Real VFO/mode/PTT
/// controls land once this skeleton is wired up further.
struct ContentView: View {
    @EnvironmentObject private var viewModel: RigClientViewModel
    @AppStorage("hubHost") private var host: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("FTX-1 Remote")
                .font(.title)

            if viewModel.connectionState != .connected {
                TextField("Mac hostname (Tailscale)", text: $host)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button("Connect") {
                    viewModel.connect(toHost: host)
                }
                .disabled(host.isEmpty)
            }

            Text(connectionLabel)
                .foregroundStyle(connectionColor)
                .onTapGesture {
                    if viewModel.connectionState == .connected {
                        viewModel.disconnect()
                    }
                }

            if viewModel.connectionState == .connected {
                FrequencyDisplay(
                    frequencyHz: viewModel.rigState.frequencyHz,
                    mode: viewModel.rigState.mode.displayName
                )
                if let swr = viewModel.rigState.swr {
                    Text("SWR \(swr, specifier: "%.2f")")
                        .font(.system(.body, design: .monospaced))
                }
                Text("Rig controls go here.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var connectionLabel: String {
        switch viewModel.connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private var connectionColor: Color {
        switch viewModel.connectionState {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .secondary
        case .failed: .red
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RigClientViewModel())
}

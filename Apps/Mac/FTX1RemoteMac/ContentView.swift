import FTX1Core
import SwiftUI

/// Placeholder for the dense multi-pane control UI (VFO, meters, band/mode
/// selectors all visible at once — see repo root CLAUDE.md). Real panes
/// land once RigctldClient/CommandQueue are wired into HubService.
struct ContentView: View {
    @EnvironmentObject private var hub: HubService

    var body: some View {
        VStack(spacing: 16) {
            Text("FTX-1 Remote")
                .font(.title)
            Text(connectionLabel)
                .foregroundStyle(connectionColor)
            Text("\(hub.rigState.frequencyHz) Hz — \(hub.rigState.mode.rawValue)")
                .font(.system(.body, design: .monospaced))
            if let swr = hub.rigState.swr {
                Text("SWR \(swr, specifier: "%.2f")")
                    .font(.system(.body, design: .monospaced))
            }
            Text("Dense multi-pane control UI goes here.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }

    private var connectionLabel: String {
        switch hub.connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting to rigctld…"
        case .connected: "Connected to rigctld"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private var connectionColor: Color {
        switch hub.connectionState {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .secondary
        case .failed: .red
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(HubService())
}

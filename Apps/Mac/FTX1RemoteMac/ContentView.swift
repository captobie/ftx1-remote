import FTX1Core
import SwiftUI

/// Dense multi-pane control UI (see repo root CLAUDE.md) — still growing.
/// Band selectors and mode switching still need to land here.
struct ContentView: View {
    @EnvironmentObject private var hub: HubService
    @State private var showingSettings = false
    @State private var isDraggingPower = false
    @State private var localPowerLevel: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FTX-1 Remote")
                .font(.title)

            HStack {
                Toggle("rigctld", isOn: rigctldToggleBinding)
                Text(rigctldProcessLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") { showingSettings = true }
            }

            Text(connectionLabel)
                .foregroundStyle(connectionColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("VFO (active): \(hub.rigState.frequencyHz) Hz — \(hub.rigState.mode.rawValue)")
                    .font(.system(.body, design: .monospaced))
                if let secondaryHz = hub.rigState.secondaryFrequencyHz {
                    Text("VFO (other): \(secondaryHz) Hz")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let swr = hub.rigState.swr {
                Text("SWR \(swr, specifier: "%.2f")")
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Power: \(Int(displayedPowerLevel * 100))%")
                Slider(
                    value: Binding(
                        get: { displayedPowerLevel },
                        set: { localPowerLevel = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            localPowerLevel = hub.rigState.powerLevel ?? 0
                            isDraggingPower = true
                        } else {
                            isDraggingPower = false
                            hub.send(.setPowerLevel(localPowerLevel))
                        }
                    }
                )
            }

            Text("Band/mode selectors go here.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private var displayedPowerLevel: Double {
        isDraggingPower ? localPowerLevel : (hub.rigState.powerLevel ?? 0)
    }

    private var rigctldToggleBinding: Binding<Bool> {
        Binding(
            get: { hub.rigctldProcessState == .running || hub.rigctldProcessState == .starting },
            set: { isOn in
                if isOn {
                    hub.startRigctld()
                } else {
                    hub.stopRigctld()
                }
            }
        )
    }

    private var rigctldProcessLabel: String {
        switch hub.rigctldProcessState {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .failed(let message): "Failed: \(message)"
        }
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

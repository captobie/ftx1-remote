import FTX1Core
import SwiftUI

/// Dense multi-pane control UI (see repo root CLAUDE.md) — still growing.
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

            HStack(spacing: 12) {
                VFODisplayBox(label: "VFO A", frequencyHz: hub.rigState.frequencyHz, isActive: true)
                VFODisplayBox(label: "VFO B", frequencyHz: hub.rigState.secondaryFrequencyHz, isActive: false)
            }
            Text(hub.rigState.mode.rawValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

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

            HStack(spacing: 16) {
                Picker("Band", selection: bandBinding) {
                    ForEach(BandPlan.all, id: \.name) { band in
                        Text(band.name).tag(band.name)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)

                Picker("Mode", selection: modeBinding) {
                    ForEach(RigMode.allCases.filter { $0 != .unknown }, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
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

    /// Falls back to the first band in the plan if the active frequency
    /// isn't within any known band (e.g. rigctld hasn't reported yet).
    private var bandBinding: Binding<String> {
        Binding(
            get: { hub.rigState.band ?? BandPlan.all.first?.name ?? "" },
            set: { hub.send(.setBand($0)) }
        )
    }

    private var modeBinding: Binding<RigMode> {
        Binding(
            get: { hub.rigState.mode },
            set: { hub.send(.setMode($0)) }
        )
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

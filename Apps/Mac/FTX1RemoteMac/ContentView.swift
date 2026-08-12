import FTX1Core
import SwiftUI

/// Dense multi-pane control UI (see repo root CLAUDE.md) — still growing.
struct ContentView: View {
    @EnvironmentObject private var hub: HubService
    @State private var showingSettings = false
    @State private var isDraggingPower = false
    @State private var localPowerLevel: Double = 0
    @State private var isPTTPressed = false

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
                VFODisplayBox(label: "VFO A", frequencyHz: hub.rigState.frequencyHz, isActive: true, mode: hub.rigState.mode.displayName)
                VFODisplayBox(label: "VFO B", frequencyHz: hub.rigState.secondaryFrequencyHz, isActive: false, mode: hub.rigState.secondaryMode?.displayName ?? "—")
            }

            Text(swrLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(hub.rigState.swr == nil ? .secondary : .primary)

            pttButton

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

            MenuPageView()
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 360)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    /// Momentary press-and-hold, not a toggle — keys on press-down and
    /// unkeys on release, matching how PTT actually works. A plain
    /// `Button` only fires on release, so this uses a zero-distance
    /// `DragGesture` instead (fires `onChanged` immediately on press,
    /// `onEnded` on release; works the same for a mouse click as it does
    /// for touch). `isPTTPressed` guards against sending `.setPTT(true)`
    /// repeatedly while `onChanged` keeps firing during the hold.
    private var pttButton: some View {
        Text(hub.rigState.ptt ? "TRANSMITTING" : "PTT")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(hub.rigState.ptt ? Color.red : Color.gray.opacity(0.25))
            .foregroundStyle(hub.rigState.ptt ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPTTPressed else { return }
                        isPTTPressed = true
                        hub.send(.setPTT(true))
                    }
                    .onEnded { _ in
                        isPTTPressed = false
                        hub.send(.setPTT(false))
                    }
            )
    }

    /// Reserves the SWR row's height even before there's a reading (rather
    /// than omitting the row via `if let`), so the window's total content
    /// height — fixed once the disconnected layout first appears — doesn't
    /// grow on connect and squeeze the frequency digits' `minimumScaleFactor`
    /// down to fit.
    private var swrLabel: String {
        guard let swr = hub.rigState.swr else { return "SWR --" }
        return String(format: "SWR %.2f", swr)
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

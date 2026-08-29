import FTX1Core
import SwiftUI

/// Dense multi-pane control UI (see repo root CLAUDE.md) — still growing.
struct ContentView: View {
    @EnvironmentObject private var hub: HubService
    @State private var showingSettings = false
    @State private var isPTTPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                connectButton
                Text(rigctldProcessLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") { showingSettings = true }
            }

            HStack(spacing: 12) {
                VFODisplayBox(label: "VFO A", frequencyHz: hub.rigState.frequencyHz, isActive: true, mode: hub.rigState.mode.displayName)
                VFODisplayBox(label: "VFO B", frequencyHz: hub.rigState.secondaryFrequencyHz, isActive: false, mode: hub.rigState.secondaryMode?.displayName ?? "—")
            }

            HStack(alignment: .bottom, spacing: 12) {
                SMeterView(smeterDb: hub.rigState.smeterDb, swr: hub.rigState.swr, ptt: hub.rigState.ptt)
                    .frame(width: 280)
                Text(swrLabel)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(hub.rigState.swr == nil ? .secondary : .primary)
            }

            pttButton

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

            MenuPageView<HubService>()
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

    /// Replaces the old rigctld on/off `Toggle` with a button whose label
    /// and color reflect `connectionState` (what the user actually cares
    /// about — is the app talking to the rig), while its tap action still
    /// starts/stops the rigctld process itself, same as the toggle did.
    private var connectButton: some View {
        Button {
            if isRigctldActive {
                hub.stopRigctld()
            } else {
                hub.startRigctld()
            }
        } label: {
            Text(hub.connectionState == .connected ? "Disconnect" : "Connect")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(hub.connectionState == .connected ? Color.green : Color.red)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var isRigctldActive: Bool {
        hub.rigctldProcessState == .running || hub.rigctldProcessState == .starting
    }

    private var rigctldProcessLabel: String {
        switch hub.rigctldProcessState {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .failed(let message): "Failed: \(message)"
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(HubService())
}

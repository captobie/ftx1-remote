import FTX1Core
import SwiftUI

/// Dense multi-pane control UI, modeled on the Mac's `ContentView` rather
/// than iPhone's single-focus flow (see repo root CLAUDE.md) — VFO A/B,
/// meters, and band/mode selectors all visible together, plus the numbered
/// `MenuPageView` grid. Unlike the Mac, this is a WebSocket client only
/// (`RigClientViewModel`), never touches `RigctldClient` directly.
struct ContentView: View {
    @EnvironmentObject private var viewModel: RigClientViewModel
    @AppStorage("hubHost") private var host: String = ""
    @State private var isDraggingPower = false
    @State private var localPowerLevel: Double = 0
    @State private var isPTTPressed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if viewModel.connectionState != .connected {
                        TextField("Mac hostname (Tailscale)", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    connectButton
                }

                HStack(spacing: 12) {
                    VFODisplayBox(label: "VFO A", frequencyHz: viewModel.rigState.frequencyHz, isActive: true, mode: viewModel.rigState.mode.displayName, onSetFrequency: { viewModel.send(.setFrequency(hz: $0)) })
                    vfoSwapButton
                    VFODisplayBox(label: "VFO B", frequencyHz: viewModel.rigState.secondaryFrequencyHz, isActive: false, mode: viewModel.rigState.secondaryMode?.displayName ?? "—", onSetFrequency: { viewModel.send(.setSecondaryFrequency(hz: $0)) })
                }

                HStack(alignment: .bottom, spacing: 12) {
                    SMeterView(smeterDb: viewModel.rigState.smeterDb, swr: viewModel.rigState.swr, ptt: viewModel.rigState.ptt)
                        .frame(width: 280)
                    Text(swrLabel)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(viewModel.rigState.swr == nil ? .secondary : .primary)
                }

                pttButton

                VStack(alignment: .leading, spacing: 4) {
                    Text("Power: \(Int(displayedPowerLevel * 100))W")
                    Slider(
                        value: Binding(
                            get: { displayedPowerLevel },
                            set: { localPowerLevel = $0 }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if editing {
                                localPowerLevel = viewModel.rigState.powerLevel ?? 0
                                isDraggingPower = true
                            } else {
                                isDraggingPower = false
                                viewModel.send(.setPowerLevel(localPowerLevel))
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
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                MenuPageView<RigClientViewModel>()
            }
            .padding(32)
        }
    }

    /// Swaps which of Main/Sub is the active VFO — the rig's own physical
    /// A/B button, over CAT. See Mac `ContentView`'s identical button for
    /// why no other display logic is needed.
    private var vfoSwapButton: some View {
        Button {
            viewModel.send(.swapActiveVFO)
        } label: {
            Image(systemName: "arrow.left.arrow.right")
        }
        .buttonStyle(.bordered)
    }

    /// Momentary press-and-hold, not a toggle — same `DragGesture` pattern
    /// as Mac/iOS (see their `ContentView`s): keys on touch-down, unkeys on
    /// release, matching how PTT actually works.
    private var pttButton: some View {
        Text(viewModel.rigState.ptt ? "TRANSMITTING" : "PTT")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(viewModel.rigState.ptt ? Color.red : Color.gray.opacity(0.25))
            .foregroundStyle(viewModel.rigState.ptt ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPTTPressed else { return }
                        isPTTPressed = true
                        viewModel.send(.setPTT(true))
                    }
                    .onEnded { _ in
                        isPTTPressed = false
                        viewModel.send(.setPTT(false))
                    }
            )
    }

    /// Replaces the old "Connect" button + separate tap-to-disconnect
    /// status text with a single button whose label and color reflect
    /// `connectionState`, same pattern as Mac's `ContentView`.
    private var connectButton: some View {
        Button {
            if viewModel.connectionState == .connected {
                viewModel.disconnect()
            } else {
                viewModel.connect(toHost: host)
            }
        } label: {
            Text(viewModel.connectionState == .connected ? "Connected" : "Disconnected")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(viewModel.connectionState == .connected ? Color.green : Color.red)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.connectionState != .connected && host.isEmpty)
    }

    private var swrLabel: String {
        guard let swr = viewModel.rigState.swr else { return "SWR --" }
        return String(format: "SWR %.2f", swr)
    }

    private var displayedPowerLevel: Double {
        isDraggingPower ? localPowerLevel : (viewModel.rigState.powerLevel ?? 0)
    }

    /// Falls back to the first band in the plan if the active frequency
    /// isn't within any known band (e.g. not connected yet) — same as Mac's
    /// `ContentView`.
    private var bandBinding: Binding<String> {
        Binding(
            get: { viewModel.rigState.band ?? BandPlan.all.first?.name ?? "" },
            set: { viewModel.send(.setBand($0)) }
        )
    }

    private var modeBinding: Binding<RigMode> {
        Binding(
            get: { viewModel.rigState.mode },
            set: { viewModel.send(.setMode($0)) }
        )
    }

}

#Preview {
    ContentView()
        .environmentObject(RigClientViewModel())
}

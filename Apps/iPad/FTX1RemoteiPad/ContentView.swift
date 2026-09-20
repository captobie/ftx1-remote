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
    @AppStorage(AudioPlaybackSettings.volumeKey) private var mainAudioVolume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.squelchThresholdKey) private var mainAudioSquelchThreshold: Double = 0.015
    @AppStorage(AudioPlaybackSettings.subVolumeKey) private var subAudioVolume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.subSquelchThresholdKey) private var subAudioSquelchThreshold: Double = 0.015
    @State private var isDraggingPower = false
    @State private var localPowerLevel: Double = 0
    @State private var isPTTPressed = false

    /// Upper bound of the squelch slider's *displayed* range — see the
    /// Mac's identical constant/doc comment in its own `ContentView`.
    private static let squelchDisplayRange: Double = 0.05

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
                    VFODisplayBox(label: "SUB", frequencyHz: viewModel.rigState.secondaryFrequencyHz, isActive: viewModel.rigState.singleReceive != true, mode: viewModel.rigState.secondaryMode?.displayName ?? "—", txRxLabel: "RX", callsign: viewModel.rigState.secondaryMode == .c4fm ? viewModel.rigState.c4fmCallsign : (viewModel.rigState.aprsSubActive ? viewModel.rigState.aprsSubLastCallsign : nil), reflector: viewModel.rigState.secondaryMode == .c4fm ? viewModel.rigState.c4fmReflector : nil, aprsActive: viewModel.rigState.aprsSubActive, onSetFrequency: { viewModel.send(.setSecondaryFrequency(hz: $0)) })
                    vfoSwapButton
                    VFODisplayBox(label: "MAIN", frequencyHz: viewModel.rigState.frequencyHz, isActive: true, mode: viewModel.rigState.mode.displayName, txRxLabel: viewModel.rigState.splitEnabled == true ? "RX" : "TXRX", callsign: viewModel.rigState.mode == .c4fm ? viewModel.rigState.c4fmCallsign : (viewModel.rigState.aprsActive ? viewModel.rigState.aprsLastCallsign : nil), reflector: viewModel.rigState.mode == .c4fm ? viewModel.rigState.c4fmReflector : nil, aprsActive: viewModel.rigState.aprsActive, onSetFrequency: { viewModel.send(.setFrequency(hz: $0)) })
                }

                HStack(alignment: .bottom, spacing: 12) {
                    SMeterView(smeterDb: viewModel.rigState.smeterDb, swr: viewModel.rigState.swr, ptt: viewModel.rigState.ptt, powerWatts: viewModel.rigState.powerWatts, txMeters: viewModel.rigState.txMeters)
                        .frame(width: 280)
                    Text(swrLabel)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(viewModel.rigState.swr == nil ? .secondary : .primary)
                    audioControls
                        .frame(maxWidth: .infinity)
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
                        Section("Amateur") {
                            ForEach(BandPlan.all, id: \.name) { band in
                                Text(band.name).tag(band.name)
                            }
                        }
                        Section("Broadcast") {
                            ForEach(GeneralCoverageSegments.all.filter { $0.category == .broadcast }, id: \.name) { segment in
                                Text(segment.name).tag(segment.name)
                            }
                        }
                        Section("Utility") {
                            ForEach(GeneralCoverageSegments.all.filter { $0.category == .utility }, id: \.name) { segment in
                                Text(segment.name).tag(segment.name)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)

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

    /// Volume + "virtual" squelch + mute (a client-side noise gate on the
    /// relayed audio — see `AudioPlaybackEngine`/`SquelchGate` —
    /// independent of the rig's own hardware squelch) for the Mac's
    /// relayed radio audio, one column per channel. Occupies the free
    /// trailing space in the SMeterView row, the iPad's analog of where the
    /// Mac's `ScopeDisplayView` sits in its own `ContentView`. Volume/
    /// squelch are bound to `AudioPlaybackSettings` directly via
    /// `@AppStorage` — these never touch `RigCommand`/the rig, so unlike
    /// the power slider they don't need a drag-commit-on-release pattern,
    /// local audio settings can update live. Mute lives on
    /// `viewModel` instead (see `RigClientViewModel.isMainAudioMuted`/
    /// `isSubAudioMuted`) since it has to gate whether incoming relayed
    /// audio gets pushed to the playback engine at all, not just adjust a
    /// setting. Sub column added 2026-09-18, mirroring the Mac's — see repo
    /// CLAUDE.md, "Dual Main/Sub audio channels".
    private var audioControls: some View {
        HStack(alignment: .top, spacing: 16) {
            channelAudioControls(
                label: "SUB",
                volume: $subAudioVolume,
                squelchThreshold: $subAudioSquelchThreshold,
                isMuted: viewModel.isSubAudioMuted,
                engine: viewModel.subAudioEngine,
                onToggleMute: viewModel.toggleSubAudioMuted
            )
            channelAudioControls(
                label: "MAIN",
                volume: $mainAudioVolume,
                squelchThreshold: $mainAudioSquelchThreshold,
                isMuted: viewModel.isMainAudioMuted,
                engine: viewModel.audioEngine,
                onToggleMute: viewModel.toggleMainAudioMuted
            )
        }
    }

    /// One channel's worth of `audioControls` — see its doc comment.
    /// `engine` is written to directly on every slider change (not routed
    /// back through `RigClientViewModel`) since `AudioPlaybackEngine` is a
    /// reference type owned by the view model already, same pattern the
    /// pre-Sub single-channel version used for `viewModel.audioEngine`.
    private func channelAudioControls(
        label: String,
        volume: Binding<Double>,
        squelchThreshold: Binding<Double>,
        isMuted: Bool,
        engine: AudioPlaybackEngine,
        onToggleMute: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onToggleMute) {
                    Text(isMuted ? "Muted" : "Mute")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isMuted ? Color.red : Color.gray.opacity(0.2))
                        .foregroundStyle(isMuted ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            Text("Volume")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: volume, in: 0...1)
                .onChange(of: volume.wrappedValue) { _, newValue in
                    engine.volume = Float(newValue)
                }
            Text("Squelch")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // `SquelchGate.threshold` is now "how close to true silence
            // counts as quieting" — smaller is stricter (see its doc
            // comment). Inverted here so dragging up still tightens the
            // squelch, matching a normal radio's knob and the Mac's own
            // slider — see its `squelchBinding` doc comment.
            Slider(
                value: Binding(
                    get: { Self.squelchDisplayRange - squelchThreshold.wrappedValue },
                    set: { squelchThreshold.wrappedValue = Self.squelchDisplayRange - $0 }
                ),
                in: 0...Self.squelchDisplayRange
            )
            .onChange(of: squelchThreshold.wrappedValue) { _, newValue in
                engine.squelchThreshold = Float(newValue)
            }
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

    /// Mirrors `HubService.send(_:)`'s TX gate (transmit-enabled toggle AND
    /// inside an amateur allocation) so the button visibly reflects why a
    /// press won't do anything — the real enforcement happens on the Mac
    /// hub regardless, since every command here goes out over the
    /// WebSocket, but a silent no-op with no visual cue would be confusing.
    private var canTransmit: Bool {
        viewModel.rigState.transmitEnabled && BandPlan.band(containing: viewModel.rigState.frequencyHz) != nil
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
            .opacity(canTransmit ? 1 : 0.4)
            .help(
                viewModel.rigState.transmitEnabled
                    ? (canTransmit ? "" : "Transmit disabled: outside an amateur band")
                    : "Transmit disabled"
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPTTPressed, canTransmit else { return }
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

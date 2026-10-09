import FTX1Core
import SwiftUI

/// The iPad's Pi-direct proof-of-concept screen (see `PiDirectViewModel`):
/// a cut-down `HubControlView` — SUB/MAIN `VFODisplayBox`es (showing
/// everything the Mac's do except APRS: TX/RX tags, memory channel + tag,
/// scan state, SUB dimmed in single receive, and — with a WPSD host set —
/// the C4FM callsign/reflector), a meter + audio `ChannelStrip` under
/// each. Tapping a box's frequency tunes it and sets its mode (VFO mode)
/// or picks a memory channel from the list (Memory mode), MAIN and SUB
/// alike — not while the rig is scanning (see `PiDirectViewModel.send`).
///
/// The top row adds, once connected, the memory scan (`MemoryScanButtons`),
/// V/M (MAIN only), the Mac's swap (`SV`) and audio-channel override
/// (speaker, orange while swapped) — the model tracks the audio parity
/// across swaps like `HubService`.
///
/// Transmit (2026-10-09): hold-to-talk `PTTButton` right of Connected,
/// with the iPad's microphone streamed to the Pi's TX audio service, and a
/// lock button beside it — this route's own Enable Transmit (off by
/// default), since the Mac's toggle isn't in the path. Still no power,
/// band picker or `MenuPageView`: those depend on `HubService`
/// translating/gating commands, which this path bypasses.
///
/// Unlike the iPhone's `PiDirectView` (single focused VFO, Main audio
/// only), this shows both receivers, as the hub screen does.
struct PiDirectView: View {
    @EnvironmentObject private var viewModel: PiDirectViewModel
    @AppStorage("piHost") private var host: String = "ftx1pi"
    /// This device's own copy of the Mac's WPSD host key; empty = no C4FM
    /// callsign/reflector lookup.
    @AppStorage(WPSDSettings.hostKey) private var wpsdHost: String = ""
    @AppStorage(AudioPlaybackSettings.volumeKey) private var mainAudioVolume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.squelchThresholdKey) private var mainAudioSquelchThreshold: Double = 0.015
    @AppStorage(AudioPlaybackSettings.subVolumeKey) private var subAudioVolume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.subSquelchThresholdKey) private var subAudioSquelchThreshold: Double = 0.015
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if viewModel.connectionState != .connected {
                        TextField("Pi hostname (Tailscale)", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("WPSD hotspot (optional, C4FM callsign)", text: $wpsdHost)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    connectButton
                    if viewModel.connectionState == .connected {
                        PTTButton(
                            isTransmitting: viewModel.isTransmitting || viewModel.rigState.ptt,
                            blockReason: viewModel.transmitBlockReason,
                            onPress: viewModel.startTransmit,
                            onRelease: viewModel.stopTransmit
                        )
                        transmitEnableButton
                        Spacer()
                        rigButtons
                    }
                }

                if viewModel.connectionState == .connected, let problem = viewModel.transmitProblem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if case .failed(let message) = viewModel.connectionState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.connectionState == .connected {
                    connectedContent
                }
            }
            .padding(32)
        }
        // A press can't be released from the background; don't stay keyed.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stopTransmit() }
        }
    }

    /// This route's Enable Transmit: locked (gray) blocks PTT; unlocked
    /// (red) allows it. Persisted by the model, off on first use.
    private var transmitEnableButton: some View {
        Button {
            viewModel.transmitEnabled.toggle()
        } label: {
            Image(systemName: viewModel.transmitEnabled ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(viewModel.transmitEnabled ? Color.white : Color.primary)
        }
        .buttonStyle(.bordered)
        .tint(viewModel.transmitEnabled ? .red : nil)
        .accessibilityLabel(viewModel.transmitEnabled ? "Transmit enabled; tap to disable" : "Transmit disabled; tap to enable")
    }

    @ViewBuilder
    private var connectedContent: some View {
        let state = viewModel.rigState
        // No editing while the rig scans — see `PiDirectViewModel.send`.
        let editable = state.memoryScan != .scanning && state.memoryScan != .paused
        HStack(spacing: 12) {
            // Same arguments as the hub screen's boxes, minus APRS (no
            // decoder on this route).
            VFODisplayBox(
                label: "SUB",
                frequencyHz: state.secondaryFrequencyHz,
                isActive: state.singleReceive != true,
                mode: state.secondaryMode?.displayName ?? "—",
                txRxLabel: state.subTxRxLabel,
                callsign: state.secondaryMode == .c4fm ? state.c4fmCallsign : nil,
                reflector: state.secondaryMode == .c4fm ? state.c4fmReflector : nil,
                onSetFrequency: editable ? { viewModel.send(.setSecondaryFrequency(hz: $0)) } : nil,
                vfoMemoryMode: state.subVfoMemoryMode,
                memoryChannel: state.subMemoryChannel,
                memoryChannelTag: state.subMemoryChannelTag,
                onSetMemoryChannel: editable ? { viewModel.send(.setSubMemoryChannel($0)) } : nil,
                onStepMemoryChannel: editable ? { viewModel.send(.stepSubMemoryChannel(up: $0)) } : nil,
                memoryScan: state.memoryScan(on: .sub),
                currentMode: state.secondaryMode,
                onSetMode: { viewModel.send(.setSecondaryMode($0)) },
                memoryList: viewModel.memoryListSnapshot,
                onRefreshMemoryList: { viewModel.send(.refreshMemoryList) }
            )
            VFODisplayBox(
                label: "MAIN",
                frequencyHz: state.frequencyHz,
                isActive: true,
                mode: state.mode.displayName,
                txRxLabel: state.mainTxRxLabel,
                callsign: state.mode == .c4fm ? state.c4fmCallsign : nil,
                reflector: state.mode == .c4fm ? state.c4fmReflector : nil,
                onSetFrequency: editable ? { viewModel.send(.setFrequency(hz: $0)) } : nil,
                vfoMemoryMode: state.vfoMemoryMode,
                memoryChannel: state.memoryChannel,
                memoryChannelTag: state.memoryChannelTag,
                onSetMemoryChannel: editable ? { viewModel.send(.setMemoryChannel($0)) } : nil,
                onStepMemoryChannel: editable ? { viewModel.send(.stepMemoryChannel(up: $0)) } : nil,
                memoryScan: state.memoryScan(on: .main),
                currentMode: state.mode,
                onSetMode: { viewModel.send(.setMode($0)) },
                memoryList: viewModel.memoryListSnapshot,
                onRefreshMemoryList: { viewModel.send(.refreshMemoryList) }
            )
        }

        // Same SUB | MAIN columns as the VFO boxes above. Receive only, so
        // no TX readings.
        HStack(spacing: 12) {
            ChannelStrip(
                label: "SUB",
                smeterDb: state.subSmeterDb,
                txReadings: nil,
                ptt: false,
                volume: $subAudioVolume,
                squelchThreshold: $subAudioSquelchThreshold,
                isMuted: viewModel.isSubAudioMuted,
                engine: viewModel.subAudioEngine,
                onToggleMute: viewModel.toggleSubAudioMuted
            )
            ChannelStrip(
                label: "MAIN",
                smeterDb: state.smeterDb,
                txReadings: nil,
                ptt: false,
                volume: $mainAudioVolume,
                squelchThreshold: $mainAudioSquelchThreshold,
                isMuted: viewModel.isMainAudioMuted,
                engine: viewModel.mainAudioEngine,
                onToggleMute: viewModel.toggleMainAudioMuted
            )
        }

        // Only the problem case gets a line; playing/off need no text.
        if viewModel.audioState == .waiting {
            Text("Waiting for audio — is another device using the Pi's stream?")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Text("Direct to rigctld on the Pi, no Mac hub. Unlock to transmit; hold PTT to talk through the iPad's microphone. Audio follows swaps; use the speaker button if MAIN and SUB audio are reversed.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Scan/Skip, V/M, swap and audio-channel override — same as the Mac's
    /// buttons by the VFO boxes. Swap and V/M are refused while the rig
    /// scans; stop the scan first.
    private var rigButtons: some View {
        let state = viewModel.rigState
        let scanning = state.memoryScan == .scanning || state.memoryScan == .paused
        return HStack(spacing: 12) {
            MemoryScanButtons(state: state, isConnected: true, send: viewModel.send)

            // Against `.vfo`, not `.memory`, as on the Mac: the rig's other
            // channel modes (PMS, 5 MHz band...) must exit to VFO too.
            Button {
                viewModel.send(.setVFOMemoryMode(memory: state.vfoMemoryMode == .vfo))
            } label: {
                Text("V/M")
                    .fontWeight(state.vfoMemoryMode == .vfo ? .regular : .bold)
            }
            .disabled(scanning || state.vfoMemoryMode == nil)

            Button {
                viewModel.send(.swapActiveVFO)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(scanning)
            .accessibilityLabel("Swap MAIN and SUB")

            Button {
                viewModel.toggleAudioChannelsSwapped()
            } label: {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(viewModel.audioChannelsSwapped ? Color.white : Color.primary)
            }
            .tint(viewModel.audioChannelsSwapped ? .orange : nil)
            .accessibilityLabel(viewModel.audioChannelsSwapped ? "Audio channels swapped; tap to swap back" : "Swap audio channels")
        }
        .buttonStyle(.bordered)
    }

    private var connectButton: some View {
        Button {
            if viewModel.connectionState == .disconnected {
                viewModel.connect(toHost: host, wpsdHost: wpsdHost)
            } else {
                viewModel.disconnect()
            }
        } label: {
            Text(buttonTitle)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(buttonColor)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.connectionState == .disconnected && host.isEmpty)
    }

    /// Connecting/retrying is tappable too — it cancels the retry loop.
    private var buttonTitle: String {
        switch viewModel.connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Retrying…"
        }
    }

    private var buttonColor: Color {
        switch viewModel.connectionState {
        case .disconnected: .red
        case .connecting, .failed: .orange
        case .connected: .green
        }
    }
}

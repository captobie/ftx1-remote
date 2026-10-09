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
/// Receive-only: no PTT, power, band picker, VFO swap or `MenuPageView` —
/// those transmit, or depend on `HubService` translating/gating commands,
/// which this path bypasses. A swap would also break the "left = Main,
/// right = Sub" assumption the audio columns rely on.
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

        Text("Receive only — direct to rigctld on the Pi, no Mac hub. Audio: left channel = MAIN, right = SUB, until the rig's VFOs are swapped.")
            .font(.caption)
            .foregroundStyle(.secondary)
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

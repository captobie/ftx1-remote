import FTX1Core
import SwiftUI

/// The iPad's Pi-direct proof-of-concept screen (see `PiDirectViewModel`):
/// a cut-down `HubControlView` — SUB/MAIN `VFODisplayBox`es, the S-meter,
/// Sub + Main audio columns, and the mode picker. MAIN can be tuned and
/// its mode changed; SUB is read-only (the model accepts only
/// `.setFrequency`/`.setMode`).
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
        HStack(spacing: 12) {
            VFODisplayBox(
                label: "SUB",
                frequencyHz: state.secondaryFrequencyHz,
                isActive: true,
                mode: state.secondaryMode?.displayName ?? "—"
            )
            VFODisplayBox(
                label: "MAIN",
                frequencyHz: state.frequencyHz,
                isActive: true,
                mode: state.mode.displayName,
                onSetFrequency: { viewModel.send(.setFrequency(hz: $0)) }
            )
        }

        HStack(alignment: .bottom, spacing: 12) {
            SMeterView(smeterDb: state.smeterDb, swr: nil, ptt: state.ptt)
                .frame(width: 280)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    ChannelAudioControls(
                        label: "SUB",
                        volume: $subAudioVolume,
                        squelchThreshold: $subAudioSquelchThreshold,
                        isMuted: viewModel.isSubAudioMuted,
                        engine: viewModel.subAudioEngine,
                        onToggleMute: viewModel.toggleSubAudioMuted
                    )
                    ChannelAudioControls(
                        label: "MAIN",
                        volume: $mainAudioVolume,
                        squelchThreshold: $mainAudioSquelchThreshold,
                        isMuted: viewModel.isMainAudioMuted,
                        engine: viewModel.mainAudioEngine,
                        onToggleMute: viewModel.toggleMainAudioMuted
                    )
                }
                Text(audioStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }

        Picker("Mode", selection: Binding(
            get: { viewModel.rigState.mode },
            set: { viewModel.send(.setMode($0)) }
        )) {
            ForEach(RigMode.allCases.filter { $0 != .unknown }, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        Text("Receive only — direct to rigctld on the Pi, no Mac hub. Audio: left channel = MAIN, right = SUB, until the rig's VFOs are swapped.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var audioStatus: String {
        switch viewModel.audioState {
        case .off: "Audio off"
        case .waiting: "Waiting for audio — is another device using the Pi's stream?"
        case .playing: "Audio from the Pi"
        }
    }

    private var connectButton: some View {
        Button {
            if viewModel.connectionState == .disconnected {
                viewModel.connect(toHost: host)
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

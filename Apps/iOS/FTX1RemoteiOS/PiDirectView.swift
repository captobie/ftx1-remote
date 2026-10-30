import FTX1Core
import SwiftUI

/// The Pi-direct proof of concept's screen (see `PiDirectViewModel`):
/// the selected receiver's (MAIN or SUB, `DisplaySide`) frequency, mode
/// and S-meter, tunable, plus its audio from the Pi's stream with mute,
/// VOL and SQL. Both channels play, each by its own mute; the controls
/// shown are the selected side's. Hold-to-talk PTT along the bottom keys
/// through rigctld and sends the microphone to the Pi's TX audio service,
/// behind this route's own transmit lock (off by default), as on the iPad.
struct PiDirectView: View {
    @EnvironmentObject private var viewModel: PiDirectViewModel
    @AppStorage("piHost") private var host: String = "ftx1pi"
    @AppStorage(DisplaySide.storageKey) private var side: DisplaySide = .main
    /// Same persisted keys as the iPad's audio controls.
    @AppStorage(AudioPlaybackSettings.volumeKey) private var mainVolume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.squelchThresholdKey) private var mainSquelchThreshold: Double = 0.015
    @AppStorage(AudioPlaybackSettings.subVolumeKey) private var subVolume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.subSquelchThresholdKey) private var subSquelchThreshold: Double = 0.015
    @Environment(\.scenePhase) private var scenePhase

    /// Upper bound of the squelch slider's displayed range, as on the iPad:
    /// the slider shows `range - threshold`, so left is open (the
    /// quieting gate's threshold is high) and right is tight, like a rig's
    /// squelch knob. HF band noise sits around 0.02 RMS, so it only
    /// passes with the slider toward the left.
    private static let squelchDisplayRange: Double = 0.05

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.connectionState != .connected {
                TextField("common.piHostnameTailscale", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            HStack(spacing: 12) {
                connectButton
                if viewModel.connectionState == .connected {
                    TransmitLockButton(
                        isEnabled: viewModel.transmitEnabled,
                        enabledLabel: "common.transmitEnabledTapTo",
                        disabledLabel: "common.transmitDisabledTapTo"
                    ) {
                        viewModel.transmitEnabled.toggle()
                    }
                }
            }

            if case .failed(let message) = viewModel.connectionState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if viewModel.connectionState == .connected {
                SideDisplay(side: side, state: viewModel.rigState, send: viewModel.send) {
                    audioRow
                    audioSliders
                }
            }

            Spacer(minLength: 0)

            if viewModel.connectionState == .connected {
                if let problem = viewModel.transmitProblem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                PTTButton(
                    isTransmitting: viewModel.isTransmitting || viewModel.rigState.ptt,
                    blockReason: viewModel.transmitBlockReason,
                    onPress: viewModel.startTransmit,
                    onRelease: viewModel.stopTransmit
                )
            }
        }
        .padding(24)
        // A press can't be released from the background; don't stay keyed.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stopTransmit() }
        }
    }

    private var isMuted: Bool {
        side == .main ? viewModel.isMainAudioMuted : viewModel.isSubAudioMuted
    }

    private var volume: Binding<Double> { side == .main ? $mainVolume : $subVolume }
    private var squelchThreshold: Binding<Double> { side == .main ? $mainSquelchThreshold : $subSquelchThreshold }

    private var audioRow: some View {
        HStack(spacing: 12) {
            Button {
                if side == .main { viewModel.toggleMainAudioMuted() } else { viewModel.toggleSubAudioMuted() }
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title3)
                    .frame(width: 44, height: 36)
                    .background(isMuted ? Color.orange.opacity(0.85) : Color.gray.opacity(0.25))
                    .foregroundStyle(isMuted ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMuted ? "piDirect.unmuteAudio \(side.label)" : "piDirect.muteAudio \(side.label)")

            Text(audioStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var audioSliders: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("VOL").font(.caption.monospaced())
                Slider(value: volume, in: 0...1)
            }
            GridRow {
                Text("SQL").font(.caption.monospaced())
                Slider(
                    value: Binding(
                        get: { Self.squelchDisplayRange - squelchThreshold.wrappedValue },
                        set: { squelchThreshold.wrappedValue = Self.squelchDisplayRange - $0 }
                    ),
                    in: 0...Self.squelchDisplayRange
                )
            }
        }
        // Both engines, whichever side is shown: each plays all the time.
        .onChange(of: mainVolume, initial: true) { _, newValue in
            viewModel.mainAudioEngine.volume = Float(newValue)
        }
        .onChange(of: mainSquelchThreshold, initial: true) { _, newValue in
            viewModel.mainAudioEngine.squelchThreshold = Float(newValue)
        }
        .onChange(of: subVolume, initial: true) { _, newValue in
            viewModel.subAudioEngine.volume = Float(newValue)
        }
        .onChange(of: subSquelchThreshold, initial: true) { _, newValue in
            viewModel.subAudioEngine.squelchThreshold = Float(newValue)
        }
    }

    private var audioStatus: String {
        switch viewModel.audioState {
        case .off: String(localized: "piDirect.audioOff")
        case .waiting: String(localized: "piDirect.waitingForAudioIs")
        case .playing: isMuted ? String(localized: "piDirect.audioMuted \(side.label)") : String(localized: "piDirect.audio \(side.label)")
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
        case .disconnected: String(localized: "common.disconnected")
        case .connecting: String(localized: "common.connecting")
        case .connected: String(localized: "common.connected")
        case .failed: String(localized: "common.retrying")
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

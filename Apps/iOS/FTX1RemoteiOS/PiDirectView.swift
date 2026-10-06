import FTX1Core
import SwiftUI

/// The Pi-direct proof of concept's screen (see `PiDirectViewModel`):
/// MAIN frequency/mode with tune and mode change, SUB and TX state shown
/// read-only, plus Main audio from the Pi's stream with a mute button.
/// Receive-only — no PTT.
struct PiDirectView: View {
    @EnvironmentObject private var viewModel: PiDirectViewModel
    @AppStorage("piHost") private var host: String = "ftx1pi"
    /// Same persisted keys as the iPad's Main audio controls.
    @AppStorage(AudioPlaybackSettings.volumeKey) private var volume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.squelchThresholdKey) private var squelchThreshold: Double = 0.015

    /// Upper bound of the squelch slider's displayed range, as on the iPad:
    /// the slider shows `range - threshold`, so left is open (the
    /// quieting gate's threshold is high) and right is tight, like a rig's
    /// squelch knob. HF band noise sits around 0.02 RMS, so it only
    /// passes with the slider toward the left.
    private static let squelchDisplayRange: Double = 0.05

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.connectionState != .connected {
                TextField("Pi hostname (Tailscale)", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            connectButton

            if case .failed(let message) = viewModel.connectionState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if viewModel.connectionState == .connected {
                FrequencyDisplay(
                    frequencyHz: viewModel.rigState.frequencyHz,
                    mode: viewModel.rigState.mode.displayName,
                    onSetFrequency: { viewModel.send(.setFrequency(hz: $0)) }
                )
                statusLine
                audioRow
                audioSliders
                ModeGrid(selected: viewModel.rigState.mode) { viewModel.send(.setMode($0)) }
                Text("Receive only — direct to rigctld on the Pi, no Mac hub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var statusLine: some View {
        HStack {
            if let subHz = viewModel.rigState.secondaryFrequencyHz {
                Text("SUB \(Self.format(subHz)) \(viewModel.rigState.secondaryMode?.displayName ?? "")")
            }
            Spacer()
            if viewModel.rigState.ptt {
                Text("TX")
                    .bold()
                    .padding(.horizontal, 6)
                    .background(Color.red)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    private var audioRow: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.toggleMainAudioMuted()
            } label: {
                Image(systemName: viewModel.isMainAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title3)
                    .frame(width: 44, height: 36)
                    .background(viewModel.isMainAudioMuted ? Color.orange.opacity(0.85) : Color.gray.opacity(0.25))
                    .foregroundStyle(viewModel.isMainAudioMuted ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isMainAudioMuted ? "Unmute audio" : "Mute audio")

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
                Slider(value: $volume, in: 0...1)
            }
            GridRow {
                Text("SQL").font(.caption.monospaced())
                Slider(
                    value: Binding(
                        get: { Self.squelchDisplayRange - squelchThreshold },
                        set: { squelchThreshold = Self.squelchDisplayRange - $0 }
                    ),
                    in: 0...Self.squelchDisplayRange
                )
            }
        }
        .onChange(of: volume, initial: true) { _, newValue in
            viewModel.mainAudioEngine.volume = Float(newValue)
        }
        .onChange(of: squelchThreshold, initial: true) { _, newValue in
            viewModel.mainAudioEngine.squelchThreshold = Float(newValue)
        }
    }

    private var audioStatus: String {
        switch viewModel.audioState {
        case .off: "Audio off"
        case .waiting: "Waiting for audio — is the Mac using the Pi's stream?"
        case .playing: viewModel.isMainAudioMuted ? "Main audio (muted)" : "Main audio"
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

    private static func format(_ hz: Int) -> String {
        let mhz = hz / 1_000_000
        let khz = (hz / 1_000) % 1_000
        let rest = hz % 1_000
        return String(format: "%d.%03d.%03d", mhz, khz, rest)
    }
}

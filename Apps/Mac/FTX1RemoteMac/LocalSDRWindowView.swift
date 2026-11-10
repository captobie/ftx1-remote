import FTX1Core
import SwiftUI

/// Tools → Local SDR (`Window(id: "local-sdr")`): the operator's own
/// KiwiSDR as native audio, through `LocalSDRModel`. Opens disconnected;
/// closing the window disconnects. `hub` for the rig link (Follow, Tune
/// rig, Mute on TX, muting Main), passed in so the model can subscribe in
/// `init`, as the WebSDR window does.
struct LocalSDRWindowView: View {
    @StateObject private var model: LocalSDRModel
    @Environment(\.openWindow) private var openWindow

    init(hub: HubService) {
        _model = StateObject(wrappedValue: LocalSDRModel(hub: hub))
    }
    /// The frequency field's text in kHz, committed on Return.
    @State private var frequencyDraft = ""
    @FocusState private var frequencyFocused: Bool

    private static let steps = [100, 1_000, 5_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalSDRWaterfallView(model: model, store: model.waterfall)
                .frame(minHeight: 240, maxHeight: .infinity)
            Divider()
            connectionRow
            Divider()
            tuningRow
            HStack(spacing: 16) {
                LocalSDRMeterView(meter: model.meter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                audioControls
            }
            rigLinkRow
            Divider()
            Text(verbatim: model.recordingNote.map { "\(statusText) · \($0)" } ?? statusText)
                .font(.caption)
                .themedSecondaryForeground()
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("app.myKiwiSDR")
        .onAppear { frequencyDraft = Self.kHzText(model.frequencyHz) }
        .onChange(of: model.frequencyHz) { _, hz in
            if !frequencyFocused { frequencyDraft = Self.kHzText(hz) }
        }
        .onDisappear(perform: model.disconnect)
    }

    // MARK: - Rows

    private var connectionRow: some View {
        HStack(spacing: 10) {
            TextField("localSDR.hostPlaceholder", text: $model.hostPort)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .frame(maxWidth: 260)
                .disabled(model.isConnected)
                .onSubmit { if !model.isConnected { model.connect() } }
            SecureField("localSDR.password", text: $model.password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .disabled(model.isConnected)
                .onSubmit { if !model.isConnected { model.connect() } }
                .help("localSDR.passwordHelp")
            if model.isConnected {
                Button("common.disconnect", systemImage: "stop.circle", action: model.disconnect)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(ThemedButtonStyle())
            } else {
                Button("common.connect", systemImage: "play.circle", action: model.connect)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(!model.canConnect)
            }
            Spacer()
            recordButton
            // The same Recordings window as the WebSDR window's and the CW
            // page's PLAY: MyKiwiSDR recordings sit beside the rig's own.
            Button("localSDR.play", systemImage: "waveform") { openWindow(id: "recordings") }
                .labelStyle(.titleAndIcon)
                .buttonStyle(ThemedButtonStyle())
                .help("localSDR.playHelp")
        }
    }

    /// Record while connected; Stop (red, with the current file's elapsed
    /// time) while recording.
    @ViewBuilder
    private var recordButton: some View {
        if model.isRecording {
            Button(action: model.toggleRecording) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                    Text("common.stop")
                    if let started = model.segmentStartedAt {
                        Text(started, style: .timer).monospacedDigit()
                    }
                }
            }
            .buttonStyle(ThemedButtonStyle())
            .foregroundStyle(.red)
            .help("localSDR.stopRecordingHelp")
        } else {
            Button("localSDR.record", systemImage: "record.circle", action: model.toggleRecording)
                .labelStyle(.titleAndIcon)
                .buttonStyle(ThemedButtonStyle())
                .disabled(!isAudioReady)
                .help(isAudioReady ? "localSDR.recordHelp" : "localSDR.recordNeedsConnection")
        }
    }

    private var isAudioReady: Bool {
        if case .connected = model.state { return true }
        return false
    }

    private var tuningRow: some View {
        HStack(spacing: 10) {
            Text(FrequencyFormat.dotted(model.frequencyHz))
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .frame(minWidth: 190, alignment: .trailing)
            TextField("localSDR.frequencyKHz", text: $frequencyDraft)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .frame(width: 110)
                .focused($frequencyFocused)
                .onSubmit(commitFrequency)
                .help("localSDR.frequencyHelp")
            ForEach(Self.steps, id: \.self) { step in
                HStack(spacing: 2) {
                    Button { model.step(byHz: -step) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(ThemedButtonStyle())
                    Text(verbatim: Self.stepLabel(step))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 34)
                    Button { model.step(byHz: step) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(ThemedButtonStyle())
                }
            }
            Picker("common.mode", selection: Binding(get: { model.mode }, set: model.selectMode)) {
                ForEach(KiwiSDRMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var rigLinkRow: some View {
        HStack(spacing: 14) {
            Toggle("localSDR.followRig", isOn: $model.followRig)
                .help("localSDR.followRigHelp")
            Toggle("localSDR.tuneRig", isOn: $model.tuneRig)
                .help("localSDR.tuneRigHelp")
            Toggle("localSDR.muteOnTx", isOn: $model.muteOnTransmit)
                .help("localSDR.muteOnTxHelp")
            Text(rigLinkText)
                .font(.caption)
                .foregroundStyle(model.rigLinkNote == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }

    /// Which direction is active, then the last refusal, if any.
    private var rigLinkText: String {
        let active: String
        switch (model.followRig, model.tuneRig) {
        case (true, true): active = String(localized: "localSDR.rigLink.both")
        case (true, false): active = String(localized: "localSDR.rigLink.followOnly")
        case (false, true): active = String(localized: "localSDR.rigLink.tuneOnly")
        case (false, false): active = String(localized: "localSDR.rigLink.off")
        }
        if !model.isConnected, model.followRig || model.tuneRig {
            return String(localized: "localSDR.rigLink.whenConnected \(active)")
        }
        guard let note = model.rigLinkNote else { return active }
        return String(localized: "localSDR.rigLink.withNote \(active) \(note)")
    }

    private var audioControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").themedSecondaryForeground()
            Slider(value: $model.volume, in: 0...1)
                .frame(width: 140)
                .help("localSDR.volume")
            Button(action: model.toggleMuted) {
                Label(model.isMuted ? "localSDR.muted" : "localSDR.mute",
                      systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(ThemedButtonStyle(isOn: model.isMuted, prominentWhenOn: false))
            .foregroundStyle(model.isMuted ? .red : .primary)
            .fixedSize()
        }
    }

    // MARK: - Helpers

    private func commitFrequency() {
        let text = frequencyDraft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let kHz = Double(text), kHz > 0 {
            model.setFrequency(Int((kHz * 1000).rounded()))
        }
        frequencyDraft = Self.kHzText(model.frequencyHz)
    }

    /// kHz with only the decimals it needs, always with a "." (frequencies
    /// don't follow the locale).
    static func kHzText(_ hz: Int) -> String {
        let kHz = Double(hz) / 1000
        var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), kHz)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func stepLabel(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }

    private var statusText: String {
        switch model.state {
        case .disconnected:
            String(localized: "localSDR.status.disconnected")
        case .connecting:
            String(localized: "localSDR.status.connecting \(model.connectedHostPort)")
        case .connected(let rate):
            String(localized: "localSDR.status.connected \(model.connectedHostPort) \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rate))")
        case .failed(let error):
            Self.message(for: error)
        }
    }

    static func message(for error: KiwiSDRError) -> String {
        switch error {
        case .invalidHost: String(localized: "localSDR.error.invalidHost")
        case .badPassword: String(localized: "localSDR.error.badPassword")
        case .busy: String(localized: "localSDR.error.busy")
        case .down: String(localized: "localSDR.error.down")
        case .redirect(let target): String(localized: "localSDR.error.redirect \(target)")
        case .refused(let code): String(localized: "localSDR.error.refused \(code)")
        case .unreachable(let reason): String(localized: "localSDR.error.unreachable \(reason)")
        case .noResponse: String(localized: "localSDR.error.noResponse")
        }
    }
}

/// The Kiwi's S-meter as S units (S9 = −73 dBm, 6 dB per unit, the HF
/// convention — the Kiwi covers 0–30 MHz) with the dBm reading.
private struct LocalSDRMeterView: View {
    @ObservedObject var meter: LocalSDRMeterStore

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(width: 180, height: 10)
            Text(verbatim: readout)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 130, alignment: .leading)
            if meter.overload {
                Text("localSDR.adcOverload")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
        .animation(.linear(duration: 0.1), value: meter.dBm)
    }

    /// S0 (−127 dBm) … S9 (−73) fills 60%, S9+40 (−33) the rest.
    private var fraction: CGFloat {
        guard let dBm = meter.dBm else { return 0 }
        if dBm <= -73 { return CGFloat(max(0, (dBm + 127) / 54) * 0.6) }
        return CGFloat(0.6 + min(1, (dBm + 73) / 40) * 0.4)
    }

    private var fillColor: Color {
        (meter.dBm ?? -127) > -73 ? .red : .green
    }

    private var readout: String {
        guard let dBm = meter.dBm else { return "S– · — dBm" }
        let sUnits: String
        if dBm > -73 {
            sUnits = "S9+\(Int((dBm + 73).rounded()))"
        } else {
            sUnits = "S\(max(0, Int(((dBm + 127) / 6).rounded(.down))))"
        }
        return "\(sUnits) · \(Int(dBm.rounded())) dBm"
    }
}

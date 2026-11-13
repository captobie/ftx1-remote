import FTX1Core
import SwiftUI

/// Tools → Local SDR (`Window(id: "local-sdr")`): the operator's own
/// KiwiSDR as native audio, through `LocalSDRModel`. Opens disconnected;
/// closing the window disconnects. `hub` is the rig link (Follow, Tune
/// rig, Mute on TX, muting Main) and the decoder source.
struct LocalSDRWindowView: View {
    @StateObject private var model: LocalSDRModel
    @Environment(\.openWindow) private var openWindow

    init(hub: HubService) {
        _model = StateObject(wrappedValue: LocalSDRModel(hub: hub))
    }
    /// The frequency field's text in kHz, committed on Return.
    @State private var frequencyDraft = ""
    @FocusState private var frequencyFocused: Bool
    @State private var receiverExpanded = false
    @AppStorage(LocalSDRModel.hostKey) private var hostPort = ""

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
            DisclosureGroup("common.receiver", isExpanded: $receiverExpanded) {
                LocalSDRReceiverSection(model: model)
                    .padding(.top, 6)
            }
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
            // Address and password live in Settings → Devices.
            if hostPort.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("localSDR.noHost")
                    .themedSecondaryForeground()
            } else {
                Text(verbatim: hostPort)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            SettingsLink {
                Label("localSDR.settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(ThemedButtonStyle())
            .help("localSDR.settingsHelp")
            if model.isConnected {
                Button("common.disconnect", systemImage: "stop.circle", action: model.disconnect)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(ThemedButtonStyle())
            } else {
                Button("common.connect", systemImage: "play.circle", action: model.connect)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(model.isLoadingPassword || !LocalSDRModel.isValidHost(hostPort))
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
            // In a box like the S-meter's under it, same width, in the VFO
            // boxes' themed digits — a size down where the font (7-segment,
            // padded with unlit 8s) is too wide for the box.
            ViewThatFits(in: .horizontal) {
                ForEach([26, 22, 18] as [CGFloat], id: \.self) { size in
                    VFODigitsText(text: FrequencyFormat.dotted(model.frequencyHz), size: size)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 190, height: 40, alignment: .trailing)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.gray.opacity(0.6), lineWidth: 1.5)
            )
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
            Toggle("localSDR.followRigWidth", isOn: Binding(get: { model.followRigWidth }, set: model.setFollowRigWidth))
                .help("localSDR.followRigWidthHelp")
                .disabled(!model.followRig)
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
            model.isLoadingPassword
                ? String(localized: "localSDR.status.readingPassword")
                : String(localized: "localSDR.status.disconnected")
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

/// AGC, noise blanker and noise filter, collapsed by default. Each row is
/// one group; a control that wouldn't do anything isn't shown.
private struct LocalSDRReceiverSection: View {
    @ObservedObject var model: LocalSDRModel

    private typealias Settings = KiwiReceiverSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            agcRow
            blankerRow
            filterRow
        }
    }

    private var agcRow: some View {
        HStack(spacing: 14) {
            Toggle(isOn: bind(\.agc)) { Text(verbatim: "AGC").frame(width: 34, alignment: .leading) }
                .toggleStyle(.switch)
                .help("localSDR.receiver.agcHelp")
                .fixedSize()
            if model.receiver.agc {
                slider("localSDR.receiver.threshold", value: intBinding(\.threshold), range: range(Settings.thresholdRange),
                       step: 1, readout: "\(model.receiver.threshold) dB")
                slider("localSDR.receiver.decay", value: intBinding(\.decay), range: range(Settings.decayRange),
                       step: Double(Settings.decayStep), readout: "\(model.receiver.decay) ms")
            } else {
                slider("localSDR.receiver.manualGain", value: intBinding(\.manualGain), range: range(Settings.manualGainRange),
                       step: 1, readout: "\(model.receiver.manualGain) dB")
            }
        }
    }

    private var blankerRow: some View {
        HStack(spacing: 14) {
            Text(verbatim: "NB").frame(width: 34, alignment: .leading)
            Picker("localSDR.receiver.noiseBlanker", selection: bind(\.noiseBlanker)) {
                Text("localSDR.receiver.off").tag(Settings.NoiseBlanker.off)
                Text("localSDR.receiver.standard").tag(Settings.NoiseBlanker.standard)
                Text(verbatim: "Wild").tag(Settings.NoiseBlanker.wild)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("localSDR.receiver.noiseBlankerHelp")
            switch model.receiver.noiseBlanker {
            case .off:
                EmptyView()
            case .standard:
                slider("localSDR.receiver.gate", value: intBinding(\.gate), range: range(Settings.gateRange),
                       step: Double(Settings.gateStep), readout: "\(model.receiver.gate)")
                slider("localSDR.receiver.threshold", value: intBinding(\.blankerThreshold),
                       range: range(Settings.blankerThresholdRange), step: 1, readout: "\(model.receiver.blankerThreshold)")
            case .wild:
                slider("localSDR.receiver.threshold", value: bind(\.wildThreshold), range: Settings.wildThresholdRange,
                       step: Settings.wildThresholdStep,
                       readout: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), model.receiver.wildThreshold))
            }
            Spacer(minLength: 0)
        }
    }

    private var filterRow: some View {
        HStack(spacing: 14) {
            Text(verbatim: "NR").frame(width: 34, alignment: .leading)
            Picker("localSDR.receiver.noiseFilter", selection: Binding(
                get: { model.receiver.noiseFilter },
                set: { filter in model.updateReceiver { $0.select(noiseFilter: filter) } })) {
                Text("localSDR.receiver.off").tag(Settings.NoiseFilter.off)
                Text(verbatim: "WDSP").tag(Settings.NoiseFilter.wdsp)
                Text(verbatim: "LMS").tag(Settings.NoiseFilter.lms)
                Text(verbatim: "Spectral").tag(Settings.NoiseFilter.spectral)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("localSDR.receiver.noiseFilterHelp")
            if model.receiver.noiseFilter.hasSeparateFilters {
                Toggle("localSDR.receiver.denoise", isOn: bind(\.denoise))
                    .toggleStyle(.switch)
                    .fixedSize()
                Toggle("localSDR.receiver.autonotch", isOn: bind(\.autonotch))
                    .toggleStyle(.switch)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>,
                        step: Double, readout: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).themedSecondaryForeground().fixedSize()
            Slider(value: value, in: range, step: step).frame(minWidth: 90, maxWidth: 220)
            Text(verbatim: readout).font(.caption.monospacedDigit()).frame(minWidth: 52, alignment: .leading)
        }
    }

    private func range(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    private func bind<T: Equatable>(_ path: WritableKeyPath<KiwiReceiverSettings, T>) -> Binding<T> {
        Binding(get: { model.receiver[keyPath: path] },
                set: { value in model.updateReceiver { $0[keyPath: path] = value } })
    }

    private func intBinding(_ path: WritableKeyPath<KiwiReceiverSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(model.receiver[keyPath: path]) },
                set: { value in model.updateReceiver { $0[keyPath: path] = Int(value.rounded()) } })
    }
}

/// The Kiwi's S-meter on the main window's meter face (Settings →
/// Appearance → S-Meter), with the dBm reading and the ADC overload flag
/// beside it. S9 = −73 dBm, 6 dB per unit (the HF convention — the Kiwi
/// covers 0–30 MHz), so the face's dB-over-S9 is dBm + 73.
private struct LocalSDRMeterView: View {
    @ObservedObject var meter: LocalSDRMeterStore
    @AppStorage(AppearanceSettings.sMeterStyleKey) private var style: SMeterStyle = .lighted

    /// The main window's meter size (`ContentView.meterWidth`, 280:120).
    private static let width: CGFloat = 190

    var body: some View {
        HStack(spacing: 12) {
            SMeterView(
                smeterDb: meter.dBm.map { $0 + 73 },
                swr: nil,
                ptt: false,
                style: style,
                receiveOnly: true,
                label: "MyKiwiSDR"
            )
            // Digital is a single S line here (no TX meter), so it's short.
            .frame(width: Self.width, height: style == .digital ? 30 : Self.width * 120 / 280)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: sUnits)
                    .font(.title3.monospacedDigit().bold())
                Text(verbatim: dBmText)
                    .font(.callout.monospacedDigit())
                    .themedSecondaryForeground()
                if meter.overload {
                    Text("localSDR.adcOverload")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            .frame(minWidth: 90, alignment: .leading)
        }
    }

    private var sUnits: String {
        guard let dBm = meter.dBm else { return "S–" }
        if dBm > -73 { return "S9+\(Int((dBm + 73).rounded()))" }
        return "S\(max(0, Int(((dBm + 127) / 6).rounded(.down))))"
    }

    private var dBmText: String {
        guard let dBm = meter.dBm else { return "— dBm" }
        return "\(Int(dBm.rounded())) dBm"
    }
}

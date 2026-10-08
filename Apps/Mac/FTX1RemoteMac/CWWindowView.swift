import CWKit
import FTX1Core
import SwiftUI
import UniformTypeIdentifiers

/// Tools → CW (`Window(id: "cw")` in `FTX1RemoteMacApp`): the receive pane
/// on top, the send pane (`CWSendPane`, v2) below it and the Log QSO pane
/// (`CWLogPane`) at the bottom, in a `VSplitView`. Each
/// pane keeps its own controls in its own header rather than sharing the
/// window toolbar.
///
/// Decoding runs only while this window is open (`.onAppear`/
/// `.onDisappear`), like FT8. Sending doesn't stop when it closes: a
/// queued line still goes out (Stop is the way to cancel it).
struct CWWindowView: View {
    @EnvironmentObject private var receiver: CWReceiver
    @EnvironmentObject private var workedStations: WorkedStationsStore

    var body: some View {
        VSplitView {
            CWReceivePane()
                .frame(minHeight: 240)
            CWSendPane()
                .frame(minHeight: 230)
            CWLogPane()
                .frame(minHeight: 130, maxHeight: 160)
        }
            .navigationTitle("CW")
            .frame(minWidth: 720, minHeight: 660)
            .onAppear {
                receiver.start()
                workedStations.start()
            }
            .onDisappear {
                receiver.stop()
                workedStations.stop()
            }
            .alert("CW", isPresented: Binding(
                get: { receiver.errorMessage != nil },
                set: { if !$0 { receiver.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(receiver.errorMessage ?? "")
            }
    }
}

/// Decoded text plus its controls: channel/decoder/file/copy/clear header,
/// meter bar, text, tuning row. Ported from the standalone CWDecode app's
/// `ContentView` (`captobie/cwdecode`), minus its input-device picker — the
/// input here is always the rig's audio.
private struct CWReceivePane: View {
    @EnvironmentObject private var receiver: CWReceiver
    @State private var isShowingFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CWSignalStatusBar(meters: receiver.meters, isDecodingFile: receiver.isDecodingFile, sourceNote: sourceNote)
            Divider()
            CWDecodedTextView(text: receiver.decodedText, tentative: receiver.tentativeText)
            Divider()
            CWTuningControls(meters: receiver.meters)
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.audio],
            onCompletion: { result in
                switch result {
                case .success(let url):
                    receiver.decodeFile(at: url)
                case .failure(let error):
                    receiver.errorMessage = error.localizedDescription
                }
            }
        )
        .fileDialogDefaultDirectory(AudioRecorder.recordingsDirectory)
    }

    /// Why the WebSDR source isn't decoding, when it isn't.
    private var sourceNote: String? {
        guard !receiver.isDecodingFile else { return nil }
        if receiver.isPausedForTransmit {
            return "Paused while transmitting"
        }
        if let mode = receiver.sourceModeIfNotCW {
            return "\(receiver.channel.title) is in \(mode.displayName), not CW — decoding anyway"
        }
        guard receiver.channel == .webSDR else { return nil }
        switch receiver.webSDRStatus {
        case .stopped, .capturing:
            return nil
        case .waitingForWebSDR:
            return "Waiting for the WebSDR window's audio — connect it in Tools → WebSDR"
        case .silent:
            return "WebSDR is silent — check that its page is playing, or allow FTX1Remote under System Settings → Privacy & Security → Screen & System Audio Recording"
        case .failed(let message):
            return "Can't capture WebSDR audio: \(message)"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            CWChannelPicker()
            CWDecoderPicker()
            Spacer()
            Button {
                isShowingFileImporter = true
            } label: {
                Label("Open Audio File…", systemImage: "waveform")
            }
            .keyboardShortcut("o")
            .help("Decode a recording (the Recordings folder opens first)")
            .disabled(receiver.isDecodingFile)

            Button {
                receiver.copyText()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy the decoded text")
            .disabled(receiver.decodedText.isEmpty)

            Button {
                receiver.clearText()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .keyboardShortcut("k")
            .help("Clear the decoded text")
            .disabled(receiver.decodedText.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// MAIN/SUB. Its own view so that observing `hub` (for single-receive
/// display) re-renders only this picker, not the decoded text.
private struct CWChannelPicker: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var receiver: CWReceiver

    var body: some View {
        Picker("Receiver", selection: $receiver.channel) {
            ForEach(CWAudioChannel.allCases, id: \.self) { channel in
                Text(channel.title).tag(channel)
                    .selectionDisabled(channel == .sub && subUnavailableReason != nil)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(subUnavailableReason ?? "Which audio to decode: the rig's MAIN or SUB receiver, or what the WebSDR window is playing")
    }

    private var subUnavailableReason: String? {
        if !receiver.isSubAudioAvailable {
            "No SUB audio: the audio input is mono"
        } else if hub.rigState.singleReceive == true {
            "SUB is off: the rig is in single-receive display"
        } else {
            nil
        }
    }
}

private struct CWDecoderPicker: View {
    @EnvironmentObject private var receiver: CWReceiver

    var body: some View {
        Picker("Decoder", selection: $receiver.decoder) {
            ForEach(DecoderKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(receiver.neuralUnavailableReason != nil)
        .help(receiver.neuralUnavailableReason
              ?? "Neural: a model trained on simulated CW, best on weak and noisy signals; text runs about 3½ s behind. Classic: tone threshold and timing rules.")
    }
}

/// Callsigns in the committed text are links (`CWCallsigns`): clicking one
/// fills the send pane's Their call. Handled here through `openURL`, so the
/// custom scheme never reaches the system. The tentative text isn't linked
/// — it can still change.
/// Callsigns in the decoded text are links (a click fills Their call) and
/// are colored by worked-before (`WorkedStationsStore`): green worked on
/// the band the rig transmits on, orange worked only on other bands, the
/// plain link color never worked.
private struct CWDecodedTextView: View {
    @EnvironmentObject private var sender: CWSender
    @EnvironmentObject private var workedStations: WorkedStationsStore
    let text: String
    /// Newest text, not yet final: shown dimmed after the committed text.
    let tentative: String

    var body: some View {
        ScrollView {
            Group {
                if text.isEmpty && tentative.isEmpty {
                    Text("Decoded CW from the selected receiver appears here. Tune to a CW signal, or open a recording.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(linked)\(Text(tentative).foregroundStyle(.tertiary))")
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 20, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding()
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            if workedStations.problem == nil, !text.isEmpty {
                WorkedLegend(band: workedStations.band)
                    .padding(8)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let call = CWCallsigns.call(from: url) else { return .systemAction }
            sender.theirCall = call
            return .handled
        })
    }

    private var linked: AttributedString {
        var attributed = AttributedString(text)
        for range in CWCallsigns.ranges(in: text, excluding: StationSettings.callsign) {
            guard let attributedRange = Range(range, in: attributed),
                  let url = CWCallsigns.url(for: text[range]) else { continue }
            attributed[attributedRange].link = url
            attributed[attributedRange].underlineStyle = .single
            if let color = Self.color(for: workedStations.worked.status(of: String(text[range]), band: workedStations.band)) {
                attributed[attributedRange].foregroundColor = color
            }
        }
        return attributed
    }

    static func color(for status: WorkedStations.Status) -> Color? {
        switch status {
        case .thisBand: .green
        case .otherBand: .orange
        case .never: nil
        }
    }
}

/// Key to the decoded callsigns' colors.
private struct WorkedLegend: View {
    let band: String?

    var body: some View {
        HStack(spacing: 10) {
            entry(.green, "Worked on \(band ?? "this band")")
            entry(.orange, "Worked, other band")
            entry(Color(nsColor: .linkColor), "New")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private func entry(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }
}

private struct CWSignalStatusBar: View {
    @ObservedObject var meters: CWMeterStore
    let isDecodingFile: Bool
    let sourceNote: String?

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(meters.keyDown ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 12, height: 12)
                .help("Key down")

            CWLevelMeter(level: meters.signalLevel)
                .frame(width: 120, height: 8)
                .help("Tone level between the noise floor and the signal peak")

            Text(String(meters.pendingSymbols.map { $0 == "." ? "·" : "–" }))
                .font(.system(.title3, design: .monospaced))
                .frame(minWidth: 110, alignment: .leading)
                .help("Elements of the character being received (Classic decoder)")

            Spacer()

            if isDecodingFile {
                ProgressView().controlSize(.small)
                Text("Decoding file…").foregroundStyle(.secondary)
            } else if let sourceNote {
                Label(sourceNote, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(sourceNote)
            }

            Group {
                Text("\(Int(meters.detectedFrequency.rounded())) Hz")
                Text("SNR \(Int(meters.snrDB.rounded())) dB")
                Text(meters.wpm > 0 ? "\(Int(meters.wpm.rounded())) WPM" : "– WPM")
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

private struct CWLevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * min(max(level, 0), 1))
            }
        }
    }
}

private struct CWTuningControls: View {
    @EnvironmentObject private var receiver: CWReceiver
    @ObservedObject var meters: CWMeterStore

    var body: some View {
        HStack(spacing: 24) {
            Toggle("Auto-tune", isOn: $receiver.autoTune)
                .help("Follow the strongest tone between \(Int(FrequencyTracker.searchRange.lowerBound)) and \(Int(FrequencyTracker.searchRange.upperBound)) Hz")

            HStack {
                Text("Tone")
                Slider(value: frequency, in: FrequencyTracker.searchRange, step: 10)
                    .disabled(receiver.autoTune)
                Text("\(Int(frequency.wrappedValue.rounded())) Hz")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
                Button("Rig Pitch") {
                    receiver.useRigPitch()
                }
                .controlSize(.small)
                .disabled(receiver.rigPitchHz == nil)
                .help(receiver.rigPitchHz.map { "Turn off auto-tune and use the rig's CW pitch, \($0) Hz — where a zero-beat signal sounds" }
                      ?? "The rig's CW pitch hasn't been read yet")
            }

            HStack {
                Text("Squelch")
                Slider(value: $receiver.squelchDB, in: 3...30, step: 1)
                    .frame(maxWidth: 160)
                Text("\(Int(receiver.squelchDB)) dB")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(receiver.decoder == .neural)
            .help(receiver.decoder == .neural
                  ? "The neural decoder doesn't need a squelch: it stays silent on noise"
                  : "Minimum signal-to-noise ratio needed before anything is decoded")
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var frequency: Binding<Double> {
        Binding(
            get: { receiver.autoTune ? meters.detectedFrequency : receiver.toneFrequency },
            set: { receiver.toneFrequency = $0 }
        )
    }
}

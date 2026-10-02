import CWKit
import FTX1Core
import SwiftUI
import UniformTypeIdentifiers

/// Tools → CW (`Window(id: "cw")` in `FTX1RemoteMacApp`). v1 is the
/// receive pane only. v2 adds a send pane below it (planned: a `VSplitView`
/// with this pane on top), which is why each pane keeps its own controls in
/// its own header instead of sharing the window toolbar.
///
/// Decoding runs only while this window is open (`.onAppear`/
/// `.onDisappear`), like FT8.
struct CWWindowView: View {
    @EnvironmentObject private var receiver: CWReceiver

    var body: some View {
        CWReceivePane()
            .navigationTitle("CW")
            .frame(minWidth: 640, minHeight: 360)
            .onAppear { receiver.start() }
            .onDisappear { receiver.stop() }
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
            CWSignalStatusBar(meters: receiver.meters, isDecodingFile: receiver.isDecodingFile)
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
        .help(subUnavailableReason ?? "Which receiver's audio to decode")
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

private struct CWDecodedTextView: View {
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
                    Text("\(text)\(Text(tentative).foregroundStyle(.tertiary))")
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 20, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding()
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct CWSignalStatusBar: View {
    @ObservedObject var meters: CWMeterStore
    let isDecodingFile: Bool

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

import CWKit
import FTX1CW
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
    @EnvironmentObject private var webSDRSource: CWWebSDRSource
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
            return String(localized: "common.pausedWhileTransmitting")
        }
        if let mode = receiver.sourceModeIfNotCW {
            return String(localized: "common.isInNotCw \(receiver.channel.title) \(mode.displayName)")
        }
        guard receiver.channel == .webSDR else { return nil }
        switch webSDRSource.status {
        case .stopped, .capturing:
            return nil
        case .waitingForWebSDR:
            return String(localized: "common.waitingForTheWebSDR")
        case .silent:
            return String(localized: "cwWindow.webSDRIsSilentCheck")
        case .failed(let message):
            return String(localized: "cwWindow.cantCaptureWebSDRAudio \(message)")
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
                Label("cwWindow.openAudioFile", systemImage: "waveform")
            }
            .keyboardShortcut("o")
            .help("cwWindow.decodeARecordingThe")
            .disabled(receiver.isDecodingFile)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(receiver.decodedText, forType: .string)
            } label: {
                Label("common.copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("cwWindow.copyTheDecodedText")
            .disabled(receiver.decodedText.isEmpty)

            Button {
                receiver.clearText()
            } label: {
                Label("common.clear", systemImage: "trash")
            }
            .keyboardShortcut("k")
            .help("cwWindow.clearTheDecodedText")
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
        Picker("common.receiver", selection: $receiver.channel) {
            ForEach(CWAudioChannel.allCases, id: \.self) { channel in
                Text(channel.title).tag(channel)
                    .selectionDisabled(channel == .sub && subUnavailableReason != nil)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(subUnavailableReason ?? String(localized: "cwWindow.whichAudioToDecode"))
    }

    private var subUnavailableReason: String? {
        if !receiver.isSubAudioAvailable {
            String(localized: "cwWindow.noSubAudioThe")
        } else if hub.rigState.singleReceive == true {
            String(localized: "common.subIsOffThe")
        } else {
            nil
        }
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
        // The legend gets a row of its own under the scrolling text — not an
        // overlay (it covered the newest decoded line) and not a
        // `safeAreaInset` (the scroll view still ran under it there, and the
        // last lines couldn't be scrolled into view). Shown whenever the log
        // is loaded, so the text area doesn't change height as text arrives.
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if text.isEmpty && tentative.isEmpty {
                        Text("cwWindow.decodedCwFromThe")
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
            if workedStations.problem == nil {
                HStack {
                    Spacer()
                    WorkedLegend(band: workedStations.band)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
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
            entry(.green, String(localized: "cwWindow.workedOn \(band ?? "this band")"))
            entry(.orange, String(localized: "cwWindow.workedOtherBand"))
            entry(Color(nsColor: .linkColor), String(localized: "cwWindow.new"))
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

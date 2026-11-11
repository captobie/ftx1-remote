import FTX1Core
import FTX1Digi
import SwiftUI
import UniformTypeIdentifiers

/// Tools → RTTY/PSK (`Window(id: "digi")` in `FTX1RemoteMacApp`): decodes
/// one RTTY, BPSK31 or BPSK63 signal at a time from MAIN, SUB or the
/// WebSDR window's audio. A click on the tuning strip picks the signal;
/// AFC follows it from there.
///
/// Decoding runs only while this window is open, like FT8 and CW. The
/// strip and the status line observe `DigiReceiver.meters` (about ten
/// updates a second); only the text view observes the decoded text.
struct DigiWindowView: View {
    @EnvironmentObject private var receiver: DigiReceiver
    @EnvironmentObject private var sender: DigiSender
    @State private var isShowingFileImporter = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                DigiHeader(isShowingFileImporter: $isShowingFileImporter)
                Divider()
                DigiSettingsRow()
                Divider()
                DigiTuningStrip(meters: receiver.meters)
                    .frame(height: 84)
                Divider()
                DigiStatusLine(meters: receiver.meters)
                Divider()
                DigiDecodedTextView()
            }
            .frame(minHeight: 340)
            DigiSendPane()
                .frame(minHeight: 200)
        }
        .navigationTitle("RTTY/PSK")
        // Wide enough for the header's four sources and its buttons
        // without wrapping a label.
        .frame(minWidth: 980, minHeight: 600)
        .onAppear { receiver.start() }
        .onDisappear {
            // Not left keyed with nobody watching: closing acts as RX
            // (what's typed goes out, then the tail and unkey).
            sender.finish()
            receiver.stop()
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
        .alert("RTTY/PSK", isPresented: Binding(
            get: { receiver.errorMessage != nil },
            set: { if !$0 { receiver.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(receiver.errorMessage ?? "")
        }
    }
}

// MARK: - Header

private struct DigiHeader: View {
    @EnvironmentObject private var receiver: DigiReceiver
    @Binding var isShowingFileImporter: Bool

    var body: some View {
        HStack(spacing: 12) {
            Picker("digiWindow.mode", selection: $receiver.mode) {
                ForEach(DigiMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            DigiChannelPicker()
            Spacer()
            Button {
                isShowingFileImporter = true
            } label: {
                Label("cwWindow.openAudioFile", systemImage: "waveform")
            }
            .fixedSize()
            .keyboardShortcut("o")
            .help("digiWindow.decodeARecording")
            .disabled(receiver.isDecodingFile)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(receiver.decodedText, forType: .string)
            } label: {
                Label("common.copy", systemImage: "doc.on.doc")
            }
            .fixedSize()
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("digiWindow.copyTheText")
            .disabled(receiver.decodedText.isEmpty)

            Button {
                receiver.clearText()
            } label: {
                Label("common.clear", systemImage: "trash")
            }
            .fixedSize()
            .keyboardShortcut("k")
            .help("digiWindow.clearTheText")
            .disabled(receiver.decodedText.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// MAIN/SUB/WebSDR/MyKiwiSDR. Its own view so observing `hub` (for single-receive
/// display) re-renders only this picker.
private struct DigiChannelPicker: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var receiver: DigiReceiver

    var body: some View {
        Picker("common.receiver", selection: $receiver.channel) {
            ForEach(ReceiveAudioChannel.allCases, id: \.self) { channel in
                Text(verbatim: channel.title).tag(channel)
                    .selectionDisabled(channel == .sub && subUnavailableReason != nil)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(subUnavailableReason ?? String(localized: "digiWindow.whichAudio"))
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

// MARK: - Settings row

private struct DigiSettingsRow: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var receiver: DigiReceiver
    @State private var isReadingRigTones = false

    var body: some View {
        HStack(spacing: 14) {
            if receiver.mode == .rtty {
                Picker("digiWindow.shift", selection: $receiver.rttyShiftHz) {
                    ForEach(RTTYSettings.shifts, id: \.self) { shift in
                        Text(verbatim: "\(Int(shift)) Hz").tag(shift)
                    }
                }
                .fixedSize()
                Picker("digiWindow.baud", selection: $receiver.rttyBaud) {
                    ForEach(RTTYSettings.bauds, id: \.self) { baud in
                        Text(verbatim: baud == 45.45 ? "45.45" : "\(Int(baud))").tag(baud)
                    }
                }
                .fixedSize()
                Toggle("digiWindow.reverse", isOn: $receiver.rttyReverse)
                    .help("digiWindow.reverseHelp")
                Toggle(isOn: $receiver.rttyUnshiftOnSpace) {
                    Text(verbatim: "USOS")
                }
                .help("digiWindow.unshiftOnSpaceHelp")
            }
            Toggle(isOn: $receiver.afcEnabled) {
                Text(verbatim: "AFC")
            }
            .help("digiWindow.afcHelp")
            HStack(spacing: 6) {
                Text("digiWindow.squelch")
                Slider(value: $receiver.squelch, in: 0...0.9)
                    .frame(width: 110)
            }
            .help("digiWindow.squelchHelp")
            Spacer()
            Button {
                Task { await useRigTones() }
            } label: {
                Label("digiWindow.rigTones", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("digiWindow.rigTonesHelp")
            .disabled(hub.connectionState != .connected || isReadingRigTones)
        }
        .toggleStyle(.checkbox)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// RTTY: the rig's MARK FREQUENCY and SHIFT (MODE RTTY, EX010514/15);
    /// in the rig's RTTY mode the space tone is assumed to sit above the
    /// mark, as on the classic 2125/2295 Hz pair. PSK: its PSK TONE
    /// (MODE DATA, EX010417).
    private func useRigTones() async {
        isReadingRigTones = true
        defer { isReadingRigTones = false }
        if receiver.mode == .rtty {
            guard let markCode = await hub.readMenuItem(p1: 1, p2: 5, p3: 14).flatMap(Int.init),
                  let shiftCode = await hub.readMenuItem(p1: 1, p2: 5, p3: 15).flatMap(Int.init),
                  RTTYSettings.shifts.indices.contains(shiftCode)
            else {
                receiver.errorMessage = String(localized: "digiWindow.rigTonesFailed")
                return
            }
            let mark: Double = markCode == 0 ? 1275 : 2125
            let shift = RTTYSettings.shifts[shiftCode]
            receiver.rttyShiftHz = shift
            receiver.setCenter(mark + shift / 2)
        } else {
            guard let toneCode = await hub.readMenuItem(p1: 1, p2: 4, p3: 17).flatMap(Int.init) else {
                receiver.errorMessage = String(localized: "digiWindow.rigTonesFailed")
                return
            }
            receiver.setCenter(toneCode == 0 ? 1000 : 1500)
        }
    }
}

// MARK: - Status line

private struct DigiStatusLine: View {
    @EnvironmentObject private var receiver: DigiReceiver
    @EnvironmentObject private var webSDRSource: WebSDRAudioSource
    @EnvironmentObject private var localSDRSource: LocalSDRAudioSource
    @ObservedObject var meters: DigiMeterStore

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(Int(meters.trackedHz.rounded())) Hz")
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 70, alignment: .leading)
            HStack(spacing: 6) {
                Text("digiWindow.quality")
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(meters.quality))
                    .tint(Double(meters.quality) >= receiver.squelch ? .green : .secondary)
                    .frame(width: 90)
            }
            if let note {
                Text(note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var note: String? {
        guard !receiver.isDecodingFile else { return nil }
        if receiver.isPausedForTransmit {
            return String(localized: "common.pausedWhileTransmitting")
        }
        if let mode = receiver.unsuitableSourceMode {
            return String(localized: "digiWindow.sourceIsIn \(receiver.channel.title) \(mode.displayName)")
        }
        if receiver.channel == .myKiwiSDR {
            switch localSDRSource.status {
            case .receiving: return nil
            case .notConnected: return String(localized: "common.myKiwiSDRNotConnected")
            case .silent: return String(localized: "common.myKiwiSDRSilent")
            }
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
}

// MARK: - Decoded text

/// Received text, with this station's own transmissions in red (as in
/// fldigi). Callsigns in received text are links that fill the send
/// pane's Their call (`CWCallsigns`, the CW window's rule).
private struct DigiDecodedTextView: View {
    @EnvironmentObject private var receiver: DigiReceiver
    @EnvironmentObject private var sender: DigiSender

    var body: some View {
        ScrollView {
            Group {
                if receiver.runs.isEmpty {
                    Text("digiWindow.placeholder")
                        .foregroundStyle(.secondary)
                } else {
                    Text(attributed)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 17, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding()
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            guard let call = CWCallsigns.call(from: url) else { return .systemAction }
            sender.theirCall = call
            return .handled
        })
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for run in receiver.runs {
            var part = AttributedString(run.text)
            if run.isTransmit {
                part.foregroundColor = .red
            } else {
                Self.linkCallsigns(in: run.text, attributed: &part)
            }
            result += part
        }
        return result
    }

    /// PSK is often typed in lowercase, so calls are found in the
    /// uppercased text (same offsets for ASCII; skipped otherwise).
    private static func linkCallsigns(in text: String, attributed: inout AttributedString) {
        let upper = text.uppercased()
        guard upper.utf8.count == text.utf8.count else { return }
        for range in CWCallsigns.ranges(in: upper, excluding: StationSettings.callsign) {
            let start = upper.utf8.distance(from: upper.startIndex, to: range.lowerBound)
            let length = upper.utf8.distance(from: range.lowerBound, to: range.upperBound)
            let lower = attributed.utf8.index(attributed.startIndex, offsetBy: start)
            let upperBound = attributed.utf8.index(lower, offsetBy: length)
            guard let url = CWCallsigns.url(for: upper[range]) else { continue }
            attributed[lower..<upperBound].link = url
            attributed[lower..<upperBound].underlineStyle = .single
        }
    }
}

import FTX1Core
import FreeDVKit
import SwiftUI
import UniformTypeIdentifiers

/// Tools → FreeDV (`Window(id: "freedv")` in `FTX1RemoteMacApp`): FreeDV
/// RADE V1 from MAIN, SUB, the WebSDR window or the MyKiwiSDR window,
/// decoded to speech on the Mac's audio output, with the callsigns heard
/// at each end-of-over, and transmit from the Mac's microphone (TX/RX, or
/// hold the space bar) — see CLAUDE.md "Digital modes — FreeDV".
///
/// Decoding runs only while this window is open, like the other decoders.
/// The status line observes `FreeDVReceiver.status` (about twenty updates
/// a second); the rest of the window observes the receiver.
struct FreeDVWindowView: View {
    @EnvironmentObject private var receiver: FreeDVReceiver
    @EnvironmentObject private var sender: FreeDVSender
    @Environment(\.openWindow) private var openWindow
    @State private var isShowingFileImporter = false
    @FocusState private var windowFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            FreeDVHeader(isShowingFileImporter: $isShowingFileImporter)
            Divider()
            FreeDVTransmitRow()
            Divider()
            FreeDVStatusLine(status: receiver.status)
            Divider()
            FreeDVNotes()
            FreeDVHeardTable()
            if receiver.isDecodingFile || receiver.lastDecodedFile != nil {
                Divider()
                fileLine
            }
        }
        .navigationTitle("FreeDV")
        .frame(minWidth: 720, minHeight: 380)
        // Hold the space bar to talk (while this window has the keyboard).
        .focusable()
        .focusEffectDisabled()
        .focused($windowFocused)
        .onKeyPress(.space, phases: [.down, .up]) { press in
            if press.phase == .down {
                if sender.state == .idle { sender.start(.momentary) }
            } else {
                sender.releaseMomentary()
            }
            return .handled
        }
        .onAppear {
            receiver.start()
            windowFocused = true
        }
        .onDisappear {
            // Not left keyed with nobody watching: closing ends the over.
            sender.finish()
            receiver.stop()
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.audio],
            onCompletion: { result in
                switch result {
                case .success(let url): receiver.decodeFile(at: url)
                case .failure(let error): receiver.errorMessage = error.localizedDescription
                }
            }
        )
        .fileDialogDefaultDirectory(AudioRecorder.recordingsDirectory)
        .alert("FreeDV", isPresented: Binding(
            get: { receiver.errorMessage != nil },
            set: { if !$0 { receiver.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(receiver.errorMessage ?? "")
        }
    }

    @ViewBuilder private var fileLine: some View {
        HStack(spacing: 10) {
            if receiver.isDecodingFile {
                ProgressView().controlSize(.small)
                Text("freeDVWindow.decodingFile")
            } else if let file = receiver.lastDecodedFile {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("freeDVWindow.savedDecodedSpeech \(file.lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("freeDVWindow.showRecordings") {
                    openWindow(id: "recordings")
                }
                .fixedSize()
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - Header

private struct FreeDVHeader: View {
    @EnvironmentObject private var receiver: FreeDVReceiver
    @Binding var isShowingFileImporter: Bool

    var body: some View {
        HStack(spacing: 12) {
            FreeDVChannelPicker()
            Spacer()
            Button {
                receiver.isMuted.toggle()
            } label: {
                Image(systemName: receiver.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .help(receiver.isMuted ? "freeDVWindow.unmuteHelp" : "freeDVWindow.muteHelp")
            Slider(value: $receiver.volume, in: 0...1) {
                Text("freeDVWindow.volume")
            }
            .labelsHidden()
            .frame(width: 110)
            .disabled(receiver.isMuted)
            .help("freeDVWindow.volume")
            Button {
                isShowingFileImporter = true
            } label: {
                Label("cwWindow.openAudioFile", systemImage: "waveform")
            }
            .fixedSize()
            .keyboardShortcut("o")
            .help("freeDVWindow.decodeARecording")
            .disabled(receiver.isDecodingFile)
            Button {
                receiver.clearHeard()
            } label: {
                Label("common.clear", systemImage: "trash")
            }
            .fixedSize()
            .keyboardShortcut("k")
            .help("freeDVWindow.clearTheList")
            .disabled(receiver.heard.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// MAIN/SUB/WebSDR/MyKiwiSDR. Its own view so observing `hub` (for
/// single-receive display) re-renders only this picker.
private struct FreeDVChannelPicker: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var receiver: FreeDVReceiver

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
        .help(subUnavailableReason ?? String(localized: "freeDVWindow.whichAudio"))
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

// MARK: - Transmit

/// TX/RX, elapsed time, microphone meter, output level, and what the
/// end-of-over will carry. Observes the sender only (its state changes
/// rarely; the meter has its own store).
private struct FreeDVTransmitRow: View {
    @EnvironmentObject private var sender: FreeDVSender
    @AppStorage(StationSettings.callsignKey) private var callsign = ""

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if sender.state == .idle { sender.start(.toggle) } else { sender.finish() }
            } label: {
                Label(sender.state == .idle ? "freeDVWindow.transmit" : "freeDVWindow.receive",
                      systemImage: sender.state == .idle ? "mic.fill" : "ear")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(sender.state == .idle ? .accentColor : .red)
            .keyboardShortcut("t")
            .disabled(sender.state == .finishing)
            .help("freeDVWindow.transmitHelp")

            if let startedAt = sender.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(verbatim: Self.elapsed(context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
                FreeDVMicMeter(level: sender.micLevel)
            } else {
                Text("freeDVWindow.holdSpace")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("freeDVWindow.level")
                Slider(value: $sender.levelDB, in: FreeDVSender.levelRange, step: 1)
                    .frame(width: 100)
                Text(verbatim: "\(Int(sender.levelDB)) dB")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .help("freeDVWindow.levelHelp")

            Spacer()
            if let message = sender.statusMessage {
                Text(message)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if callsign.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("freeDVWindow.noCallsign")
                    .foregroundStyle(.secondary)
            } else {
                Text("freeDVWindow.sendsCallsign \(callsign.uppercased())")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The microphone's peak, −60…0 dBFS: green, yellow above −12, red above
/// −3. The only view observing `FreeDVMicLevelStore`.
private struct FreeDVMicMeter: View {
    @ObservedObject var level: FreeDVMicLevelStore

    var body: some View {
        let fraction = CGFloat((level.peakDB + 60) / 60)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.2))
            Capsule()
                .fill(level.peakDB > -3 ? Color.red : (level.peakDB > -12 ? Color.yellow : Color.green))
                .frame(width: max(0, min(1, fraction)) * 90)
        }
        .frame(width: 90, height: 8)
        .help("freeDVWindow.micLevelHelp")
    }
}

// MARK: - Status

/// Sync, SNR and tuning offset: the only view observing `status`.
private struct FreeDVStatusLine: View {
    @ObservedObject var status: FreeDVStatusStore

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.sync ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(status.sync ? "freeDVWindow.receiving" : "freeDVWindow.noSignal")
                    .fontWeight(status.sync ? .semibold : .regular)
            }
            .frame(minWidth: 150, alignment: .leading)
            Group {
                Text("freeDVWindow.snr \(Int(status.snrDB.rounded()))")
                    .frame(minWidth: 80, alignment: .leading)
                Text("freeDVWindow.offset \(Self.signed(status.frequencyOffsetHz))")
                    .help("freeDVWindow.offsetHelp")
            }
            .monospacedDigit()
            .foregroundStyle(status.sync ? .primary : .secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private static func signed(_ hz: Float) -> String {
        let value = Int(hz.rounded())
        return value > 0 ? "+\(value)" : "\(value)"
    }
}

/// What might keep FreeDV from being heard, and what the window is doing
/// to the other audio.
private struct FreeDVNotes: View {
    @EnvironmentObject private var receiver: FreeDVReceiver
    @EnvironmentObject private var webSDRSource: WebSDRAudioSource
    @EnvironmentObject private var localSDRSource: LocalSDRAudioSource

    var body: some View {
        let notes = self.notes
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            Divider()
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if receiver.isPausedForTransmit {
            notes.append(String(localized: "common.pausedWhileTransmitting"))
        }
        if let hint = receiver.modeHint {
            let source = receiver.channel.title, mode = hint.mode.displayName
            switch hint.expected {
            case .lower: notes.append(String(localized: "freeDVWindow.useLSB \(source) \(mode)"))
            case .upper: notes.append(String(localized: "freeDVWindow.useUSB \(source) \(mode)"))
            case .either: notes.append(String(localized: "freeDVWindow.useSSB \(source) \(mode)"))
            }
        }
        if receiver.isReceivingVoice, receiver.channel == .main || receiver.channel == .sub {
            notes.append(String(localized: "freeDVWindow.rigAudioMuted \(receiver.channel.title)"))
        }
        switch receiver.channel {
        case .main, .sub:
            break
        case .myKiwiSDR:
            switch localSDRSource.status {
            case .receiving: notes.append(String(localized: "freeDVWindow.sdrStillPlays"))
            case .notConnected: notes.append(String(localized: "common.myKiwiSDRNotConnected"))
            case .silent: notes.append(String(localized: "common.myKiwiSDRSilent"))
            }
        case .webSDR:
            switch webSDRSource.status {
            case .stopped: break
            case .capturing: notes.append(String(localized: "freeDVWindow.sdrStillPlays"))
            case .waitingForWebSDR: notes.append(String(localized: "common.waitingForTheWebSDR"))
            case .silent: notes.append(String(localized: "cwWindow.webSDRIsSilentCheck"))
            case .failed(let message): notes.append(String(localized: "cwWindow.cantCaptureWebSDRAudio \(message)"))
            }
        }
        return notes
    }
}

// MARK: - Heard list

private struct FreeDVHeardTable: View {
    @EnvironmentObject private var receiver: FreeDVReceiver

    var body: some View {
        Table(receiver.heard) {
            TableColumn("freeDVWindow.timeUTC") { station in
                Text(verbatim: Self.timeFormatter.string(from: station.time))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80, max: 100)
            TableColumn("freeDVWindow.callsign") { station in
                Text(verbatim: station.callsign)
                    .font(.body.monospaced().weight(.semibold))
                    .textSelection(.enabled)
            }
            .width(min: 90, ideal: 110)
            TableColumn(Text(verbatim: "SNR")) { station in
                Text(verbatim: station.snrDB.map { "\(Int($0.rounded())) dB" } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 60, max: 80)
            TableColumn("freeDVWindow.frequency") { station in
                Text(verbatim: station.frequencyHz.map { FrequencyFormat.dotted($0) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 120, max: 150)
            TableColumn("freeDVWindow.source") { station in
                if station.fromFile {
                    Text("freeDVWindow.fromFile")
                } else {
                    Text(verbatim: station.channel.title)
                }
            }
            .width(min: 70, ideal: 90)
        }
        .overlay {
            if receiver.heard.isEmpty {
                Text("freeDVWindow.placeholder")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(40)
                    .allowsHitTesting(false)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

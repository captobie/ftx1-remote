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
    @EnvironmentObject private var reporter: FreeDVReporter
    @Environment(\.openWindow) private var openWindow
    @State private var isShowingFileImporter = false
    @FocusState private var windowFocused: Bool
    @AppStorage("freedv.listTab") private var listTab = FreeDVListTab.heard

    var body: some View {
        VStack(spacing: 0) {
            FreeDVHeader(isShowingFileImporter: $isShowingFileImporter)
            Divider()
            FreeDVTransmitRow()
            Divider()
            FreeDVReporterRow()
            Divider()
            FreeDVStatusLine(status: receiver.status)
            Divider()
            FreeDVNotes()
            if reporter.enabled {
                Picker("freeDVWindow.list", selection: $listTab) {
                    Text("freeDVWindow.heardTab \(receiver.heard.count)").tag(FreeDVListTab.heard)
                    Text("freeDVWindow.reporterTab \(reporter.stations.count)").tag(FreeDVListTab.reporter)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 6)
            }
            if reporter.enabled, listTab == .reporter {
                FreeDVReporterTable()
            } else {
                FreeDVHeardTable()
            }
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
            reporter.setActive(true)
            windowFocused = true
        }
        .onDisappear {
            // Not left keyed with nobody watching: closing ends the over.
            sender.finish()
            receiver.stop()
            reporter.setActive(false)
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

// MARK: - FreeDV Reporter

enum FreeDVListTab: String {
    case heard
    case reporter
}

/// The opt-in checkbox, the connection's state and our status message.
private struct FreeDVReporterRow: View {
    @EnvironmentObject private var reporter: FreeDVReporter
    @State private var draft = ""
    @FocusState private var editingMessage: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("freeDVWindow.reportToFreeDVReporter", isOn: $reporter.enabled)
                .toggleStyle(.checkbox)
                .help("freeDVWindow.reportHelp")
            if reporter.enabled {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                TextField("freeDVWindow.message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($editingMessage)
                    .onSubmit { reporter.message = draft }
                    .onChange(of: editingMessage) { _, editing in
                        if !editing { reporter.message = draft }
                    }
                    .help("freeDVWindow.messageHelp")
            } else {
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .onAppear { draft = reporter.message }
    }

    private var statusColor: Color {
        switch reporter.status {
        case .connected: .green
        case .connecting: .yellow
        case .retrying, .needsStation: .orange
        case .off: .secondary
        }
    }

    private var statusText: String {
        switch reporter.status {
        case .off: ""
        case .needsStation: String(localized: "freeDVWindow.reporterNeedsStation")
        case .connecting: String(localized: "freeDVWindow.reporterConnecting")
        case .connected: String(localized: "freeDVWindow.reporterConnected \(reporter.stations.count)")
        case .retrying(let reason): String(localized: "freeDVWindow.reporterRetrying \(reason)")
        }
    }
}

/// Everyone on FreeDV Reporter. Double-click (or the context menu) tunes
/// MAIN there. Observes only the reporter.
private struct FreeDVReporterTable: View {
    @EnvironmentObject private var reporter: FreeDVReporter
    @EnvironmentObject private var hub: HubService
    @State private var selection: FreeDVReporterStation.ID?
    @State private var tuneError: String?

    var body: some View {
        Table(reporter.stations, selection: $selection) {
            TableColumn("freeDVWindow.callsign") { station in
                Text(verbatim: station.callsign)
                    .font(.body.monospaced().weight(.semibold))
            }
            .width(min: 80, ideal: 95)
            TableColumn("freeDVWindow.grid") { station in
                Text(verbatim: station.gridSquare)
                    .monospaced()
            }
            .width(min: 55, ideal: 65, max: 80)
            TableColumn("freeDVWindow.frequency") { station in
                Text(verbatim: station.frequencyHz.map { FrequencyFormat.dotted($0) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 95, ideal: 110, max: 130)
            TableColumn("freeDVWindow.mode") { station in
                HStack(spacing: 4) {
                    Text(verbatim: station.mode ?? (station.receiveOnly ? "RX" : "—"))
                    if station.transmitting {
                        Text(verbatim: "TX")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            .width(min: 70, ideal: 90, max: 110)
            TableColumn("freeDVWindow.lastHeard") { station in
                if let call = station.lastHeardCallsign {
                    Text(verbatim: "\(call) \(station.lastHeardSNR.map { "\(Int($0.rounded())) dB" } ?? "")")
                        .monospacedDigit()
                } else {
                    Text(verbatim: "")
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("freeDVWindow.statusMessage") { station in
                Text(verbatim: station.message)
                    .foregroundStyle(.secondary)
                    .help(station.message)
            }
            TableColumn("freeDVWindow.updated") { station in
                Text(verbatim: station.lastUpdate.map { Self.timeFormatter.string(from: $0) } ?? "")
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 60, max: 70)
        }
        .contextMenu(forSelectionType: FreeDVReporterStation.ID.self) { ids in
            if let station = station(ids), let hz = station.frequencyHz {
                Button("freeDVWindow.tuneMain \(FrequencyFormat.dotted(hz))") { tune(station) }
            }
        } primaryAction: { ids in
            if let station = station(ids) { tune(station) }
        }
        .overlay {
            if reporter.stations.isEmpty {
                Text(reporter.status == .connected ? "freeDVWindow.reporterEmpty" : "freeDVWindow.reporterNotConnected")
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .alert("FreeDV", isPresented: Binding(get: { tuneError != nil }, set: { if !$0 { tuneError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tuneError ?? "")
        }
    }

    private func station(_ ids: Set<FreeDVReporterStation.ID>) -> FreeDVReporterStation? {
        guard let id = ids.first else { return nil }
        return reporter.stations.first { $0.id == id }
    }

    private func tune(_ station: FreeDVReporterStation) {
        guard let hz = station.frequencyHz else { return }
        tuneError = hub.tuneFromFreeDVReporter(frequencyHz: hz)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
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

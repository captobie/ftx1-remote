import AppKit
import FTX1Core
import Sparkle
import SwiftUI

/// App settings, presented via the standard macOS `Settings` scene (app
/// menu → Settings…, ⌘,) rather than a sheet from `ContentView`.
///
/// The "rigctld" tab's edits are held in local `@State`, not written back
/// to `RigctldSettings` until "Done" — so "Cancel" can discard them (e.g.
/// an accidental empty binary path) rather than the old `@AppStorage`
/// bindings, which wrote on every keystroke with no way to back out. The
/// "Appearance" tab has no such failure mode (there's no invalid theme),
/// so it applies instantly via `@AppStorage` instead, the same way macOS's
/// own System Settings appearance picker does — Cancel/Done only govern
/// the rigctld tab.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hub: HubService

    let updater: SPUUpdater

    @State private var connectionMode = RigctldSettings.connectionMode
    @State private var remoteHost = RigctldSettings.remoteHost
    @State private var binaryPath = RigctldSettings.binaryPath
    @State private var modelNumber = RigctldSettings.modelNumber
    @State private var devicePath = RigctldSettings.devicePath
    @State private var baudRate = RigctldSettings.baudRate
    @State private var pttPort = RigctldSettings.pttPort

    @State private var showRestartPrompt = false

    @State private var availableDevices: [String] = []
    @State private var availableBinaryPaths: [String] = []

    /// Common CAT baud rates for hamlib-controlled rigs.
    private static let baudRateOptions = [4800, 9600, 19200, 38400, 57600, 115200]

    /// Where `rigctld` typically lands depending on how it was installed.
    private static let commonBinaryPaths = [
        "/opt/homebrew/bin/rigctld",
        "/usr/local/bin/rigctld",
        "/opt/local/bin/rigctld",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TabView {
                rigctldTab
                    .tabItem { Text("rigctld") }
                AudioSettingsTab()
                    .tabItem { Text("Audio") }
                C4FMSettingsTab()
                    .tabItem { Text("C4FM") }
                APRSSettingsTab()
                    .tabItem { Text("APRS") }
                StationSettingsTab()
                    .tabItem { Text("Station") }
                LogbookSettingsTab()
                    .tabItem { Text("Logbook") }
                HomeFrequencySettingsTab()
                    .tabItem { Text("Home Freq") }
                PollingSettingsTab()
                    .tabItem { Text("Polling") }
                AppearanceSettingsTab()
                    .tabItem { Text("Appearance") }
                UpdatesSettingsTab(updater: updater)
                    .tabItem { Text("Updates") }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        // Flexible so the window can be resized — SwiftUI's `Settings`
        // window is fixed-size otherwise, and the Local rigctld fields
        // didn't fit. The ideal size is what it opens at.
        .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity,
               minHeight: 320, idealHeight: 520, maxHeight: .infinity)
        .background(ResizableWindow())
        .onAppear {
            refreshAvailableDevices()
            refreshAvailableBinaryPaths()
        }
        .alert("Restart FTX1Remote?", isPresented: $showRestartPrompt) {
            Button("Restart Now") { AppDelegate.relaunch() }
                .keyboardShortcut(.defaultAction)
            Button("Later", role: .cancel) { dismiss() }
        } message: {
            Text("The new connection settings take effect after a restart. Until then FTX1Remote keeps using \(Self.describe(RigctldSettings.activeConnectionMode, host: RigctldSettings.activeRemoteHost)).")
        }
    }

    /// Whether the saved connection differs from what this launch is
    /// running with. The remote host only counts in `.remote` mode — in
    /// `.local` it isn't used, so editing it needs no restart.
    private var connectionNeedsRestart: Bool {
        if connectionMode != RigctldSettings.activeConnectionMode { return true }
        return connectionMode == .remote && remoteHost != RigctldSettings.activeRemoteHost
    }

    private static func describe(_ mode: RigctldSettings.ConnectionMode, host: String) -> String {
        switch mode {
        case .local: "the local (USB) connection"
        case .remote: host.isEmpty ? "the remote (Pi) connection" : "the remote connection to \(host)"
        }
    }

    private var rigctldTab: some View {
        ScrollView {
            Form {
                // Applies immediately via a live binding into `hub`, unlike
                // every other control on this tab (which waits for "Done") —
                // it's a safety cutoff, not a connection parameter, so
                // "Cancel" must never be able to silently leave it un-applied.
                // See `HubService.transmitEnabled`'s doc comment for what it
                // gates and the force-unkey behavior when switched off
                // mid-transmission.
                Toggle("Enable Transmit", isOn: $hub.transmitEnabled)
                Text("When off, PTT, MOX, antenna tuning, and CW MESSAGE playback are disabled for every connected client. Applies immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Connection", selection: $connectionMode) {
                    Text("Local (USB)").tag(RigctldSettings.ConnectionMode.local)
                    Text("Remote (Pi)").tag(RigctldSettings.ConnectionMode.remote)
                }
                .pickerStyle(.segmented)
                Text("Changing this requires restarting FTX1Remote — you'll be offered a restart when you click Done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch connectionMode {
                case .local:
                    HStack {
                        Picker("Binary path", selection: $binaryPath) {
                            ForEach(availableBinaryPaths, id: \.self) { path in
                                Text(path).tag(path)
                            }
                        }
                        Button("Choose…") { chooseBinaryPath() }
                    }
                    TextField("Model number", value: $modelNumber, format: .number.grouping(.never))
                    Picker("Serial device", selection: $devicePath) {
                        ForEach(availableDevices, id: \.self) { device in
                            Text((device as NSString).lastPathComponent).tag(device)
                        }
                    }
                    Picker("Baud rate", selection: $baudRate) {
                        ForEach(baudRateOptionsIncludingCurrent, id: \.self) { rate in
                            Text("\(rate)").tag(rate)
                        }
                    }
                    Picker("PTT port", selection: $pttPort) {
                        Text("None (use CAT on main port)").tag("")
                        ForEach(availableDevices, id: \.self) { device in
                            Text((device as NSString).lastPathComponent).tag(device)
                        }
                    }
                case .remote:
                    TextField("Pi hostname", text: $remoteHost, prompt: Text("e.g. raspberrypi.tailnet-name.ts.net"))
                        .frame(maxWidth: 280)
                }

                RigctldVersionBox(connectionMode: connectionMode, binaryPath: binaryPath, remoteHost: remoteHost)
            }
            .padding(.top, 8)
        }
    }

    private func save() {
        RigctldSettings.connectionMode = connectionMode
        RigctldSettings.remoteHost = remoteHost
        RigctldSettings.binaryPath = binaryPath
        RigctldSettings.modelNumber = modelNumber
        RigctldSettings.devicePath = devicePath
        RigctldSettings.baudRate = baudRate
        RigctldSettings.pttPort = pttPort
        // Saved either way; "Later" just keeps this launch on its current
        // connection until the next quit/reopen.
        if connectionNeedsRestart {
            showRestartPrompt = true
        } else {
            dismiss()
        }
    }

    /// Opens a file browser rooted at the standard Homebrew bin directory,
    /// for the case where `rigctld` lives somewhere none of
    /// `commonBinaryPaths` guessed.
    private func chooseBinaryPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        binaryPath = url.path
        if !availableBinaryPaths.contains(binaryPath) {
            availableBinaryPaths.append(binaryPath)
            availableBinaryPaths.sort()
        }
    }

    /// The standard baud rate list, plus the currently configured value if
    /// it's something else (e.g. set by hand before this dropdown existed)
    /// — so opening this sheet never silently discards an existing choice.
    private var baudRateOptionsIncludingCurrent: [Int] {
        Self.baudRateOptions.contains(baudRate)
            ? Self.baudRateOptions
            : (Self.baudRateOptions + [baudRate]).sorted()
    }

    /// Scans `/dev` for serial devices (macOS exposes each serial adapter as
    /// both a "tty." and "cu." entry) so the dropdown reflects whatever's
    /// actually plugged in right now, rather than a hardcoded guess. Feeds
    /// both the "Serial device" and "PTT port" pickers, since they're
    /// drawing from the same universe of devices. Keeps the currently
    /// configured device(s) in the list even if unplugged, so an offline
    /// rig/interface doesn't lose its setting.
    private func refreshAvailableDevices() {
        var devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
            .filter { $0.hasPrefix("tty.") || $0.hasPrefix("cu.") }
            .map { "/dev/" + $0 }
            .sorted() ?? []
        for configured in [devicePath, pttPort] where !configured.isEmpty && !devices.contains(configured) {
            devices.append(configured)
        }
        availableDevices = devices.sorted()
    }

    /// Scans `commonBinaryPaths` for whichever actually exist on disk, so
    /// the dropdown always offers a real, working path to fall back to even
    /// if the configured one got cleared or typo'd by hand. Keeps the
    /// current value in the list too, so a nonstandard install location
    /// isn't silently dropped.
    private func refreshAvailableBinaryPaths() {
        var paths = Self.commonBinaryPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !binaryPath.isEmpty, !paths.contains(binaryPath) {
            paths.append(binaryPath)
        }
        availableBinaryPaths = paths.sorted()
    }
}

/// The rigctld tab's version box, following the tab's *edited* values (not
/// the saved ones), so picking another binary or typing a host shows that
/// one's version before Done. Two sources: "Installed" (Local only) runs the
/// picked binary with `--version`; "Running" asks whatever rigctld is
/// listening on port 4532 (localhost, or the Pi) over its own short-lived
/// connection (`RigctldClient.readHamlibVersion`) — the only way to see the
/// Pi's version, and in Local mode it can differ from the binary when an
/// already-running rigctld was adopted.
private struct RigctldVersionBox: View {
    let connectionMode: RigctldSettings.ConnectionMode
    let binaryPath: String
    let remoteHost: String

    private enum Lookup: Equatable {
        case checking
        case found(String)
        case unavailable(String)
    }

    private struct Inputs: Equatable {
        var connectionMode: RigctldSettings.ConnectionMode
        var binaryPath: String
        var remoteHost: String
        var refreshCount: Int
    }

    @State private var installed: Lookup = .checking
    @State private var running: Lookup = .checking
    @State private var refreshCount = 0

    var body: some View {
        GroupBox("Version") {
            VStack(alignment: .leading, spacing: 6) {
                if connectionMode == .local {
                    row("Installed", installed)
                }
                row(connectionMode == .local ? "Running" : "Running on Pi", running)
                HStack {
                    Spacer()
                    Button("Refresh") { refreshCount += 1 }
                        .disabled(installed == .checking || running == .checking)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .task(id: Inputs(connectionMode: connectionMode, binaryPath: binaryPath, remoteHost: remoteHost, refreshCount: refreshCount)) {
            await lookUp()
        }
    }

    private func row(_ label: String, _ lookup: Lookup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 90, alignment: .leading)
            switch lookup {
            case .checking:
                Text("Checking…").foregroundStyle(.secondary)
            case .found(let version):
                Text(version).textSelection(.enabled)
            case .unavailable(let reason):
                Text(reason).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func lookUp() async {
        installed = .checking
        running = .checking
        // Typing a host restarts this task per keystroke; wait until it
        // settles before connecting anywhere.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        switch connectionMode {
        case .local:
            let binaryResult = await Self.binaryVersion(atPath: binaryPath)
            guard !Task.isCancelled else { return }
            installed = binaryResult
            let liveResult = await Self.runningVersion(host: "127.0.0.1")
            guard !Task.isCancelled else { return }
            running = liveResult
        case .remote:
            let host = remoteHost.trimmingCharacters(in: .whitespaces)
            let result: Lookup = host.isEmpty ? .unavailable("No Pi hostname set") : await Self.runningVersion(host: host)
            guard !Task.isCancelled else { return }
            running = result
        }
    }

    /// `rigctld --version` prints e.g. "rigctld Hamlib 4.7.2 2026-06-21T…
    /// SHA=40f63488f 64-bit"; the leading program name is dropped to match
    /// what `\dump_caps` reports for the running one.
    nonisolated private static func binaryVersion(atPath path: String) async -> Lookup {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .unavailable("No rigctld at this path")
        }
        return await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["--version"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                return .unavailable("Couldn't run rigctld")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let line = (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let version = line.hasPrefix("rigctld ") ? String(line.dropFirst("rigctld ".count)) : line
            return version.isEmpty ? .unavailable("No version reported") : .found(version)
        }.value
    }

    nonisolated private static func runningVersion(host: String) async -> Lookup {
        let client = RigctldClient(host: host, port: 4532)
        // A refused connection doesn't fail an NWConnection, it waits — so
        // "nothing listening" takes the whole timeout. Localhost answers at
        // once if anything is there; the Pi gets the hub's usual 5 s.
        let isLocal = host == "127.0.0.1"
        do {
            try await client.connect(timeout: .seconds(isLocal ? 1 : 5))
        } catch {
            return .unavailable(isLocal ? "Not running" : "Unreachable")
        }
        do {
            if let version = try await client.readHamlibVersion() {
                return .found(version)
            }
            return .unavailable("No version reported")
        } catch {
            await client.disconnect()
            return .unavailable("No reply from rigctld")
        }
    }
}

/// Sound card input selection, ahead of features that will need it (e.g. a
/// waterfall/spectrum display). Applies instantly via `@AppStorage`, same
/// as `AppearanceSettingsTab` below — picking from an enumerated device
/// list has no invalid-input failure mode, unlike the rigctld tab's free-
/// text fields.
private struct AudioSettingsTab: View {
    @AppStorage(AudioInputSettings.deviceUIDKey) private var inputDeviceUID = ""
    @AppStorage(AudioOutputSettings.deviceUIDKey) private var outputDeviceUID = ""
    @AppStorage(TXAudioOutputSettings.deviceUIDKey) private var txOutputDeviceUID = ""
    @State private var availableInputDevices: [AudioInputDevice] = []
    @State private var availableOutputDevices: [AudioOutputDevice] = []

    var body: some View {
        Form {
            Picker("Input device", selection: $inputDeviceUID) {
                Text("System Default").tag("")
                ForEach(availableInputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Picker("Output device", selection: $outputDeviceUID) {
                Text("System Default").tag("")
                ForEach(availableOutputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Text("Changing this requires reconnecting (or restarting FTX1Remote) to take effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Transmit audio output", selection: $txOutputDeviceUID) {
                Text("None").tag("")
                ForEach(availableOutputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Text("Local mode: where an iPad's PTT microphone is played — pick the FTX-1's USB audio device. Remote mode sends it to the Pi instead. Takes effect on the next transmission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .onAppear {
            refreshAvailableInputDevices()
            refreshAvailableOutputDevices()
        }
    }

    /// Keeps the currently configured device in the list even if it's not
    /// currently plugged in, so an offline sound card doesn't lose its
    /// setting — same reasoning as `SettingsView.refreshAvailableDevices`.
    private func refreshAvailableInputDevices() {
        var devices = AudioInputDeviceLister.availableInputDevices()
        if !inputDeviceUID.isEmpty, !devices.contains(where: { $0.uid == inputDeviceUID }) {
            devices.append(AudioInputDevice(id: 0, uid: inputDeviceUID, name: "\(inputDeviceUID) (not connected)"))
        }
        availableInputDevices = devices
    }

    /// Same reasoning as `refreshAvailableInputDevices`.
    private func refreshAvailableOutputDevices() {
        var devices = AudioOutputDeviceLister.availableOutputDevices()
        for uid in [outputDeviceUID, txOutputDeviceUID] where !uid.isEmpty && !devices.contains(where: { $0.uid == uid }) {
            devices.append(AudioOutputDevice(id: 0, uid: uid, name: "\(uid) (not connected)"))
        }
        availableOutputDevices = devices
    }
}

/// WPSD hotspot callsign lookup — see `WPSDCallsignMonitor`. Applies
/// instantly via `@AppStorage`, same reasoning as `AudioSettingsTab`: an
/// invalid/incomplete host just causes harmless failed fetches (no
/// callsign shown), not a broken process launch like the rigctld tab's
/// binary path, so there's no accidental-edit risk worth a Cancel/Done
/// escape hatch here.
private struct C4FMSettingsTab: View {
    @AppStorage(WPSDSettings.enabledKey) private var enabled = false
    @AppStorage(WPSDSettings.hostKey) private var host = ""

    var body: some View {
        Form {
            Toggle("Show received callsign (via WPSD)", isOn: $enabled)
            TextField("Hotspot address", text: $host, prompt: Text("e.g. 192.168.1.50"))
        }
        .padding(.top, 8)
    }
}

/// Per-band HOME channel frequencies (see `HomeBand`/`HomeFrequencySettings`)
/// — the FM/C4FM menu page's HOME button jumps to whichever of these matches
/// the current frequency's band group, since the rig itself has no CAT way
/// to read/recall its own HOME channels. Applies instantly via `@AppStorage`,
/// same reasoning as `AudioSettingsTab`/`C4FMSettingsTab` — any value here is
/// a valid frequency, no invalid-input failure mode worth a Cancel/Done
/// escape hatch.
private struct HomeFrequencySettingsTab: View {
    var body: some View {
        Form {
            ForEach(HomeBand.allCases, id: \.self) { band in
                HomeFrequencyField(band: band)
            }
        }
        .padding(.top, 8)
    }
}

/// The operator's own callsign/grid — see `StationSettings`. Currently only
/// consumed by `FT8Spot` (stamped onto each decoded spot for a future PSK
/// Reporter upload, not built yet). Applies instantly via `@AppStorage`,
/// same reasoning as the other non-rigctld tabs: an empty or malformed
/// value just means a blank/garbage reporter field later, not a broken
/// process launch.
private struct StationSettingsTab: View {
    @AppStorage(StationSettings.callsignKey) private var callsign = ""
    @AppStorage(StationSettings.gridSquareKey) private var gridSquare = ""

    var body: some View {
        Form {
            TextField("Callsign", text: $callsign, prompt: Text("e.g. W1AW"))
            TextField("Grid square", text: $gridSquare, prompt: Text("e.g. FN31pr"))
        }
        .padding(.top, 8)
    }
}

/// External logbook — see `LogbookSettings`/`MacLoggerDX`. Applies
/// instantly via `@AppStorage` like the other non-rigctld tabs. The status
/// lines only report what can be seen from here (MacLoggerDX's process,
/// its preferences, its log file read-only); the UDP link can't be
/// checked without logging something, so there's no test send.
private struct LogbookSettingsTab: View {
    @AppStorage(LogbookSettings.loggerKey) private var loggerRawValue = LogbookSettings.Logger.none.rawValue
    @AppStorage(LogbookSettings.macLoggerDXLogPathKey) private var logPathOverride = ""
    @AppStorage(LogbookSettings.macLoggerDXUDPHostKey) private var udpHost = LogbookSettings.defaultUDPHost
    @AppStorage(LogbookSettings.macLoggerDXUDPPortKey) private var udpPort = LogbookSettings.defaultUDPPort

    @State private var status: Status?

    private struct Status {
        var isRunning: Bool
        var listensForWSJTX: Bool?
        var logPath: String?
        var summary: Result<MacLoggerDX.LogSummary, MacLoggerDX.LogError>?
    }

    private var logger: Binding<LogbookSettings.Logger> {
        Binding(
            get: { LogbookSettings.Logger(rawValue: loggerRawValue) ?? .none },
            set: { loggerRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Picker("Logger", selection: logger) {
                ForEach(LogbookSettings.Logger.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }

            if logger.wrappedValue == .macLoggerDX {
                macLoggerDXSection
            }
        }
        .padding(.top, 8)
        .task(id: TaskKey(logger: loggerRawValue, path: logPathOverride)) { await refresh() }
    }

    private struct TaskKey: Equatable {
        var logger: String
        var path: String
    }

    @ViewBuilder
    private var macLoggerDXSection: some View {
        Section {
            LabeledContent("File") {
                Text(status == nil ? "Checking…" : status?.logPath ?? "Not found")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(status?.logPath ?? "")
            }
            LabeledContent("Contents") {
                logSummaryText
            }
            HStack {
                Button("Choose…", action: chooseLogFile)
                if !logPathOverride.isEmpty {
                    Button("Use MacLoggerDX’s Log") { logPathOverride = "" }
                }
            }
        } header: {
            sectionHeader("Log file (read only)")
        }

        Section {
            TextField("Host", text: $udpHost, prompt: Text(LogbookSettings.defaultUDPHost))
                .frame(maxWidth: 240)
            TextField("Port", value: $udpPort, format: .number.grouping(.never))
                .frame(maxWidth: 120)
            LabeledContent("MacLoggerDX") {
                macLoggerDXStatusText
            }
            Button("Check Again") { Task { await refresh() } }
        } header: {
            sectionHeader("Logging (WSJT-X UDP)")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 12)
    }

    @ViewBuilder
    private var logSummaryText: some View {
        switch status?.summary {
        case nil:
            Text(status == nil ? "Checking…" : "—").foregroundStyle(.secondary)
        case .success(let summary):
            Text(Self.describe(summary))
        case .failure(let error):
            Text(error.description).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var macLoggerDXStatusText: some View {
        if let status {
            if !status.isRunning {
                Text("Not running").foregroundStyle(.orange)
            } else if status.listensForWSJTX == false {
                Text("Running, but not listening for WSJT-X UDP (turn it on in MacLoggerDX’s preferences)")
                    .foregroundStyle(.orange)
            } else {
                Text("Running")
            }
        } else {
            Text("Checking…").foregroundStyle(.secondary)
        }
    }

    private static func describe(_ summary: MacLoggerDX.LogSummary) -> String {
        let counts = "\(summary.qsoCount.formatted()) QSOs, \(summary.callCount.formatted()) calls"
        guard let last = summary.lastQSO else { return counts }
        return counts + ", last \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    private func refresh() async {
        guard logger.wrappedValue == .macLoggerDX else {
            status = nil
            return
        }
        let path = LogbookSettings.macLoggerDXLogPath
        // Off the main actor: the read can wait up to a second on
        // MacLoggerDX's lock.
        status = await Task.detached {
            Status(
                isRunning: MacLoggerDX.isRunning,
                listensForWSJTX: MacLoggerDX.listensForWSJTXUDP,
                logPath: path,
                summary: path.map { path in Result { () throws(MacLoggerDX.LogError) in try MacLoggerDX.readSummary(path: path) } }
            )
        }.value
    }

    private func chooseLogFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a MacLoggerDX log file (.sql)"
        if let current = LogbookSettings.macLoggerDXLogPath {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            logPathOverride = url.path
        }
    }
}

/// APRS decode (S.LIST/M.LIST) — see `APRSSettings`/`APRSDecoder`. Applies
/// instantly via `@AppStorage`, same reasoning as every other tab above
/// except rigctld: an out-of-range frequency/tolerance just means decoding
/// never activates, not a broken process launch worth a Cancel/Done escape
/// hatch.
private struct APRSSettingsTab: View {
    @EnvironmentObject private var hub: HubService
    @AppStorage(APRSSettings.enabledKey) private var enabled = false
    @AppStorage(APRSSettings.frequencyHzKey) private var frequencyHz = APRSSettings.defaultFrequencyHz
    @AppStorage(APRSSettings.toleranceHzKey) private var toleranceHz = APRSSettings.defaultToleranceHz
    @AppStorage(APRSSettings.maxStationsKey) private var maxStations = APRSSettings.defaultMaxStations
    @AppStorage(APRSSettings.maxMessagesKey) private var maxMessages = APRSSettings.defaultMaxMessages
    @State private var showingClearConfirmation = false

    private var megahertz: Binding<Double> {
        Binding(
            get: { Double(frequencyHz) / 1_000_000 },
            set: { frequencyHz = Int(($0 * 1_000_000).rounded()) }
        )
    }

    var body: some View {
        Form {
            Toggle("Decode APRS", isOn: $enabled)
            TextField("Frequency (MHz)", value: megahertz, format: .number.precision(.fractionLength(0...6)))
            TextField("Tolerance (Hz)", value: $toleranceHz, format: .number)
            TextField("Stations to retain", value: $maxStations, format: .number.grouping(.never))
            TextField("Messages to retain", value: $maxMessages, format: .number.grouping(.never))
            Button("Clear History…") { showingClearConfirmation = true }
        }
        .padding(.top, 8)
        .confirmationDialog("Clear all decoded APRS stations and messages?", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { hub.aprsStore.clearHistory() }
        }
    }
}

/// One band's HOME frequency field, shown/edited in MHz rather than raw Hz
/// for readability — `@AppStorage`'s key is per-instance (one per band), so
/// it's assigned in `init` via the underscore-prefixed backing-storage
/// pattern rather than a static key literal like every other `@AppStorage`
/// use in this file.
private struct HomeFrequencyField: View {
    let band: HomeBand
    @AppStorage private var frequencyHz: Int

    init(band: HomeBand) {
        self.band = band
        _frequencyHz = AppStorage(wrappedValue: band.defaultFrequencyHz, HomeFrequencySettings.key(for: band))
    }

    private var megahertz: Binding<Double> {
        Binding(
            get: { Double(frequencyHz) / 1_000_000 },
            set: { frequencyHz = Int(($0 * 1_000_000).rounded()) }
        )
    }

    var body: some View {
        TextField("\(band.displayName) (MHz)", value: megahertz, format: .number.precision(.fractionLength(0...6)))
    }
}

/// Polling rates — see `PollingSettings`. Applies instantly via
/// `@AppStorage` (each consumer re-reads its rate every loop iteration),
/// same reasoning as the other non-rigctld tabs: the steppers and
/// `PollingSettings`' own clamping keep every value in a safe range, so
/// there's no invalid input worth a Cancel/Done escape hatch. "Restore
/// Defaults" is the way back if a tuned value makes things worse.
private struct PollingSettingsTab: View {
    @AppStorage(PollingSettings.fastPollMilliseconds.key) private var fastPollMs = PollingSettings.fastPollMilliseconds.defaultValue
    @AppStorage(PollingSettings.slowReadsPerTick.key) private var slowReadsPerTick = PollingSettings.slowReadsPerTick.defaultValue
    @AppStorage(PollingSettings.reconnectDelaySeconds.key) private var reconnectSeconds = PollingSettings.reconnectDelaySeconds.defaultValue
    @AppStorage(PollingSettings.wpsdCallerSeconds.key) private var wpsdCallerSeconds = PollingSettings.wpsdCallerSeconds.defaultValue
    @AppStorage(PollingSettings.wpsdReflectorSeconds.key) private var wpsdReflectorSeconds = PollingSettings.wpsdReflectorSeconds.defaultValue
    @State private var showingRestoreConfirmation = false

    var body: some View {
        Form {
            Section("Radio (rigctld)") {
                Stepper(value: $fastPollMs, in: PollingSettings.fastPollMilliseconds.range, step: 50) {
                    Text("VFO / meters interval: \(fastPollMs) ms")
                }
                Stepper(value: $slowReadsPerTick, in: PollingSettings.slowReadsPerTick.range) {
                    Text("Menu settings: \(slowReadsPerTick) read\(slowReadsPerTick == 1 ? "" : "s") per VFO poll")
                }
                Stepper(value: $reconnectSeconds, in: PollingSettings.reconnectDelaySeconds.range) {
                    Text("Reconnect delay: \(reconnectSeconds) s")
                }
                Text("Lower interval / fewer menu reads update the VFO display faster; more menu reads pick up front-panel setting changes sooner. Over the Pi link a VFO poll plus its menu reads takes about a second, so an interval below that has no further effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("WPSD hotspot") {
                Stepper(value: $wpsdCallerSeconds, in: PollingSettings.wpsdCallerSeconds.range) {
                    Text("Caller lookup: every \(wpsdCallerSeconds) s")
                }
                Stepper(value: $wpsdReflectorSeconds, in: PollingSettings.wpsdReflectorSeconds.range, step: 5) {
                    Text("Reflector lookup: every \(wpsdReflectorSeconds) s")
                }
            }
            HStack {
                Text("Changes apply immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults…") { showingRestoreConfirmation = true }
                    .disabled(isAtDefaults)
            }
        }
        .padding(.top, 8)
        .confirmationDialog("Restore default polling rates?", isPresented: $showingRestoreConfirmation, titleVisibility: .visible) {
            Button("Restore Defaults") { restoreDefaults() }
        }
    }

    private var isAtDefaults: Bool {
        fastPollMs == PollingSettings.fastPollMilliseconds.defaultValue
            && slowReadsPerTick == PollingSettings.slowReadsPerTick.defaultValue
            && reconnectSeconds == PollingSettings.reconnectDelaySeconds.defaultValue
            && wpsdCallerSeconds == PollingSettings.wpsdCallerSeconds.defaultValue
            && wpsdReflectorSeconds == PollingSettings.wpsdReflectorSeconds.defaultValue
    }

    /// Assigns through the `@AppStorage` bindings rather than only calling
    /// `PollingSettings.restoreDefaults()`, so the steppers visibly snap
    /// back too.
    private func restoreDefaults() {
        PollingSettings.restoreDefaults()
        fastPollMs = PollingSettings.fastPollMilliseconds.defaultValue
        slowReadsPerTick = PollingSettings.slowReadsPerTick.defaultValue
        reconnectSeconds = PollingSettings.reconnectDelaySeconds.defaultValue
        wpsdCallerSeconds = PollingSettings.wpsdCallerSeconds.defaultValue
        wpsdReflectorSeconds = PollingSettings.wpsdReflectorSeconds.defaultValue
    }
}

/// App appearance controls. Theme plus the MENU grid's button value color —
/// future appearance settings (VFO display color, background color, per
/// repo CLAUDE.md) belong here too, following `AppTheme`/`ButtonValueColor`'s
/// `AppearanceSettings`-backed pattern.
private struct AppearanceSettingsTab: View {
    @AppStorage(AppearanceSettings.themeKey) private var themeRawValue = AppTheme.system.rawValue
    @AppStorage(AppearanceSettings.buttonValueColorKey) private var buttonValueColorRawValue = ButtonValueColor.orange.rawValue

    private var theme: Binding<AppTheme> {
        Binding(
            get: { AppTheme(rawValue: themeRawValue) ?? .system },
            set: { themeRawValue = $0.rawValue }
        )
    }

    private var buttonValueColor: Binding<ButtonValueColor> {
        Binding(
            get: { ButtonValueColor(rawValue: buttonValueColorRawValue) ?? .orange },
            set: { buttonValueColorRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Picker("Theme", selection: theme) {
                ForEach(AppTheme.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Picker("Button Value Color", selection: buttonValueColor) {
                ForEach(ButtonValueColor.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
        }
        .padding(.top, 8)
    }
}

/// Sparkle's automatic-update preferences — see `UpdaterSettingsViewModel`.
/// Applies instantly like the other non-rigctld tabs; Sparkle stores the
/// values itself.
private struct UpdatesSettingsTab: View {
    @StateObject private var viewModel: UpdaterSettingsViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: UpdaterSettingsViewModel(updater: updater))
    }

    var body: some View {
        Form {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { viewModel.automaticallyChecksForUpdates },
                set: { viewModel.setAutomaticallyChecksForUpdates($0) }
            ))
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { viewModel.automaticallyDownloadsUpdates },
                set: { viewModel.setAutomaticallyDownloadsUpdates($0) }
            ))
            .disabled(!viewModel.allowsAutomaticUpdates)

            CheckForUpdatesView(updater: updater)
        }
        .padding(.top, 8)
    }
}

#Preview {
    SettingsView(updater: SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    ).updater)
        .environmentObject(HubService())
}

/// Adds `.resizable` to the window hosting it. SwiftUI's `Settings` scene
/// creates its window without that style bit, and `windowResizability`
/// alone doesn't add it.
private struct ResizableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.styleMask.insert(.resizable)
        }
    }
}

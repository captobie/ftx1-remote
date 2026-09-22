import AppKit
import FTX1Core
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

    @State private var connectionMode = RigctldSettings.connectionMode
    @State private var remoteHost = RigctldSettings.remoteHost
    @State private var binaryPath = RigctldSettings.binaryPath
    @State private var modelNumber = RigctldSettings.modelNumber
    @State private var devicePath = RigctldSettings.devicePath
    @State private var baudRate = RigctldSettings.baudRate
    @State private var pttPort = RigctldSettings.pttPort

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
                HomeFrequencySettingsTab()
                    .tabItem { Text("Home Freq") }
                AppearanceSettingsTab()
                    .tabItem { Text("Appearance") }
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
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            refreshAvailableDevices()
            refreshAvailableBinaryPaths()
        }
    }

    private var rigctldTab: some View {
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
            Text("Changing this requires restarting FTX1Remote to take effect.")
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
        }
        .padding(.top, 8)
    }

    private func save() {
        RigctldSettings.connectionMode = connectionMode
        RigctldSettings.remoteHost = remoteHost
        RigctldSettings.binaryPath = binaryPath
        RigctldSettings.modelNumber = modelNumber
        RigctldSettings.devicePath = devicePath
        RigctldSettings.baudRate = baudRate
        RigctldSettings.pttPort = pttPort
        dismiss()
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

/// Sound card input selection, ahead of features that will need it (e.g. a
/// waterfall/spectrum display). Applies instantly via `@AppStorage`, same
/// as `AppearanceSettingsTab` below — picking from an enumerated device
/// list has no invalid-input failure mode, unlike the rigctld tab's free-
/// text fields.
private struct AudioSettingsTab: View {
    @AppStorage(AudioInputSettings.deviceUIDKey) private var inputDeviceUID = ""
    @AppStorage(AudioOutputSettings.deviceUIDKey) private var outputDeviceUID = ""
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
        if !outputDeviceUID.isEmpty, !devices.contains(where: { $0.uid == outputDeviceUID }) {
            devices.append(AudioOutputDevice(id: 0, uid: outputDeviceUID, name: "\(outputDeviceUID) (not connected)"))
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

#Preview {
    SettingsView()
        .environmentObject(HubService())
}

import AppKit
import SwiftUI

/// rigctld launch configuration, overriding the defaults in
/// `RigctldSettings`. Presented as a sheet from `ContentView`.
///
/// Edits are held in local `@State`, not written back to `RigctldSettings`
/// until "Done" — so "Cancel" can discard them (e.g. an accidental empty
/// binary path) rather than the old `@AppStorage` bindings, which wrote on
/// every keystroke with no way to back out.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var binaryPath = RigctldSettings.binaryPath
    @State private var modelNumber = RigctldSettings.modelNumber
    @State private var devicePath = RigctldSettings.devicePath
    @State private var baudRate = RigctldSettings.baudRate

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
            Text("rigctld Settings")
                .font(.title2)

            Form {
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
        .frame(minWidth: 380)
        .onAppear {
            refreshAvailableDevices()
            refreshAvailableBinaryPaths()
        }
    }

    private func save() {
        RigctldSettings.binaryPath = binaryPath
        RigctldSettings.modelNumber = modelNumber
        RigctldSettings.devicePath = devicePath
        RigctldSettings.baudRate = baudRate
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
    /// actually plugged in right now, rather than a hardcoded guess. Keeps
    /// the currently configured device in the list even if it isn't
    /// currently present, so an unplugged rig doesn't lose its setting.
    private func refreshAvailableDevices() {
        var devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
            .filter { $0.hasPrefix("tty.") || $0.hasPrefix("cu.") }
            .map { "/dev/" + $0 }
            .sorted() ?? []
        if !devices.contains(devicePath) {
            devices.append(devicePath)
            devices.sort()
        }
        availableDevices = devices
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

#Preview {
    SettingsView()
}

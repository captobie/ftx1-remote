import SwiftUI

/// rigctld launch configuration, overriding the defaults in
/// `RigctldSettings`. Presented as a sheet from `ContentView`.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(RigctldSettings.binaryPathKey) private var binaryPath = RigctldSettings.binaryPath
    @AppStorage(RigctldSettings.modelNumberKey) private var modelNumber = RigctldSettings.modelNumber
    @AppStorage(RigctldSettings.devicePathKey) private var devicePath = RigctldSettings.devicePath
    @AppStorage(RigctldSettings.baudRateKey) private var baudRate = RigctldSettings.baudRate

    @State private var availableDevices: [String] = []

    /// Common CAT baud rates for hamlib-controlled rigs.
    private static let baudRateOptions = [4800, 9600, 19200, 38400, 57600, 115200]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("rigctld Settings")
                .font(.title2)

            Form {
                TextField("Binary path", text: $binaryPath)
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
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .onAppear { refreshAvailableDevices() }
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
}

#Preview {
    SettingsView()
}

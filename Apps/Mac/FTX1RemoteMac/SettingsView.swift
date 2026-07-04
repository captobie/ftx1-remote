import SwiftUI

/// rigctld launch configuration, overriding the defaults in
/// `RigctldSettings`. Presented as a sheet from `ContentView`.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(RigctldSettings.binaryPathKey) private var binaryPath = RigctldSettings.binaryPath
    @AppStorage(RigctldSettings.modelNumberKey) private var modelNumber = RigctldSettings.modelNumber
    @AppStorage(RigctldSettings.devicePathKey) private var devicePath = RigctldSettings.devicePath
    @AppStorage(RigctldSettings.baudRateKey) private var baudRate = RigctldSettings.baudRate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("rigctld Settings")
                .font(.title2)

            Form {
                TextField("Binary path", text: $binaryPath)
                TextField("Model number", value: $modelNumber, format: .number)
                TextField("Serial device", text: $devicePath)
                TextField("Baud rate", value: $baudRate, format: .number)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
    }
}

#Preview {
    SettingsView()
}

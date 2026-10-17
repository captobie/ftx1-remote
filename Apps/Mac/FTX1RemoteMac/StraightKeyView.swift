import FTX1Core
import SwiftUI

/// Tools → Straight Key: the Arduino key interface's link, the Armed
/// toggle, key/line indicators, and the keying port settings. See
/// `StraightKeyController`.
struct StraightKeyView: View {
    @EnvironmentObject private var key: StraightKeyController
    @State private var ports: [String] = []

    var body: some View {
        Form {
            Section("Key interface") {
                portPicker("Port", selection: $key.interfacePort)
                LabeledContent("Link") {
                    Text(linkText).foregroundStyle(key.snapshot.link.isConnected ? Color.primary : Color.orange)
                }
                if let status = key.snapshot.deviceStatus {
                    LabeledContent("Device") {
                        Text("Sidetone \(status.sidetoneOn ? "on" : "off") · keyer \(status.wpm) WPM")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 24) {
                    indicator("Key", on: key.snapshot.operatorKeyDown, color: .green)
                    indicator("Line", on: key.snapshot.keyed, color: .red)
                    Spacer()
                }
            }

            Section("Keying") {
                Toggle("Armed", isOn: Binding(get: { key.snapshot.armed }, set: { key.setArmed($0) }))
                    .toggleStyle(.switch)
                    .font(.headline)
                if let refusal = key.armRefusal {
                    message(refusal, color: .orange)
                }
                if let error = key.snapshot.keyerError {
                    message(error, color: .red)
                }
                if let latch = key.snapshot.latch {
                    message("Holding the line up: \(latch.description)", color: .red)
                } else if key.snapshot.armed, let cutoff = key.snapshot.cutoff {
                    message("Won't key: \(cutoff.description)", color: .orange)
                } else if let reason = key.blockReason {
                    message("Won't key: \(reason)", color: .secondary)
                }
                if let warning = key.modeWarning {
                    message(warning, color: .orange)
                }
            }

            Section {
                if StraightKeyController.isRemote {
                    LabeledContent("Pi keyer", value: key.piKeyerAddress)
                } else {
                    portPicker("Rig keying port", selection: $key.keyingPort)
                }
                Picker("Line", selection: $key.keyingLine) {
                    ForEach(CWKeyingLine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Inverted polarity (line cleared = key down)", isOn: $key.invertedPolarity)
                if key.invertedPolarity {
                    message("Inverted: unplugging or the app quitting unexpectedly leaves the line cleared, which keys the rig.", color: .red)
                }
            } header: {
                Text("Keying port")
            } footer: {
                Text(StraightKeyController.isRemote
                     ? "Remote mode: the Pi's ftx1-cwkey service keys the rig's second USB port and plays your timing out there. On the rig set CW SETTING → MODE CW → PC KEYING to \(key.keyingLine.rawValue), and leave RPTT SELECT there OFF. Changing these disarms."
                     : "The rig's second USB port (\"Standard COM Port\"), not rigctld's. On the rig set CW SETTING → MODE CW → PC KEYING to \(key.keyingLine.rawValue), and leave RPTT SELECT there OFF. Changing these disarms.")
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                Stepper(value: $key.playoutDelayMs, in: StraightKeySettings.playoutDelayRange, step: 10) {
                    LabeledContent("Playout delay", value: "\(key.playoutDelayMs) ms")
                }
                Stepper(value: $key.maxKeyDownSeconds, in: StraightKeySettings.maxKeyDownRange) {
                    LabeledContent("Max key-down", value: "\(key.maxKeyDownSeconds) s")
                }
                if StraightKeyController.isRemote {
                    Stepper(value: $key.remoteHeartbeatTimeoutMs, in: StraightKeySettings.remoteHeartbeatRange, step: 100) {
                        LabeledContent("Pi keys up after silence of", value: "\(key.remoteHeartbeatTimeoutMs) ms")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 720)
        .onAppear { ports = key.availablePorts() }
    }

    private var linkText: String {
        switch key.snapshot.link {
        case .closed: key.interfacePort.isEmpty ? "No port selected" : "Closed"
        case .opening: "Waiting for the key interface…"
        case .connected(let id, let version): id == "?" ? "Connected" : "Connected (\(id) v\(version))"
        case .failed(let message): message
        }
    }

    private func portPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: selection) {
                Text("None").tag("")
                // Keep a saved port listed while it's unplugged.
                ForEach(ports.contains(selection.wrappedValue) || selection.wrappedValue.isEmpty
                        ? ports : ports + [selection.wrappedValue], id: \.self) { path in
                    Text(path.replacingOccurrences(of: "/dev/", with: "")).tag(path)
                }
            }
            Button {
                ports = key.availablePorts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh the port list")
        }
    }

    private func indicator(_ title: String, on: Bool, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? color : Color.secondary.opacity(0.25))
                .frame(width: 14, height: 14)
            Text(title)
        }
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

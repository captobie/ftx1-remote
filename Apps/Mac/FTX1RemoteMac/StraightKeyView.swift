import FTX1Core
import SwiftUI

/// Tools → CW Key: the Arduino key interface's link, its paddle keyer's
/// settings, the Armed toggle, key/line indicators, and the keying port
/// settings. See `StraightKeyController`.
struct StraightKeyView: View {
    @EnvironmentObject private var key: StraightKeyController
    @State private var ports: [String] = []

    /// The key interface's `S` line, one whole sentence per combination.
    private static func deviceStatusText(wpm: Int, modeB: Bool, reversed: Bool, sidetoneOn: Bool) -> String {
        let mode = modeB ? "B" : "A"
        return switch (reversed, sidetoneOn) {
        case (false, true): String(localized: "straightKey.deviceStatusSidetoneOn \(wpm) \(mode)")
        case (false, false): String(localized: "straightKey.deviceStatusSidetoneOff \(wpm) \(mode)")
        case (true, true): String(localized: "straightKey.deviceStatusReversedSidetoneOn \(wpm) \(mode)")
        case (true, false): String(localized: "straightKey.deviceStatusReversedSidetoneOff \(wpm) \(mode)")
        }
    }

    var body: some View {
        Form {
            Section("straightKey.keyInterface") {
                portPicker(String(localized: "common.port"), selection: $key.interfacePort)
                LabeledContent("straightKey.link") {
                    Text(linkText).foregroundStyle(key.snapshot.link.isConnected ? Color.primary : Color.orange)
                }
                if let status = key.snapshot.deviceStatus {
                    LabeledContent("straightKey.device") {
                        Text(Self.deviceStatusText(wpm: status.wpm, modeB: status.iambicModeB,
                                                   reversed: status.paddleReversed, sidetoneOn: status.sidetoneOn))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 24) {
                    indicator(String(localized: "straightKey.key"), on: key.snapshot.operatorKeyDown, color: .green)
                    indicator(String(localized: "straightKey.line"), on: key.snapshot.keyed, color: .red)
                    Spacer()
                }
            }

            Section {
                Toggle("straightKey.followTheRigsKeyer", isOn: $key.keyerFollowsRig)
                if key.keyerFollowsRig {
                    LabeledContent("straightKey.speed", value: key.rigKeyerWPM.map { String(localized: "straightKey.wpmRig \(key.effectiveKeyerWPM) \($0)") } ?? String(localized: "straightKey.waitingForTheRigs"))
                } else {
                    stepper(String(localized: "straightKey.speed"), "\(key.keyerWPM) WPM", value: $key.keyerWPM, in: StraightKeySettings.keyerWPMRange)
                }
                Picker("straightKey.iambicMode", selection: $key.iambicModeB) {
                    Text("A").tag(false)
                    Text("B").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("straightKey.reversePaddleDitDah", isOn: $key.paddleReversed)
                Toggle("straightKey.sidetoneOnTheInterface", isOn: $key.sidetoneOn)
            } header: {
                Text("straightKey.paddleKeyer")
            } footer: {
                Text("straightKey.theKeyerRunsIn")
                    .foregroundStyle(.secondary)
            }

            Section("straightKey.keying") {
                Toggle("straightKey.armed", isOn: Binding(get: { key.snapshot.armed }, set: { key.setArmed($0) }))
                    .toggleStyle(.switch)
                    .font(.headline)
                if let refusal = key.armRefusal {
                    message(refusal, color: .orange)
                }
                if let error = key.snapshot.keyerError {
                    message(error, color: .red)
                }
                if let latch = key.snapshot.latch {
                    message(String(localized: "straightKey.holdingTheLineUp \(latch.description)"), color: .red)
                } else if key.snapshot.armed, let cutoff = key.snapshot.cutoff {
                    message(String(localized: "straightKey.wontKey \(cutoff.description)"), color: .orange)
                } else if let reason = key.blockReason {
                    message(String(localized: "straightKey.wontKey \(reason)"), color: .secondary)
                }
                if let warning = key.modeWarning {
                    message(warning, color: .orange)
                }
            }

            Section {
                if StraightKeyController.isRemote {
                    LabeledContent("straightKey.piKeyer", value: key.piKeyerAddress)
                } else {
                    portPicker(String(localized: "straightKey.rigKeyingPort"), selection: $key.keyingPort)
                }
                Picker("straightKey.line", selection: $key.keyingLine) {
                    ForEach(CWKeyingLine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("straightKey.invertedPolarityLineCleared", isOn: $key.invertedPolarity)
                if key.invertedPolarity {
                    message(String(localized: "straightKey.invertedUnpluggingOrThe"), color: .red)
                }
            } header: {
                Text("straightKey.keyingPort")
            } footer: {
                Text(StraightKeyController.isRemote
                     ? "straightKey.remoteModeThePis \(key.keyingLine.rawValue)"
                     : "straightKey.theRigsSecondUsb \(key.keyingLine.rawValue)")
                    .foregroundStyle(.secondary)
            }

            Section("straightKey.timing") {
                stepper(String(localized: "straightKey.playoutDelay"), "\(key.playoutDelayMs) ms", value: $key.playoutDelayMs,
                        in: StraightKeySettings.playoutDelayRange, step: 10)
                stepper(String(localized: "straightKey.maxKeyDown"), "\(key.maxKeyDownSeconds) s", value: $key.maxKeyDownSeconds,
                        in: StraightKeySettings.maxKeyDownRange)
                if StraightKeyController.isRemote {
                    stepper(String(localized: "straightKey.piKeysUpAfter"), "\(key.remoteHeartbeatTimeoutMs) ms",
                            value: $key.remoteHeartbeatTimeoutMs, in: StraightKeySettings.remoteHeartbeatRange, step: 100)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 900)
        .onAppear { ports = key.availablePorts() }
    }

    private var linkText: String {
        switch key.snapshot.link {
        case .closed: key.interfacePort.isEmpty ? String(localized: "straightKey.noPortSelected") : String(localized: "straightKey.closed")
        case .opening: String(localized: "straightKey.waitingForTheKey")
        case .connected(let id, let version): id == "?" ? String(localized: "common.connected") : String(localized: "straightKey.connectedV \(id) \(version)")
        case .failed(let message): message
        }
    }

    private func portPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: selection) {
                Text("common.none").tag("")
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
            .help("straightKey.refreshThePortList")
        }
    }

    /// A labelled row with its value on the right, next to the stepper's
    /// arrows — a `Stepper` wrapping a `LabeledContent` puts the value right
    /// after the label instead, leaving the row's value column empty.
    private func stepper(_ title: String, _ value: String, value binding: Binding<Int>,
                         in range: ClosedRange<Int>, step: Int = 1) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value).monospacedDigit()
                Stepper(title, value: binding, in: range, step: step).labelsHidden()
            }
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

import FTX1CW
import FTX1Core
import SwiftUI

/// The CW pane's send section, on both routes: the Mac's
/// `CWSendPane` on the shared `CWSender` — the rig's keyer speed and
/// break-in, the keyer memory slot, macro buttons that fill the send line,
/// a log of queued/keying/sent lines and a line to type into (Return
/// queues it). Sending goes through the rig's own keyer memory, gated by
/// the route's `CWKeyerLink.cwSendBlock`; the decoder pauses while it runs.
///
/// Generic over `RigController` for the parts that read the rig (keyer
/// controls, status line): `PiDirectViewModel` on Pi direct (phase 2),
/// `RigClientViewModel` on the hub route (phase 3, the keyer memory
/// written on the Mac through `CWKeyerRequest`). Those parts are their own
/// small views so the rig's polling doesn't re-render the log.
struct CWSendSection<Controller: RigController>: View {
    @EnvironmentObject private var sender: CWSender
    @State private var line = ""
    @State private var note: String?
    @State private var isEditingMacros = false
    @FocusState private var isLineFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            macroRow
            CWSendLog(items: sender.items)
                .frame(minHeight: 70, maxHeight: 130)
            CWSendStatus<Controller>(note: note)
            inputRow
        }
        .sheet(isPresented: $isEditingMacros) {
            CWMacroEditor(macros: $sender.macros)
        }
    }

    private var header: some View {
        // No "Send" heading: the row is just wide enough in portrait
        // without one, and the line below says what it's for.
        HStack(spacing: 12) {
            CWKeyerControls<Controller>()
            Spacer()
            Button {
                isEditingMacros = true
            } label: {
                Label("Macros", systemImage: "square.grid.3x2")
            }
            Button {
                sender.clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(!sender.items.contains { !$0.isWaiting })
            Button(role: .destructive) {
                sender.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!sender.canStop)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Their call (for `{CALL}`) and the macro buttons, scrolling sideways
    /// if there are many.
    private var macroRow: some View {
        HStack(spacing: 8) {
            TextField("Their call", text: $sender.theirCall)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .frame(width: 130)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sender.macros) { macro in
                        Button(macro.label) { insert(macro) }
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Type a line and press Return to send", text: $line)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .focused($isLineFocused)
                .submitLabel(.send)
                .onSubmit(submit)
                .onChange(of: line) { _, new in
                    if !new.isEmpty { note = nil }
                }
            Button("Send", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(line.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    /// Adds a macro's text to the send line (after a space if there's
    /// already something there); macros don't send by themselves.
    private func insert(_ macro: CWMacro) {
        switch sender.text(for: macro, stationSettings: "CW pane → Macros") {
        case .failure(let problem):
            note = problem.message
        case .success(let text):
            let current = line.trimmingCharacters(in: .whitespaces)
            line = current.isEmpty ? text : current + " " + text
            note = nil
            isLineFocused = true
        }
    }

    private func submit() {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        note = sender.enqueue(line)
        if note == nil { line = "" }
        isLineFocused = true
    }
}

/// Keyer speed, break-in and the keyer memory slot. Reads the rig state.
private struct CWKeyerControls<Controller: RigController>: View {
    @EnvironmentObject private var rig: Controller
    @EnvironmentObject private var sender: CWSender

    var body: some View {
        HStack(spacing: 10) {
            let wpm = rig.rigState.cwSpeedWpm
            Text(wpm.map { "\($0) WPM" } ?? "– WPM")
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 64, alignment: .trailing)
            Stepper("Keyer speed", onIncrement: {
                rig.send(.setCWSpeed(wpm: min((wpm ?? 20) + 1, 60)))
            }, onDecrement: {
                rig.send(.setCWSpeed(wpm: max((wpm ?? 20) - 1, 4)))
            })
            .labelsHidden()
            .disabled(wpm == nil)

            // A button rather than a `.button`-style Toggle, which drew
            // no label here. Filled while break-in is on; the rig only keys
            // its memory then.
            let breakIn = rig.rigState.breakIn ?? false
            Button {
                rig.send(.setBreakIn(!breakIn))
            } label: {
                Text("BK-IN")
                    .fontWeight(breakIn ? .bold : .regular)
                    .foregroundStyle(breakIn ? Color.white : Color.primary)
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .tint(breakIn ? .accentColor : nil)
            .disabled(rig.rigState.breakIn == nil)
            .accessibilityLabel(breakIn ? "Break-in on; tap to turn off" : "Break-in off; tap to turn on")

            Picker("Memory", selection: $sender.slot) {
                ForEach(1...5, id: \.self) { Text("Memory \($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(sender.isSending)
        }
    }
}

/// One line under the log: the last problem queueing something, what the
/// rig is doing, what's blocking sending, or ready. Reads the rig state
/// (so the block re-checks on every poll).
private struct CWSendStatus<Controller: RigController>: View {
    @EnvironmentObject private var rig: Controller
    @EnvironmentObject private var sender: CWSender
    let note: String?

    var body: some View {
        HStack(spacing: 8) {
            if let note {
                Label(note, systemImage: "exclamationmark.triangle")
            } else if let activity = sender.activity {
                ProgressView().controlSize(.small)
                Text(activity)
            } else if let block = sender.block {
                Label("Can't send: \(block.message)", systemImage: "exclamationmark.triangle")
                if block == .breakInOff {
                    Button("Turn On BK-IN") { rig.send(.setBreakIn(true)) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                Text("Ready — \(rig.rigState.cwSpeedWpm.map { "\($0) WPM" } ?? "rig keyer"), memory \(sender.slot)")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// Queued, keying and sent lines, newest at the bottom.
private struct CWSendLog: View {
    let items: [CWSendItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if items.isEmpty {
                    Text("Lines you send appear here. Type below, or use a macro.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    CWSendRow(item: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .background(Color(.systemBackground))
    }
}

private struct CWSendRow: View {
    let item: CWSendItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(item.displayText)
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(item.state == .queued || item.state == .stopped ? .secondary : .primary)
                    .textSelection(.enabled)
                if item.state == .sending, item.chunks.count > 1 {
                    Text("\(item.sentChunks + 1)/\(item.chunks.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if case .failed(let reason) = item.state {
                Text(reason).font(.caption).foregroundStyle(.red).padding(.leading, 26)
            }
            if !item.dropped.isEmpty {
                Text("Left out (the keyer can't send them): \(item.dropped)")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
        }
    }

    private var symbol: String {
        switch item.state {
        case .queued: "clock"
        case .sending: "dot.radiowaves.right"
        case .sent: "checkmark"
        case .stopped: "stop.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch item.state {
        case .queued, .stopped: .secondary
        case .sending: .orange
        case .sent: .green
        case .failed: .red
        }
    }
}

/// Edits the macro buttons, plus the operator's own call and grid
/// (`StationSettings`, this iPad's copy) that `{MYCALL}`/`{MYGRID}` use —
/// the iPad has no Settings → Station of its own.
private struct CWMacroEditor: View {
    @Binding var macros: [CWMacro]
    @AppStorage(StationSettings.callsignKey) private var myCall = ""
    @AppStorage(StationSettings.gridSquareKey) private var myGrid = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("My callsign", text: $myCall)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("My grid square", text: $myGrid)
                        .autocorrectionDisabled()
                } header: {
                    Text("Station")
                } footer: {
                    Text("{MYCALL} and {MYGRID} in a macro. {CALL} is the Their call field. Prosigns: <BT>, <AR>, <KN>.")
                }
                Section("Macros") {
                    ForEach($macros) { $macro in
                        HStack {
                            TextField("Label", text: $macro.label)
                                .frame(width: 100)
                            TextField("Text", text: $macro.text)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        }
                    }
                    .onDelete { macros.remove(atOffsets: $0) }
                    .onMove { macros.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add Macro") {
                        macros.append(CWMacro(label: "New", text: ""))
                    }
                    Button("Restore Defaults") {
                        macros = CWMacro.defaults
                    }
                }
            }
            .navigationTitle("CW Macros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

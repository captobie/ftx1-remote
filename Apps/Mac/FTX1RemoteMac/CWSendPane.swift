import FTX1Core
import SwiftUI

/// The CW window's send pane (v2): macro buttons, a log of what's queued,
/// keying and sent, and a line to type into (Return queues it). A macro
/// fills the line rather than sending, so it can be edited first. Driven by
/// `CWSender`. Views that read `hub.rigState` are their own small structs
/// so the rig's polling doesn't re-render the log.
struct CWSendPane: View {
    @EnvironmentObject private var sender: CWSender
    @State private var line = ""
    /// Kept so a macro can leave the cursor at the end of the line: macOS
    /// otherwise selects the whole field on focus, and the next keystroke
    /// would replace the message.
    @State private var lineSelection: TextSelection?
    @State private var note: String?
    @State private var isEditingMacros = false
    @FocusState private var isLineFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            macroRow
            Divider()
            CWSendLog(items: sender.items)
            Divider()
            CWSendStatus(note: note)
            inputRow
        }
        .sheet(isPresented: $isEditingMacros) {
            CWMacroEditor(macros: $sender.macros)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Send").font(.headline)
            CWKeyerControls()
            Spacer()
            Button {
                isEditingMacros = true
            } label: {
                Label("Macros…", systemImage: "square.grid.3x2")
            }
            .help("Edit the macro buttons")
            Button {
                sender.clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear what's been sent from the log")
            .disabled(!sender.items.contains { !$0.isWaiting })
            Button(role: .destructive) {
                sender.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .keyboardShortcut(.cancelAction)
            .help("Stop keying now and drop everything queued (Esc)")
            .disabled(!sender.isSending && !sender.items.contains(where: \.isWaiting))
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var macroRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(sender.macros.enumerated()), id: \.element.id) { index, macro in
                Button(macro.label) {
                    insert(macro)
                }
                .modifier(MacroShortcut(index: index))
                .help("Put “\(macro.text)” in the send line" + (index < 9 ? "  (⌘\(index + 1))" : ""))
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Their call", text: $sender.theirCall)
                .frame(width: 110)
                .help("The station you're working, for {CALL} in macros. Click a callsign in the decoded text to fill it in.")
            TextField("Type a line and press Return to send", text: $line, selection: $lineSelection)
                .font(.system(.body, design: .monospaced))
                .focused($isLineFocused)
                .onSubmit(submit)
                .onChange(of: line) { if !line.isEmpty { note = nil } }
            Button("Send", action: submit)
                .disabled(line.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    /// Adds a macro's text to the send line (after a space if there's
    /// already something there) and puts the cursor at the end.
    private func insert(_ macro: CWMacro) {
        switch sender.text(for: macro) {
        case .failure(let problem):
            note = problem.message
        case .success(let text):
            let current = line.trimmingCharacters(in: .whitespaces)
            line = current.isEmpty ? text : current + " " + text
            note = nil
            isLineFocused = true
            // After focus lands, or its select-all would win.
            DispatchQueue.main.async {
                lineSelection = TextSelection(insertionPoint: line.endIndex)
            }
        }
    }

    private func submit() {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        note = sender.enqueue(line)
        if note == nil { line = "" }
        isLineFocused = true
    }
}

/// ⌘1…⌘9 for the first nine macros.
private struct MacroShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}

/// Keyer speed, break-in and the keyer memory slot. Reads `hub.rigState`.
private struct CWKeyerControls: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var sender: CWSender

    var body: some View {
        HStack(spacing: 10) {
            let wpm = hub.rigState.cwSpeedWpm
            HStack(spacing: 4) {
                Text(wpm.map { "\($0) WPM" } ?? "– WPM")
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .trailing)
                Stepper("Keyer speed", onIncrement: {
                    hub.send(.setCWSpeed(wpm: min((wpm ?? 20) + 1, 60)))
                }, onDecrement: {
                    hub.send(.setCWSpeed(wpm: max((wpm ?? 20) - 1, 4)))
                })
                .labelsHidden()
                .disabled(wpm == nil)
            }
            .help("The rig's keyer speed (KS), 4–60 WPM")

            Toggle("BK-IN", isOn: Binding(
                get: { hub.rigState.breakIn ?? false },
                set: { hub.send(.setBreakIn($0)) }
            ))
            .toggleStyle(.button)
            .disabled(hub.rigState.breakIn == nil)
            .help("Break-in. The rig only transmits its keyer memory with BK-IN on.")

            Picker("Memory", selection: $sender.slot) {
                ForEach(1...5, id: \.self) { Text("Memory \($0)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(sender.isSending)
            .help("The rig's CW TEXT keyer memory the send pane writes to. Whatever is stored there gets overwritten.")
        }
    }
}

/// One line under the log: what's blocking sending, what the rig is doing,
/// or the last problem queueing something. Reads `hub.rigState`.
private struct CWSendStatus: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var sender: CWSender
    let note: String?

    var body: some View {
        HStack(spacing: 8) {
            if let note {
                Label(note, systemImage: "exclamationmark.triangle")
            } else if let activity = sender.activity {
                ProgressView().controlSize(.small)
                Text(activity)
            } else if let block = CWSender.blockReason(hub: hub) {
                Label("Can't send: \(block.message)", systemImage: "exclamationmark.triangle")
                if block == .breakInOff {
                    Button("Turn On BK-IN") { hub.send(.setBreakIn(true)) }
                        .controlSize(.small)
                }
            } else {
                Text("Ready — \(hub.rigState.cwSpeedWpm.map { "\($0) WPM" } ?? "rig keyer"), memory \(sender.slot)")
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
            .padding()
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct CWSendRow: View {
    let item: CWSendItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(item.text)
                    .font(.system(size: 16, design: .monospaced))
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
                Text(reason).font(.caption).foregroundStyle(.red).padding(.leading, 24)
            }
            if !item.dropped.isEmpty {
                Text("Left out (the keyer can't send them): \(item.dropped)")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
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

/// Edits the macro buttons: label and text, add/remove, restore defaults.
private struct CWMacroEditor: View {
    @Binding var macros: [CWMacro]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CW Macros").font(.title3.bold())
            Text("Placeholders: {MYCALL} and {MYGRID} (Settings → Station), {CALL} (Their call — click a callsign in the decoded text to fill it in). Prosigns: <BT>, <AR>, <KN>.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                ForEach($macros) { $macro in
                    HStack {
                        TextField("Label", text: $macro.label)
                            .frame(width: 90)
                        TextField("Text", text: $macro.text)
                            .font(.system(.body, design: .monospaced))
                        Button {
                            macros.removeAll { $0.id == macro.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this macro")
                    }
                }
                .onMove { macros.move(fromOffsets: $0, toOffset: $1) }
            }
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 260)
            HStack {
                Button("Add") {
                    macros.append(CWMacro(label: "New", text: ""))
                }
                Button("Restore Defaults") {
                    macros = CWMacro.defaults
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 620)
    }
}

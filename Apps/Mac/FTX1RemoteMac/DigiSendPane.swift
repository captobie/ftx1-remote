import AppKit
import FTX1Core
import FTX1Digi
import SwiftUI

/// The RTTY/PSK window's send pane: live typeahead, as in fldigi. TX keys
/// the rig and sends what's typed in the box as it's typed (sent text
/// greys out and can't be changed); RX sends the rest and returns to
/// receive; Stop unkeys at once. Driven by `DigiSender`. Views that read
/// `hub.rigState` are their own small structs, so the rig's polling
/// doesn't re-render the box.
struct DigiSendPane: View {
    @EnvironmentObject private var sender: DigiSender
    @State private var isEditingMacros = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            macroRow
            Divider()
            DigiTypeaheadView(sender: sender)
            Divider()
            DigiSendStatus()
        }
        .sheet(isPresented: $isEditingMacros) {
            DigiMacroEditor(macros: $sender.macros)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            DigiTransmitStateLabel()
            Button {
                sender.transmit()
            } label: {
                Text(verbatim: "TX")
                    .frame(minWidth: 36)
            }
            .keyboardShortcut("t")
            .help("digiSendPane.txHelp")
            .disabled(sender.state == .transmitting)
            Button {
                sender.finish()
            } label: {
                Text(verbatim: "RX")
                    .frame(minWidth: 36)
            }
            .keyboardShortcut("r")
            .help("digiSendPane.rxHelp")
            .disabled(sender.state != .transmitting)
            Button(role: .destructive) {
                sender.stop()
            } label: {
                Label("common.stop", systemImage: "stop.fill")
            }
            .keyboardShortcut(.cancelAction)
            .help("digiSendPane.stopHelp")
            .disabled(!sender.isTransmitting)
            Spacer()
            HStack(spacing: 6) {
                Text("digiSendPane.level")
                Slider(value: $sender.levelDb, in: DigiSender.levelRange, step: 1)
                    .frame(width: 100)
                    .disabled(sender.isTransmitting)
                Text(verbatim: "\(Int(sender.levelDb)) dB")
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
            }
            .help("digiSendPane.levelHelp")
            Button {
                isEditingMacros = true
            } label: {
                Label("cwSendPane.macros", systemImage: "square.grid.3x2")
            }
            .help("cwSendPane.editTheMacroButtons")
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var macroRow: some View {
        HStack(spacing: 8) {
            TextField("common.theirCall", text: $sender.theirCall)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 120)
                .onChange(of: sender.theirCall) { _, new in
                    let uppercased = new.uppercased()
                    if uppercased != new { sender.theirCall = uppercased }
                }
            ForEach(Array(sender.macros.enumerated()), id: \.element.id) { index, macro in
                Button(macro.label) {
                    sender.run(macro)
                }
                .modifier(DigiMacroShortcut(index: index))
                .help(Text(verbatim: macro.text))
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// "TX 0:12 / 3:00" while sending, "RX" otherwise.
private struct DigiTransmitStateLabel: View {
    @EnvironmentObject private var sender: DigiSender

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Group {
                if let start = sender.transmitStartedAt {
                    let elapsed = Int(ProcessInfo.processInfo.systemUptime - start)
                    let limit = Int(DigiSender.transmitLimit)
                    Text(verbatim: String(format: "TX %d:%02d / %d:%02d", elapsed / 60, elapsed % 60, limit / 60, limit % 60))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(verbatim: "RX")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
            .font(.system(.callout, design: .monospaced).bold())
        }
    }
}

/// Why TX is refused, the last stop's reason, or the MOD SOURCE warning.
/// Its own view: it observes `hub` for the transmit gate.
private struct DigiSendStatus: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var sender: DigiSender
    @State private var modSourceWarning: String?

    var body: some View {
        HStack(spacing: 8) {
            if let line {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(line)
                    .lineLimit(2)
            } else if sender.isTransmitting {
                Text("digiSendPane.queued \(sender.unsentCount)")
            } else {
                Text("digiSendPane.ready")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .task(id: modSourceKey) {
            modSourceWarning = await hub.digiModSourceWarning()
        }
    }

    private var line: String? {
        sender.message ?? (sender.isTransmitting ? nil : sender.blockReason) ?? modSourceWarning
    }

    /// Re-read MOD SOURCE when the transmitting mode or the link changes.
    private var modSourceKey: String {
        "\(hub.rigState.transmitMode?.rawValue ?? "-")|\(hub.connectionState == .connected)"
    }
}

/// ⌘1…⌘9 for the first nine macros.
private struct DigiMacroShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}

/// The typeahead box: an `NSTextView`, since it has to grey out the sent
/// part and refuse edits to it, which `TextEditor` can't.
private struct DigiTypeaheadView: NSViewRepresentable {
    @ObservedObject var sender: DigiSender

    func makeCoordinator() -> Coordinator { Coordinator(sender: sender) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = Coordinator.font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel(String(localized: "digiSendPane.typeHere"))
        context.coordinator.textView = textView
        context.coordinator.apply(text: sender.text, sentCount: sender.sentCount)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(text: sender.text, sentCount: sender.sentCount)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let sender: DigiSender
        weak var textView: NSTextView?
        private var appliedSent = -1

        init(sender: DigiSender) { self.sender = sender }

        /// UTF-16 length of the sent part, for `NSRange`s.
        private var sentLength: Int {
            String(sender.text.prefix(sender.sentCount)).utf16.count
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            range.location >= sentLength
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let accepted = sender.edit(to: textView.string)
            if accepted != textView.string { apply(text: accepted, sentCount: sender.sentCount) }
        }

        func apply(text: String, sentCount: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            if textView.string != text {
                let selection = textView.selectedRange()
                textView.string = text
                let end = (text as NSString).length
                textView.setSelectedRange(NSRange(location: min(selection.location, end), length: 0))
                appliedSent = -1
            }
            guard sentCount != appliedSent else { return }
            appliedSent = sentCount
            let sent = (String(text.prefix(sentCount)) as NSString).length
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.font, value: Self.font, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
            if sent > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                     range: NSRange(location: 0, length: min(sent, storage.length)))
            }
            storage.endEditing()
            textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        }
    }
}

private struct DigiMacroEditor: View {
    @Binding var macros: [DigiMacro]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("digiSendPane.macrosTitle").font(.title3.bold())
            Text("digiSendPane.macrosHelp")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach($macros) { $macro in
                    HStack {
                        TextField("common.label", text: $macro.label)
                            .frame(width: 90)
                        // Several lines: macros start and end their text on
                        // a line of its own (⌥Return for a new line).
                        TextField("common.text", text: $macro.text, axis: .vertical)
                            .lineLimit(1...4)
                            .font(.system(.body, design: .monospaced))
                        Button {
                            macros.removeAll { $0.id == macro.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("cwSendPane.removeThisMacro")
                    }
                }
                .onMove { macros.move(fromOffsets: $0, toOffset: $1) }
            }
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 260)
            HStack {
                Button("cwSendPane.add") {
                    macros.append(DigiMacro(label: "New", text: "{TX}\n\n{RX}"))
                }
                Button("common.restoreDefaults") {
                    macros = DigiMacro.defaults
                }
                Spacer()
                Button("common.done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 680)
    }
}

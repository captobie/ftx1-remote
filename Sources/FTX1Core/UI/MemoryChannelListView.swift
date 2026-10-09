import SwiftUI

/// The programmed-channel list in `VFODisplayBox`'s memory popover (the
/// iPad's): channel, tag, frequency and mode from a `MemoryListSnapshot`,
/// filterable, the current channel highlighted and scrolled to. A tap
/// selects the channel and closes the popover. The list comes from the
/// Mac hub's `MemoryListStore` (pushed) or, on Pi direct, the iPad's own;
/// Refresh re-reads it from the rig, and it reads itself once when there's
/// no list yet — the same rule as the Mac's memory list window.
public struct MemoryChannelListView: View {
    let list: MemoryListSnapshot?
    let currentChannel: Int?
    let onSelect: (Int) -> Void
    let onRefresh: (() -> Void)?

    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    public init(list: MemoryListSnapshot?, currentChannel: Int?, onSelect: @escaping (Int) -> Void, onRefresh: (() -> Void)?) {
        self.list = list
        self.currentChannel = currentChannel
        self.onSelect = onSelect
        self.onRefresh = onRefresh
    }

    private var entries: [MemoryChannelEntry] { list?.entries ?? [] }
    private var isScanning: Bool { list?.scanningChannel != nil }

    private var filteredEntries: [MemoryChannelEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            String(entry.channel) == query
                || (entry.tag?.localizedCaseInsensitiveContains(query) ?? false)
                || Self.frequencyLabel(entry.frequencyHz).contains(query)
                || entry.modeName.localizedCaseInsensitiveContains(query)
        }
    }

    public var body: some View {
        VStack(spacing: 8) {
            TextField("Filter channels", text: $filter)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            ScrollViewReader { proxy in
                List(filteredEntries) { entry in
                    row(entry)
                        .id(entry.channel)
                }
                .listStyle(.plain)
                .overlay {
                    if entries.isEmpty {
                        Text(isScanning ? "Reading channels…" : "No channel list yet")
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    if let currentChannel {
                        proxy.scrollTo(currentChannel, anchor: .center)
                    }
                }
            }
            .frame(height: 320)

            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let onRefresh {
                    Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                        .labelStyle(.titleAndIcon)
                        .disabled(isScanning)
                }
            }
        }
        .onAppear {
            // No list has ever been read (as opposed to an empty one): read
            // it once now, like the Mac's window does.
            if let onRefresh, list?.scanned == nil, entries.isEmpty, !isScanning {
                onRefresh()
            }
        }
    }

    private func row(_ entry: MemoryChannelEntry) -> some View {
        let isCurrent = entry.channel == currentChannel
        return Button {
            onSelect(entry.channel)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text("\(entry.channel)")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                Text(entry.tag ?? "")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.frequencyLabel(entry.frequencyHz))
                    .monospacedDigit()
                Text(entry.modeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
            }
            .fontWeight(isCurrent ? .semibold : .regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.2) : nil)
    }

    private var status: String {
        if let channel = list?.scanningChannel { return "Reading channel \(channel)…" }
        if let scanned = list?.scanned {
            return "\(entries.count) channels · read \(scanned.formatted(date: .abbreviated, time: .shortened))"
        }
        return ""
    }

    /// Same grouping as the Mac's memory list window.
    static func frequencyLabel(_ hz: Int) -> String {
        String(format: "%d.%03d.%03d", hz / 1_000_000, (hz / 1_000) % 1_000, hz % 1_000)
    }
}

#Preview {
    MemoryChannelListView(
        list: MemoryListSnapshot(
            entries: [
                MemoryChannelEntry(channel: 1, frequencyHz: 431_075_000, modeCode: "H", toneMode: 0, shift: 0, tag: "Pi-STAR"),
                MemoryChannelEntry(channel: 2, frequencyHz: 147_380_000, modeCode: "4", toneMode: 1, shift: 1, tag: "K7RPT"),
            ],
            scanned: Date(),
            scanningChannel: nil
        ),
        currentChannel: 2,
        onSelect: { _ in },
        onRefresh: {}
    )
    .padding()
    .frame(width: 420)
}

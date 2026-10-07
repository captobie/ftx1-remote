import FTX1Core
import SwiftUI

/// The memory list window (Mem List button under Waterfall): the rig's
/// programmed channels from `MemoryListStore`, each with MAIN/SUB buttons
/// that recall it on that receiver (`RigCommand.recallMemoryChannel`). The
/// button of the channel a receiver is currently on is highlighted.
struct MemoryListView: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var store: MemoryListStore
    @State private var searchText = ""
    /// Which side Scan Down/Up start — see `memoryScanControls`.
    @State private var scanSide: FilterSide = .main

    private var isConnected: Bool { hub.connectionState == .connected }

    private var filteredEntries: [MemoryChannelEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            String(entry.channel) == query
                || (entry.tag?.localizedCaseInsensitiveContains(query) ?? false)
                || Self.frequencyLabel(entry.frequencyHz).contains(query)
                || entry.modeName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Table(filteredEntries) {
            TableColumn("Ch") { entry in
                Text("\(entry.channel)")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(36)
            TableColumn("Name") { entry in
                Text(entry.tag ?? "")
            }
            .width(min: 90, ideal: 110)
            TableColumn("") { entry in
                HStack(spacing: 4) {
                    recallButton("MAIN", entry: entry, sub: false)
                    recallButton("SUB", entry: entry, sub: true)
                }
            }
            .width(96)
            TableColumn("Frequency") { entry in
                Text(Self.frequencyLabel(entry.frequencyHz))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 100)
            TableColumn("Mode") { entry in
                Text(entry.modeName)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Shift") { entry in
                Text(entry.shiftName)
            }
            .width(36)
            TableColumn("Tone") { entry in
                Text(entry.toneName)
            }
            .width(min: 40, ideal: 60)
        }
        .searchable(text: $searchText, prompt: "Name, channel, frequency")
        .overlay {
            if store.entries.isEmpty && !store.isScanning {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "list.number")
                } description: {
                    Text(isConnected ? "Click Refresh to read the rig's memory channels." : "Connect to the rig, then click Refresh.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .toolbar {
            ToolbarItemGroup {
                memoryScanControls
            }
            ToolbarItem {
                if store.isScanning {
                    Button("Stop", systemImage: "stop.circle", action: store.cancel)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise", action: store.refresh)
                        .labelStyle(.titleAndIcon)
                        .disabled(!isConnected)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .onAppear(perform: refreshIfNeverRead)
        .onChange(of: isConnected) { refreshIfNeverRead() }
    }

    /// The cache is all the window needs once a list has been read; only a
    /// first-ever open reads the rig without being asked.
    private func refreshIfNeverRead() {
        if isConnected, store.lastScanned == nil, !store.isScanning {
            store.refresh()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let channel = store.scanningChannel {
                ProgressView().controlSize(.small)
                Text("Reading channel \(channel)…")
            } else if let error = store.scanError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error)
            } else if let scanText {
                Text(scanText)
            } else if let scanned = store.lastScanned {
                Text("\(store.entries.count) channels · read \(scanned.formatted(date: .abbreviated, time: .shortened))")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// The rig's memory scan (`RigCommand.setMemoryScan`) — not the
    /// Refresh read of the list, which this file otherwise calls a scan.
    /// Only the controls that apply right now are shown: a MAIN/SUB picker
    /// and Scan Down/Up while stopped, then Skip (paused only) and Stop
    /// Scan for the side that's scanning.
    @ViewBuilder
    private var memoryScanControls: some View {
        let state = hub.rigState.memoryScan
        if state == .scanning || state == .paused {
            if state == .paused {
                Button("Skip", systemImage: "forward.end", action: hub.skipMemoryScanChannel)
                    .labelStyle(.titleAndIcon)
                    .disabled(!isConnected)
                    .help("Resume the scan past this channel")
            }
            Button("Stop Scan", systemImage: "stop.circle") { hub.send(.setMemoryScan(.off, side: scanningSide)) }
                .labelStyle(.titleAndIcon)
                .disabled(!isConnected)
                .help("Stop the \(scanningSide.displayName) memory scan")
        } else {
            let canStart = isConnected && hub.rigState.canStartMemoryScan(on: scanSide)
            let hint = hub.rigState.canStartMemoryScan(on: scanSide) ? "" : " (put \(scanSide.displayName) in Memory mode first)"
            Picker("Scan Side", selection: $scanSide) {
                ForEach(FilterSide.allCases, id: \.self) { side in
                    Text(side.displayName).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .help("Which receiver to scan")
            Button("Scan Down", systemImage: "chevron.down.circle") { hub.send(.setMemoryScan(.down, side: scanSide)) }
                .labelStyle(.titleAndIcon)
                .disabled(!canStart)
                .help("Scan \(scanSide.displayName)'s memory channels downward" + hint)
            Button("Scan Up", systemImage: "chevron.up.circle") { hub.send(.setMemoryScan(.up, side: scanSide)) }
                .labelStyle(.titleAndIcon)
                .disabled(!canStart)
                .help("Scan \(scanSide.displayName)'s memory channels upward" + hint)
        }
    }

    private var scanningSide: FilterSide { hub.rigState.memoryScanSide ?? .main }

    /// Status-bar text for the rig's memory scan; nil when it isn't running.
    private var scanText: String? {
        let side = scanningSide
        let channel = side == .sub ? hub.rigState.subMemoryChannel : hub.rigState.memoryChannel
        switch hub.rigState.memoryScan {
        case .scanning:
            return "\(side.displayName) memory scan running…"
        case .paused:
            return "\(side.displayName) memory scan paused on " + (channel.map { "CH \($0)" } ?? "a busy channel")
        case .stopped, nil:
            return nil
        }
    }

    private func recallButton(_ title: String, entry: MemoryChannelEntry, sub: Bool) -> some View {
        let isCurrent = sub
            ? (hub.rigState.subVfoMemoryMode == .memory && hub.rigState.subMemoryChannel == entry.channel)
            : (hub.rigState.vfoMemoryMode == .memory && hub.rigState.memoryChannel == entry.channel)
        return Button {
            hub.send(.recallMemoryChannel(channel: entry.channel, sub: sub))
        } label: {
            Text(title)
                .font(.caption2)
                .frame(width: 38)
                .padding(.vertical, 2)
                .background(isCurrent ? Color.accentColor : Color.gray.opacity(0.2))
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
        .help("Recall channel \(entry.channel) on \(title)")
    }

    /// "431.075.000" — MHz.kHz.Hz, like the VFO boxes.
    static func frequencyLabel(_ hz: Int) -> String {
        String(format: "%d.%03d.%03d", hz / 1_000_000, (hz / 1_000) % 1_000, hz % 1_000)
    }
}

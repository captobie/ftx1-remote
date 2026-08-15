import FTX1Core
import SwiftUI

/// One of the FTX-1's deep SET-mode settings screens (Radio/CW/Operation/
/// Display/Extension/APRS Setting — see `DeepSettingsCatalog`), reached
/// from the numbered MENU grid's FM/C4FM page. Unlike that grid's one-
/// button-per-CAT-command buttons, this renders generically from
/// `DeepSettingsCatalog.items`: a vertical list of tabs (P2) down the
/// side, the selected tab's items (P3) as rows, each row's editor picked
/// from the item's `DeepSettingValueType`. `p1s` is normally one category,
/// except APRS Setting, whose physical button fans out to three Table 3
/// categories (`p1` 6-8) sharing one screen.
struct DeepSettingsView: View {
    let title: String
    let p1s: [Int]

    @EnvironmentObject private var hub: HubService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTabID: String?
    @State private var rawValues: [String: String] = [:]
    @State private var isLoading = false

    private struct Tab: Identifiable, Hashable {
        let p1: Int
        let p2: Int
        let name: String
        var id: String { "\(p1).\(p2)" }
    }

    private var tabs: [Tab] {
        DeepSettingsCatalog.tabs(forP1s: p1s).map { Tab(p1: $0.p1, p2: $0.p2, name: $0.name) }
    }

    private var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    private var itemsForSelectedTab: [DeepSettingItem] {
        guard let selectedTab else { return [] }
        return DeepSettingsCatalog.items(forP1: selectedTab.p1).filter { $0.p2 == selectedTab.p2 }
    }

    var body: some View {
        NavigationSplitView {
            List(tabs, selection: $selectedTabID) { tab in
                Text(tab.name).tag(tab.id)
            }
            .navigationTitle(title)
        } detail: {
            Group {
                if tabs.isEmpty {
                    ContentUnavailableView(
                        "Not catalogued yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("\(title) items haven't been added to the Deep Settings catalog.")
                    )
                } else if let selectedTab {
                    List(itemsForSelectedTab) { item in
                        DeepSettingRow(item: item, rawValue: rawValues[item.id]) { newRaw in
                            hub.send(.setMenuItem(p1: item.p1, p2: item.p2, p3: item.p3, rawValue: newRaw))
                            rawValues[item.id] = newRaw
                        }
                    }
                    .navigationTitle(selectedTab.name)
                    .task(id: selectedTab.id) { await loadValues(for: selectedTab) }
                    .overlay {
                        if isLoading { ProgressView() }
                    }
                } else {
                    ContentUnavailableView("Select a tab", systemImage: "sidebar.left")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            if selectedTabID == nil { selectedTabID = tabs.first?.id }
        }
    }

    /// Fetches only the visible tab's items, concurrently — `RigctldClient`'s
    /// round-trip lock already serializes these safely even issued at once,
    /// and a tab can hold 15-20 items at the project's confirmed ~1-2s
    /// per-round-trip latency, so sequential reads would be slow to feel
    /// responsive.
    private func loadValues(for tab: Tab) async {
        let items = DeepSettingsCatalog.items(forP1: tab.p1).filter { $0.p2 == tab.p2 }
        guard !items.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        await withTaskGroup(of: (String, String?).self) { group in
            for item in items {
                group.addTask {
                    (item.id, await hub.readMenuItem(p1: item.p1, p2: item.p2, p3: item.p3))
                }
            }
            for await (id, value) in group {
                if let value { rawValues[id] = value }
            }
        }
    }
}

/// Renders one Deep Settings item, picking the editor widget from its
/// `DeepSettingValueType`. `rawValue` is the raw P4 string already fetched
/// for this tab (nil until `DeepSettingsView.loadValues` completes); `onSet`
/// receives the newly-encoded raw P4 string to send and store optimistically,
/// same pattern as the numbered MENU grid's popover `Stepper`s.
private struct DeepSettingRow: View {
    let item: DeepSettingItem
    let rawValue: String?
    let onSet: (String) -> Void

    var body: some View {
        HStack {
            Text(item.label)
            Spacer()
            editor
        }
    }

    @ViewBuilder
    private var editor: some View {
        let decoded = rawValue.flatMap(item.decode)
        switch item.valueType {
        case .toggle(let offLabel, let onLabel):
            if case .bool(let on) = decoded {
                Toggle(on ? onLabel : offLabel, isOn: Binding(
                    get: { on },
                    set: { newValue in
                        if let encoded = item.encode(.bool(newValue)) { onSet(encoded) }
                    }
                ))
                .labelsHidden()
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        case .enumeration(let cases, _):
            if case .int(let index) = decoded {
                Picker("", selection: Binding(
                    get: { index },
                    set: { newValue in
                        if let encoded = item.encode(.int(newValue)) { onSet(encoded) }
                    }
                )) {
                    ForEach(cases) { option in
                        Text(option.label).tag(option.index)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        case .intRange(let range, _, let unit, let step):
            if case .int(let value) = decoded {
                Stepper(
                    unit.map { "\(value) \($0)" } ?? "\(value)",
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            if let encoded = item.encode(.int(newValue)) { onSet(encoded) }
                        }
                    ),
                    in: range,
                    step: step
                )
                .frame(maxWidth: 220)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        case .signedRange(let range, _, let unit, let step):
            if case .int(let value) = decoded {
                Stepper(
                    unit.map { "\(value) \($0)" } ?? "\(value)",
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            if let encoded = item.encode(.int(newValue)) { onSet(encoded) }
                        }
                    ),
                    in: range,
                    step: step
                )
                .frame(maxWidth: 220)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        case .text(let maxLength):
            if case .text(let value) = decoded {
                TextField("", text: Binding(
                    get: { value },
                    set: { newValue in
                        if let encoded = item.encode(.text(String(newValue.prefix(maxLength)))) { onSet(encoded) }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        case .readOnly, .action:
            Text(rawValue ?? "—")
                .foregroundStyle(.secondary)
                .disabled(true)
        }
    }
}

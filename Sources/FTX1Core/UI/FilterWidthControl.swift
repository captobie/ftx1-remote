import SwiftUI

/// IF WIDTH (the FTX-1's DSP passband bandwidth) picker plus narrower/wider
/// step buttons, meant to sit in the Filter row under the Band/Mode
/// pickers alongside `IFShiftControl`. Generic over
/// `RigController` like `MenuPageView`, so the same view drives the Mac
/// (`HubService`) today and can drop into the iPad's `ContentView`
/// (`RigClientViewModel`) later — the state field (`RigState.
/// filterWidthIndex`) and command (`RigCommand.setFilterWidth`) already
/// cross the WebSocket.
///
/// The rig keeps WIDTH on the MAIN knob's function menu rather than the
/// numbered MENU grid, which is why this isn't a `MenuPageView` button.
///
/// The choices offered are the current mode's column of the CAT manual's
/// Table 5 (`FilterWidthTable`): the raw "SH" index means a different Hz
/// per mode, so the list is rebuilt whenever `rigState.mode` changes. AM/FM
/// show their fixed width disabled — the NARROW function (`NarrowControl`
/// on the second Filter row) is what switches between the two fixed values
/// there; C4FM/unknown, which have no width at all, render nothing.
public struct FilterWidthControl<Controller: RigController>: View {
    @EnvironmentObject private var hub: Controller

    public init() {}

    public var body: some View {
        let mode = hub.rigState.filterMode
        let entries = FilterWidthTable.entries(for: mode)
        if !entries.isEmpty {
            HStack(spacing: 6) {
                Picker("Width", selection: selection(entries: entries)) {
                    // Right after a mode change `filterWidthIndex` still
                    // holds the previous mode's index until the next
                    // slow-tier poll re-reads it (and before any poll at
                    // all it's nil), so the current value may not be in
                    // this mode's column. A Picker whose selection matches
                    // no tag renders blank, so surface the stale/unknown
                    // value as its own entry instead — labeled "—" or
                    // "Default" by `FilterWidthTable.label`.
                    if !entries.contains(where: { $0.index == currentIndex }) {
                        Text(FilterWidthTable.label(forIndex: hub.rigState.filterWidthIndex, mode: mode))
                            .tag(currentIndex)
                    }
                    ForEach(entries) { entry in
                        Text("\(entry.hz) Hz").tag(entry.index)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)

                stepButton(systemImage: "minus", help: "Narrower", narrower: true, mode: mode)
                stepButton(systemImage: "plus", help: "Wider", narrower: false, mode: mode)
            }
            .disabled(!FilterWidthTable.isAdjustable(mode: mode))
        }
    }

    /// nil (no poll yet) is tagged as 0 so it shares the "Default" slot —
    /// neither is a real column index, and both get the fallback entry.
    private var currentIndex: Int {
        hub.rigState.filterWidthIndex ?? 0
    }

    private func selection(entries: [FilterWidthTable.Entry]) -> Binding<Int> {
        Binding(
            get: { currentIndex },
            set: { index in
                // Only real column rows are sendable — re-selecting the
                // fallback entry (or the already-current value) is a no-op
                // rather than a stray "SH0" write.
                guard index != currentIndex, entries.contains(where: { $0.index == index }) else { return }
                hub.send(.setFilterWidth(index))
            }
        )
    }

    private func stepButton(systemImage: String, help: String, narrower: Bool, mode: RigMode) -> some View {
        let target = FilterWidthTable.neighborIndex(of: currentIndex, mode: mode, narrower: narrower)
        return Button {
            if let target { hub.send(.setFilterWidth(target)) }
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.bordered)
        .disabled(target == nil)
        .help(help)
    }
}

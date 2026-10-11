import SwiftUI

/// Band/segment menu for the VFO frequency popover (iPad): amateur bands,
/// then the general-coverage broadcast and utility segments, the same list
/// the Mac's band picker offers. Picking one calls `onSetBand` with its
/// name (`RigCommand.setBand`), which the hub resolves to that band's last
/// frequency/mode.
public struct BandPicker: View {
    let currentBand: String?
    let onSetBand: (String) -> Void

    public init(currentBand: String?, onSetBand: @escaping (String) -> Void) {
        self.currentBand = currentBand
        self.onSetBand = onSetBand
    }

    public var body: some View {
        Picker("Band", selection: binding) {
            // Outside every band and segment (e.g. not read yet): a blank
            // row to show instead of a wrong band.
            if currentBand == nil {
                Text("—").tag("")
            }
            Section("Amateur") {
                ForEach(BandPlan.all, id: \.name) { band in
                    Text(band.name).tag(band.name)
                }
            }
            Section("Broadcast") {
                ForEach(GeneralCoverageSegments.all.filter { $0.category == .broadcast }, id: \.name) { segment in
                    Text(segment.name).tag(segment.name)
                }
            }
            Section("Utility") {
                ForEach(GeneralCoverageSegments.all.filter { $0.category == .utility }, id: \.name) { segment in
                    Text(segment.name).tag(segment.name)
                }
            }
        }
        .pickerStyle(.menu)
    }

    private var binding: Binding<String> {
        Binding(
            get: { currentBand ?? "" },
            set: { if !$0.isEmpty { onSetBand($0) } }
        )
    }
}

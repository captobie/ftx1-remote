import SwiftUI

/// Band/segment menu for the VFO frequency popover (iPad): amateur bands,
/// then the general-coverage broadcast and utility segments, the same list
/// the Mac's band picker offers. Picking one calls `onSetBand` with its
/// name (`RigCommand.setBand`), which the hub resolves to that band's last
/// frequency/mode. The caller picks the picker style: `.menu` on the iPad,
/// `.inline` inside the iPhone's own `Menu` tile.
public struct BandPicker: View {
    let currentBand: String?
    let onSetBand: (String) -> Void

    public init(currentBand: String?, onSetBand: @escaping (String) -> Void) {
        self.currentBand = currentBand
        self.onSetBand = onSetBand
    }

    public var body: some View {
        Picker(String(localized: "common.band", bundle: .module), selection: binding) {
            // Outside every band and segment (e.g. not read yet): a blank
            // row to show instead of a wrong band.
            if currentBand == nil {
                Text("—").tag("")
            }
            Section(String(localized: "common.amateur", bundle: .module)) {
                ForEach(BandPlan.all, id: \.name) { band in
                    Text(band.name).tag(band.name)
                }
            }
            Section(String(localized: "common.broadcast", bundle: .module)) {
                ForEach(GeneralCoverageSegments.all.filter { $0.category == .broadcast }, id: \.name) { segment in
                    Text(segment.name).tag(segment.name)
                }
            }
            Section(String(localized: "common.utility", bundle: .module)) {
                ForEach(GeneralCoverageSegments.all.filter { $0.category == .utility }, id: \.name) { segment in
                    Text(segment.name).tag(segment.name)
                }
            }
        }
    }

    /// The picker entry a frequency falls in: the amateur band, else the
    /// general-coverage segment — the hub's `RigState.band` rule, for a
    /// route that doesn't fill `band` (Pi direct).
    public static func name(containing hz: Int) -> String? {
        BandPlan.band(containing: hz)?.name ?? GeneralCoverageSegments.segment(containing: hz)?.name
    }

    private var binding: Binding<String> {
        Binding(
            get: { currentBand ?? "" },
            set: { if !$0.isEmpty { onSetBand($0) } }
        )
    }
}

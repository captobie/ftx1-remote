import SwiftUI

/// The MAIN / SUB buttons that pick which receiver the Filter-row controls
/// and the Filter Function Display address, sitting just left of the display.
/// Generic over `RigController` like the other Filter-row views. The
/// selected side is `RigState.filterSide` (nil = MAIN), changed with
/// `RigCommand.setFilterSide`; the filter fields then hold that side's
/// values (the hub clears and re-reads them on a switch).
///
/// Same fill-as-state style as the N/W, Notch and Contour buttons. SUB is
/// disabled while the rig is in single-receive display (`RigState.
/// singleReceive`): the Sub receiver isn't shown then, so a filter change
/// there would be invisible. (Hardware-probed 2026-09-19: the rig still
/// *answers* Sub filter reads in single-receive — the disable is a UX
/// choice, not a CAT limitation. The hub also falls back to MAIN if the rig
/// goes single-receive while SUB is selected.)
public struct FilterSideSelector<Controller: RigController>: View {
    @EnvironmentObject private var hub: Controller

    public init() {}

    public var body: some View {
        let selected = hub.rigState.activeFilterSide
        VStack(spacing: 4) {
            sideButton(.main, selected: selected)
            sideButton(.sub, selected: selected)
        }
        .frame(width: 58)
    }

    @ViewBuilder
    private func sideButton(_ side: FilterSide, selected: FilterSide) -> some View {
        let unavailable = side == .sub && hub.rigState.singleReceive == true
        let button = Button {
            hub.send(.setFilterSide(side))
        } label: {
            Text(side.displayName)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .disabled(unavailable)
        .help(unavailable
              ? "SUB receiver isn't shown in single-receive display"
              : "Apply the filter controls to the \(side.displayName) receiver")
        if side == selected {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

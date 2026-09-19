import Foundation

/// Which of the FTX-1's two receivers the filter controls (WIDTH, SHIFT,
/// NOTCH, CONTOUR/APF, N/W) and the Filter Function Display address. Every
/// one of those raw CAT commands documents P1 = 0 for MAIN and 1 for SUB
/// (hardware-probed 2026-09-19: the Sub replies mirror the Main shapes,
/// e.g. "SH1003;", "IS10-0001;", "BP10001;", "CO111520;", "NA10;").
///
/// See `RigState.filterSide` (the selected side; the filter fields hold
/// *that side's* values), `RigCommand.setFilterSide`, and `CommandQueue`,
/// which holds the side so a `.setFilterSide` followed immediately by a
/// control change is applied in order.
public enum FilterSide: Int, Codable, Sendable, CaseIterable, Hashable {
    case main = 0
    case sub = 1

    /// The CAT P1 digit: "0" MAIN-side, "1" SUB-side.
    public var p1: String { String(rawValue) }

    /// "MAIN" / "SUB", for buttons and the display caption.
    public var displayName: String {
        switch self {
        case .main: "MAIN"
        case .sub: "SUB"
        }
    }
}

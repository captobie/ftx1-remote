import SwiftUI

/// User-selectable color for the "value" line of a MENU grid button (see
/// `MenuPageView.twoLineLabel`) — the current setting, e.g. "ON"/"20 WPM"/
/// "50%". Matches the FTX-1's own MENU display, which shows the function
/// name in white and the current setting in orange; `.orange` is the
/// default here for the same reason, with a few additional options for
/// preference/visibility. Per-device, not synced (see `AppTheme`).
public enum ButtonValueColor: String, CaseIterable, Codable, Sendable, Hashable {
    case orange
    case red
    case yellow
    case green
    case cyan
    case blue
    case pink
    case white

    public var displayName: String {
        switch self {
        case .orange: String(localized: "buttonValueColor.orange", bundle: .module)
        case .red: String(localized: "buttonValueColor.red", bundle: .module)
        case .yellow: String(localized: "buttonValueColor.yellow", bundle: .module)
        case .green: String(localized: "buttonValueColor.green", bundle: .module)
        case .cyan: String(localized: "buttonValueColor.cyan", bundle: .module)
        case .blue: String(localized: "buttonValueColor.blue", bundle: .module)
        case .pink: String(localized: "buttonValueColor.pink", bundle: .module)
        case .white: String(localized: "buttonValueColor.white", bundle: .module)
        }
    }

    public var color: Color {
        switch self {
        case .orange: .orange
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .pink: .pink
        case .white: .white
        }
    }
}

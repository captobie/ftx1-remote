import SwiftUI

/// User-selectable app appearance. A per-device UI preference — unlike
/// `RigState`, it's never pushed over the wire (see repo CLAUDE.md: the
/// WireMessage protocol carries radio state, not client display prefs), so
/// each Mac/iOS/iPadOS instance keeps its own choice.
///
/// Starts with just light/dark/system; more display-appearance settings
/// (VFO display color, background color, ...) are expected to join this
/// file later, following the same `AppearanceSettings`-backed pattern.
public enum AppTheme: String, CaseIterable, Codable, Sendable, Hashable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` tells SwiftUI to follow the system appearance
    /// (`.preferredColorScheme(nil)`).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

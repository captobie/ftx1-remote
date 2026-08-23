import Foundation

/// Per-device display appearance, backed by `UserDefaults` directly rather
/// than `@AppStorage` — same pattern as `RigctldSettings` in the Mac app
/// target, so non-View code can read/write it too. Lives in `FTX1Core`
/// rather than a single app target since both Mac and iOS/iPadOS apps each
/// keep their own local copy of this (it's never synced between them —
/// see `AppTheme`).
public enum AppearanceSettings {
    public static let themeKey = "appearance.theme"

    public static var theme: AppTheme {
        get {
            UserDefaults.standard.string(forKey: themeKey).flatMap(AppTheme.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
        }
    }
}

import Foundation

/// Per-device display appearance, backed by `UserDefaults` directly rather
/// than `@AppStorage` — same pattern as `RigctldSettings` in the Mac app
/// target, so non-View code can read/write it too. Lives in `FTX1Core`
/// rather than a single app target since both Mac and iOS/iPadOS apps each
/// keep their own local copy of this (it's never synced between them —
/// see `AppTheme`).
public enum AppearanceSettings {
    public static let themeKey = "appearance.theme"
    public static let buttonValueColorKey = "appearance.buttonValueColor"
    /// Settings → Appearance → Theme, by name (`ThemePresets`); unset until
    /// first chosen, when `themeKey`'s old Light/Dark/Auto applies.
    public static let themeNameKey = "appearance.themeName"
    /// A `VFODigitFont` raw value; empty or unset = the theme's font.
    public static let vfoDigitFontKey = "appearance.vfoDigitFont"
    /// A `ButtonValueColor` raw value; empty or unset = the theme's colour.
    public static let vfoDigitColorKey = "appearance.vfoDigitColor"

    public static var theme: AppTheme {
        get {
            UserDefaults.standard.string(forKey: themeKey).flatMap(AppTheme.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
        }
    }

    /// The chosen theme's name, or `ThemePresets.auto`.
    public static var themeName: String {
        get {
            UserDefaults.standard.string(forKey: themeNameKey) ?? ThemePresets.fromLegacy(theme)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: themeNameKey)
        }
    }

    /// See `ButtonValueColor` — the MENU grid's per-button setting-value
    /// color, defaulting to orange like the rig's own display.
    public static var buttonValueColor: ButtonValueColor {
        get {
            UserDefaults.standard.string(forKey: buttonValueColorKey).flatMap(ButtonValueColor.init(rawValue:)) ?? .orange
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: buttonValueColorKey)
        }
    }
}

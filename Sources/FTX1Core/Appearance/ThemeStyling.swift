import CoreText
import SwiftUI

// SwiftUI side of `ThemeDefinition`: the environment value views read, the
// `.appTheme()` modifier each window's root applies, and the button styles
// that draw a theme's buttons. A view outside `.appTheme()` (the iPad, the
// iPhone) sees no theme and draws exactly as before.

/// What `.appTheme()` puts in the environment: the chosen theme plus
/// Settings → Appearance's VFO digit overrides.
public struct AppThemeContext: Equatable, Sendable {
    public var theme: ThemeDefinition
    /// nil = the theme's font.
    public var vfoDigitFont: VFODigitFont?
    /// nil = the theme's colour.
    public var vfoDigitColor: ButtonValueColor?

    public init(theme: ThemeDefinition, vfoDigitFont: VFODigitFont? = nil, vfoDigitColor: ButtonValueColor? = nil) {
        self.theme = theme
        self.vfoDigitFont = vfoDigitFont
        self.vfoDigitColor = vfoDigitColor
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppThemeContext? = nil
}

public extension EnvironmentValues {
    /// nil outside `.appTheme()`.
    var appTheme: AppThemeContext? {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

public extension ThemeColor {
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

public extension ThemeFill {
    /// A colour, or a top-to-bottom `LinearGradient`. A broken fill (caught
    /// by `validate()` for presets) draws clear rather than crashing.
    var style: AnyShapeStyle {
        guard let stops = try? stops() else { return AnyShapeStyle(Color.clear) }
        if stops.count == 1 { return AnyShapeStyle(stops[0].color.color) }
        return AnyShapeStyle(LinearGradient(
            stops: stops.map { Gradient.Stop(color: $0.color.color, location: $0.offset) },
            startPoint: .top,
            endPoint: .bottom
        ))
    }
}

public extension ThemeBase {
    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

public extension Color {
    /// A theme colour from its hex string, nil if unset (or broken).
    init?(themeHex hex: String?) {
        guard let color = ThemeColor(hex: hex) else { return nil }
        self = color.color
    }
}

func themeColor(_ hex: String?) -> Color? {
    Color(themeHex: hex)
}

/// Applies Settings → Appearance to one window: its light/dark side, the
/// accent, the window background, buttons, and the theme in the
/// environment for the views that draw their own colours (VFO boxes,
/// MENU grid values, captions). Every branch is a value, not an `if`, so
/// switching themes never resets a window's state.
public struct AppThemeModifier: ViewModifier {
    @AppStorage(AppearanceSettings.themeNameKey) private var themeName: String?
    @AppStorage(AppearanceSettings.themeKey) private var legacyTheme = AppTheme.system.rawValue
    @AppStorage(AppearanceSettings.vfoDigitFontKey) private var vfoDigitFont = ""
    @AppStorage(AppearanceSettings.vfoDigitColorKey) private var vfoDigitColor = ""

    public init() {}

    public func body(content: Content) -> some View {
        let name = themeName ?? ThemePresets.fromLegacy(AppTheme(rawValue: legacyTheme) ?? .system)
        let chosen = ThemePresets.named(name)
        // Auto has no overrides; its light/dark side is the system's.
        let theme = chosen ?? ThemePresets.defaultLight
        let context = AppThemeContext(
            theme: theme,
            vfoDigitFont: VFODigitFont(rawValue: vfoDigitFont),
            vfoDigitColor: ButtonValueColor(rawValue: vfoDigitColor)
        )
        content
            .environment(\.appTheme, context)
            .preferredColorScheme(chosen?.base.colorScheme)
            .tint(themeColor(theme.accent))
            .buttonStyle(ThemedButtonStyle(fallback: .automatic))
            .scrollContentBackground(theme.windowBackground == nil ? .automatic : .hidden)
            .modifier(WindowBackground(fill: theme.windowBackground))
    }
}

/// The window's own background (behind the titlebar too); macOS only —
/// iOS has no window container background.
private struct WindowBackground: ViewModifier {
    let fill: ThemeFill?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.containerBackground(fill?.style ?? AnyShapeStyle(.windowBackground), for: .window)
        #else
        content
        #endif
    }
}

public extension View {
    /// See `AppThemeModifier`. Applied to every window's root.
    func appTheme() -> some View {
        modifier(AppThemeModifier())
    }

    /// A caption's secondary colour: the theme's `secondaryText`, else the
    /// system's `.secondary`.
    func themedSecondaryForeground() -> some View {
        modifier(ThemedSecondaryForeground())
    }
}

private struct ThemedSecondaryForeground: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    func body(content: Content) -> some View {
        content.foregroundStyle(themeColor(appTheme?.theme.secondaryText).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
    }
}

/// A push button. Without a theme that styles buttons it's the system's
/// (`.bordered`, or `.borderedProminent` while `isOn`; `.automatic` for
/// the window-wide default); with one, the theme's fills, border and text,
/// incl. hover, pressed and disabled.
public struct ThemedButtonStyle: PrimitiveButtonStyle {
    public enum Fallback: Sendable {
        case automatic
        case bordered
    }

    let isOn: Bool
    let fallback: Fallback
    let prominentWhenOn: Bool

    /// `prominentWhenOn: false` keeps a button that shows "on" its own way
    /// without a theme (V/M's bold label, the audio swap's tint) plain
    /// bordered then; a theme still draws its on fill.
    public init(isOn: Bool = false, fallback: Fallback = .bordered, prominentWhenOn: Bool = true) {
        self.isOn = isOn
        self.fallback = fallback
        self.prominentWhenOn = prominentWhenOn
    }

    public func makeBody(configuration: Configuration) -> some View {
        ThemedButtonBody(configuration: configuration, isOn: isOn, fallback: fallback, prominentWhenOn: prominentWhenOn)
    }
}

private struct ThemedButtonBody: View {
    @Environment(\.appTheme) private var appTheme
    let configuration: PrimitiveButtonStyleConfiguration
    let isOn: Bool
    let fallback: ThemedButtonStyle.Fallback
    let prominentWhenOn: Bool

    var body: some View {
        // Every branch sets a style on the inner Button: one left to the
        // environment would be this style again, recursing.
        if let theme = appTheme?.theme, theme.stylesButtons {
            Button(configuration).buttonStyle(ThemedFaceButtonStyle(theme: theme, isOn: isOn, padded: true))
        } else if isOn && prominentWhenOn {
            Button(configuration).buttonStyle(.borderedProminent)
        } else if fallback == .bordered {
            Button(configuration).buttonStyle(.bordered)
        } else {
            Button(configuration).buttonStyle(.automatic)
        }
    }
}

private struct ThemedFaceButtonStyle: ButtonStyle {
    let theme: ThemeDefinition
    let isOn: Bool
    let padded: Bool

    func makeBody(configuration: Configuration) -> some View {
        ThemedButtonFace(theme: theme, isOn: isOn, isPressed: configuration.isPressed, padded: padded, cornerRadius: 5) {
            configuration.label
        }
    }
}

/// The ContentView-style "tile" buttons (Waterfall/Oscilloscope/Off, Mute,
/// Mem List, zoom): labels that size and pad themselves. Without a theme,
/// the grey tile they always were, `onColor` while on; with one, the
/// theme's button face (its checked fill while on).
public struct ThemedTileButtonStyle: ButtonStyle {
    let isOn: Bool
    let onColor: Color
    let cornerRadius: CGFloat

    public init(isOn: Bool = false, onColor: Color = .accentColor, cornerRadius: CGFloat = 4) {
        self.isOn = isOn
        self.onColor = onColor
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        ThemedTile(isOn: isOn, onColor: onColor, cornerRadius: cornerRadius, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// `ThemedTileButtonStyle`'s face on its own, for a label that isn't a
/// Button's (a `Menu`'s).
public struct ThemedTile<Label: View>: View {
    @Environment(\.appTheme) private var appTheme
    let isOn: Bool
    let onColor: Color
    let cornerRadius: CGFloat
    let isPressed: Bool
    let label: Label

    public init(isOn: Bool = false, onColor: Color = .accentColor, cornerRadius: CGFloat = 4, isPressed: Bool = false,
                @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.onColor = onColor
        self.cornerRadius = cornerRadius
        self.isPressed = isPressed
        self.label = label()
    }

    public var body: some View {
        if let theme = appTheme?.theme, theme.stylesButtons {
            ThemedButtonFace(theme: theme, isOn: isOn, isPressed: isPressed, padded: false, cornerRadius: cornerRadius) {
                label
            }
        } else {
            label
                .background(isOn ? onColor : Color.gray.opacity(0.2))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// A theme's button: fill by state (disabled, pressed, hover, on), the
/// border fill, and the text colour.
struct ThemedButtonFace<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovering = false
    let theme: ThemeDefinition
    let isOn: Bool
    let isPressed: Bool
    /// Push-button padding; the tiles bring their own.
    let padded: Bool
    let cornerRadius: CGFloat
    @ViewBuilder let label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        label()
            .padding(.horizontal, padded ? horizontalPadding : 0)
            .padding(.vertical, padded ? verticalPadding : 0)
            .foregroundStyle(foreground)
            .background(shape.fill(fill.style))
            .overlay(shape.strokeBorder(theme.buttonBorder?.style ?? AnyShapeStyle(Color.clear), lineWidth: 1))
            .contentShape(shape)
            .onHover { isHovering = $0 }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini: 4
        case .small: 6
        default: 8
        }
    }

    private var verticalPadding: CGFloat {
        switch controlSize {
        case .mini, .small: 1
        default: 3
        }
    }

    private var fill: ThemeFill {
        let resting = theme.buttonBackground ?? .solid("#00000000")
        if !isEnabled {
            return theme.buttonBackgroundDisabled ?? resting
        }
        if isOn {
            let checked = theme.buttonCheckedBackground ?? resting
            if isPressed { return theme.buttonCheckedBackgroundPressed ?? checked }
            if isHovering { return theme.buttonCheckedBackgroundHover ?? checked }
            return checked
        }
        if isPressed { return theme.buttonBackgroundPressed ?? resting }
        if isHovering { return theme.buttonBackgroundHover ?? resting }
        return resting
    }

    private var foreground: Color {
        let normal = themeColor(theme.buttonForeground) ?? .primary
        if !isEnabled { return themeColor(theme.buttonForegroundDisabled) ?? normal.opacity(0.5) }
        if isOn { return themeColor(theme.buttonCheckedForeground) ?? normal }
        return normal
    }
}

/// The VFO digits' fonts. DSEG7 Classic ships in this package's resources
/// and is registered for the process on first use.
public enum VFODigitFonts {
    /// PostScript names of the bundled Regular and Bold, nil if a file is
    /// missing or didn't register.
    private static let sevenSegmentNames: (regular: String?, bold: String?) = (
        register("DSEG7Classic-Regular"), register("DSEG7Classic-Bold")
    )

    private static func register(_ file: String) -> String? {
        guard let url = Bundle.module.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts") else { return nil }
        // Already registered (e.g. a second process-wide call) is fine.
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }

    /// The frequency's font. Never scales (`fixedSize`), like the boxes'
    /// SF Mono always was.
    public static func font(_ font: VFODigitFont, size: CGFloat, bold: Bool) -> Font {
        let weight: Font.Weight = bold ? .bold : .medium
        switch font {
        case .systemMono:
            return .system(size: size, weight: weight, design: .monospaced)
        case .menlo:
            return .custom("Menlo", fixedSize: size).weight(weight)
        case .sevenSegment:
            let name = bold ? (sevenSegmentNames.bold ?? sevenSegmentNames.regular) : sevenSegmentNames.regular
            guard let name else { return .system(size: size, weight: weight, design: .monospaced) }
            return .custom(name, fixedSize: size)
        }
    }

    /// Whether the 7-segment font is available (it is unless the package's
    /// resources went missing).
    public static var hasSevenSegment: Bool { sevenSegmentNames.regular != nil }
}

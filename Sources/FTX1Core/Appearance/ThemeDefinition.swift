import Foundation

// Settings → Appearance → Theme. A port of the Windows app's
// `Models/ThemeDefinition.cs` (same presets, same colour values); kept free
// of SwiftUI so `ThemeTests` cover it. `ThemeStyling.swift` turns it into
// SwiftUI colours, fills and button styles.

/// The system appearance a theme is built on: whatever a theme leaves unset
/// comes from it.
public enum ThemeBase: String, Codable, Sendable, Hashable {
    case light
    case dark
}

/// The VFO frequency digits' font. `systemMono` is SF Mono, the boxes as
/// they always looked; `sevenSegment` is the bundled DSEG7 Classic
/// (`Resources/Fonts`, SIL OFL).
public enum VFODigitFont: String, CaseIterable, Codable, Sendable, Hashable {
    case systemMono
    case menlo
    case sevenSegment

    public var displayName: String {
        switch self {
        case .systemMono: "SF Mono"
        case .menlo: "Menlo"
        case .sevenSegment: "7-segment"
        }
    }
}

/// A 32-bit ARGB colour parsed from "#RRGGBB" or "#AARRGGBB" — the form
/// theme JSON stores.
public struct ThemeColor: Hashable, Sendable, CustomStringConvertible {
    public var a: UInt8
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(a: UInt8, r: UInt8, g: UInt8, b: UInt8) {
        self.a = a
        self.r = r
        self.g = g
        self.b = b
    }

    public init?(hex: String?) {
        guard var digits = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit),
              var value = UInt32(digits, radix: 16) else { return nil }
        if digits.count == 6 { value |= 0xFF00_0000 }
        self.init(a: UInt8(value >> 24), r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }

    public static func parse(_ hex: String) throws -> ThemeColor {
        guard let color = ThemeColor(hex: hex) else { throw ThemeError.badColor(hex) }
        return color
    }

    public var description: String { String(format: "#%02X%02X%02X%02X", a, r, g, b) }
}

public enum ThemeError: Error, Equatable {
    case badColor(String)
    case emptyFill
    case mismatchedOffsets
}

/// A solid colour (one entry in `colors`) or a top-to-bottom gradient (two
/// or more). `offsets`, when given, place each colour (0 top, 1 bottom);
/// otherwise they're spread evenly. A gradient with a sharp step in the
/// middle is what reads as "glossy".
public struct ThemeFill: Codable, Hashable, Sendable {
    public var colors: [String]
    public var offsets: [Double]?

    public init(colors: [String], offsets: [Double]? = nil) {
        self.colors = colors
        self.offsets = offsets
    }

    public static func solid(_ color: String) -> ThemeFill { ThemeFill(colors: [color]) }

    public static func vertical(_ stops: (String, Double)...) -> ThemeFill {
        ThemeFill(colors: stops.map(\.0), offsets: stops.map(\.1))
    }

    public var isGradient: Bool { colors.count > 1 }

    /// Each colour with its offset; throws on a bad colour or a mismatched
    /// `offsets` list, so a broken custom theme fails at load, not mid-draw.
    public func stops() throws -> [(color: ThemeColor, offset: Double)] {
        guard !colors.isEmpty else { throw ThemeError.emptyFill }
        if let offsets, offsets.count != colors.count { throw ThemeError.mismatchedOffsets }
        return try colors.enumerated().map { index, hex in
            let offset = offsets?[index] ?? (colors.count == 1 ? 0 : Double(index) / Double(colors.count - 1))
            return (try ThemeColor.parse(hex), offset)
        }
    }
}

/// The VFO boxes (`VFODisplayBox`). Unlike Windows, every field is
/// optional: nil keeps the Mac's own look (green digits on black, a green
/// border while that receiver is shown), so the default themes change
/// nothing. A box whose receiver isn't shown (SUB in single-receive
/// display) still dims its text, themed or not.
public struct VFOTheme: Codable, Hashable, Sendable {
    public var background: ThemeFill?
    /// While that receiver is shown.
    public var border: ThemeFill?
    /// SUB in single-receive display.
    public var borderInactive: ThemeFill?
    public var digits: String?
    public var digitFont: VFODigitFont?
    public var digitsBold: Bool?
    /// The 7-segment font's unlit segments ("8"s behind the digits), an LCD
    /// look; ignored for the other fonts.
    public var unlitSegments: String?
    /// MAIN/SUB.
    public var label: String?
    public var mode: String?
    public var modeBorder: String?
    public var callsign: String?
    public var memoryChannel: String?
    /// The reflector / APRS / SCAN line.
    public var secondary: String?

    public init(
        background: ThemeFill? = nil, border: ThemeFill? = nil, borderInactive: ThemeFill? = nil,
        digits: String? = nil, digitFont: VFODigitFont? = nil, digitsBold: Bool? = nil, unlitSegments: String? = nil,
        label: String? = nil, mode: String? = nil, modeBorder: String? = nil, callsign: String? = nil,
        memoryChannel: String? = nil, secondary: String? = nil
    ) {
        self.background = background
        self.border = border
        self.borderInactive = borderInactive
        self.digits = digits
        self.digitFont = digitFont
        self.digitsBold = digitsBold
        self.unlitSegments = unlitSegments
        self.label = label
        self.mode = mode
        self.modeBorder = modeBorder
        self.callsign = callsign
        self.memoryChannel = memoryChannel
        self.secondary = secondary
    }
}

/// One theme: a base appearance plus overrides. A nil override keeps the
/// base's own look. Transmit/status colours (the TXRX and RX tags, PTT
/// while keyed, the Connected button, the meters' red zone) aren't here on
/// purpose: a theme mustn't be able to make transmit look like receive.
public struct ThemeDefinition: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var base: ThemeBase

    public var windowBackground: ThemeFill?
    /// Panels (the filter block's frame).
    public var panelBackground: ThemeFill?

    public var buttonBackground: ThemeFill?
    public var buttonBackgroundHover: ThemeFill?
    public var buttonBackgroundPressed: ThemeFill?
    public var buttonBackgroundDisabled: ThemeFill?
    public var buttonBorder: ThemeFill?
    public var buttonForeground: String?
    public var buttonForegroundDisabled: String?
    /// Toggle buttons while on (N/W, Notch, Waterfall, Mute…).
    public var buttonCheckedBackground: ThemeFill?
    public var buttonCheckedBackgroundHover: ThemeFill?
    public var buttonCheckedBackgroundPressed: ThemeFill?
    public var buttonCheckedForeground: String?

    /// Sliders, toggles, focus (`.tint`).
    public var accent: String?
    /// The small captions (SQL, VOL, zoom, status lines).
    public var secondaryText: String?
    /// The MENU grid's value line; nil = Settings' Button Value Color.
    public var menuValueColor: String?

    public var vfo: VFOTheme

    public var id: String { name }

    public init(
        name: String, base: ThemeBase,
        windowBackground: ThemeFill? = nil, panelBackground: ThemeFill? = nil,
        buttonBackground: ThemeFill? = nil, buttonBackgroundHover: ThemeFill? = nil,
        buttonBackgroundPressed: ThemeFill? = nil, buttonBackgroundDisabled: ThemeFill? = nil,
        buttonBorder: ThemeFill? = nil, buttonForeground: String? = nil, buttonForegroundDisabled: String? = nil,
        buttonCheckedBackground: ThemeFill? = nil, buttonCheckedBackgroundHover: ThemeFill? = nil,
        buttonCheckedBackgroundPressed: ThemeFill? = nil, buttonCheckedForeground: String? = nil,
        accent: String? = nil, secondaryText: String? = nil, menuValueColor: String? = nil,
        vfo: VFOTheme = VFOTheme()
    ) {
        self.name = name
        self.base = base
        self.windowBackground = windowBackground
        self.panelBackground = panelBackground
        self.buttonBackground = buttonBackground
        self.buttonBackgroundHover = buttonBackgroundHover
        self.buttonBackgroundPressed = buttonBackgroundPressed
        self.buttonBackgroundDisabled = buttonBackgroundDisabled
        self.buttonBorder = buttonBorder
        self.buttonForeground = buttonForeground
        self.buttonForegroundDisabled = buttonForegroundDisabled
        self.buttonCheckedBackground = buttonCheckedBackground
        self.buttonCheckedBackgroundHover = buttonCheckedBackgroundHover
        self.buttonCheckedBackgroundPressed = buttonCheckedBackgroundPressed
        self.buttonCheckedForeground = buttonCheckedForeground
        self.accent = accent
        self.secondaryText = secondaryText
        self.menuValueColor = menuValueColor
        self.vfo = vfo
    }

    /// Whether buttons are drawn by the theme (`ThemedButtonStyle`) rather
    /// than the system.
    public var stylesButtons: Bool { buttonBackground != nil }

    /// Parses every colour, so a broken theme is caught as a whole.
    public func validate() throws {
        let fills = [
            windowBackground, panelBackground, buttonBackground, buttonBackgroundHover, buttonBackgroundPressed,
            buttonBackgroundDisabled, buttonBorder, buttonCheckedBackground, buttonCheckedBackgroundHover,
            buttonCheckedBackgroundPressed, vfo.background, vfo.border, vfo.borderInactive,
        ]
        for fill in fills.compactMap({ $0 }) {
            _ = try fill.stops()
        }
        let colors = [
            buttonForeground, buttonForegroundDisabled, buttonCheckedForeground, accent, secondaryText, menuValueColor,
            vfo.digits, vfo.unlitSegments, vfo.label, vfo.mode, vfo.modeBorder, vfo.callsign, vfo.memoryChannel,
            vfo.secondary,
        ]
        for color in colors.compactMap({ $0 }) {
            _ = try ThemeColor.parse(color)
        }
    }
}

/// The built-in themes, and "Auto" (Default Light or Default Dark,
/// following the system). Themes are chosen by name, so adding one can't
/// shift a saved choice. Colour values are the Windows app's.
public enum ThemePresets {
    public static let auto = "Auto"

    /// The app exactly as it looked before themes.
    public static let defaultLight = ThemeDefinition(name: "Default Light", base: .light)
    public static let defaultDark = ThemeDefinition(name: "Default Dark", base: .dark)

    /// Dark mode's black lifted to charcoal, with buttons lit from above:
    /// a lighter top half stepping down to a darker bottom, and a light
    /// top edge.
    public static let glossyBlack = ThemeDefinition(
        name: "Glossy Black",
        base: .dark,
        windowBackground: .vertical(("#FF2C2F34", 0), ("#FF1C1D20", 1)),
        panelBackground: .vertical(("#FF34373D", 0), ("#FF26282C", 1)),
        buttonBackground: .vertical(("#FF5A5E66", 0), ("#FF41444A", 0.48), ("#FF2E3035", 0.52), ("#FF26282C", 1)),
        buttonBackgroundHover: .vertical(("#FF6C717A", 0), ("#FF51555C", 0.48), ("#FF3A3D43", 0.52), ("#FF303237", 1)),
        buttonBackgroundPressed: .vertical(("#FF1E1F22", 0), ("#FF2A2C30", 0.5), ("#FF35383D", 1)),
        buttonBackgroundDisabled: .solid("#FF2A2C30"),
        buttonBorder: .vertical(("#80FFFFFF", 0), ("#30FFFFFF", 0.15), ("#40000000", 1)),
        buttonForeground: "#FFF2F4F7",
        buttonForegroundDisabled: "#FF6E727A",
        buttonCheckedBackground: .vertical(("#FF4F8EF0", 0), ("#FF2D6BD0", 0.48), ("#FF1C4E9E", 0.52), ("#FF163E80", 1)),
        buttonCheckedBackgroundHover: .vertical(("#FF6AA2F5", 0), ("#FF3A7AE0", 0.48), ("#FF235AAF", 0.52), ("#FF1B4890", 1)),
        buttonCheckedBackgroundPressed: .vertical(("#FF123468", 0), ("#FF1C4E9E", 1)),
        buttonCheckedForeground: "#FFFFFFFF",
        accent: "#FF4F8EF0",
        secondaryText: "#FFA3A8B0",
        vfo: VFOTheme(
            background: .vertical(("#FF1A1C20", 0), ("#FF0C0D0F", 0.5), ("#FF050506", 1)),
            border: .vertical(("#FF9FC7E8", 0), ("#FF4A7392", 1)),
            borderInactive: .solid("#FF3A3D42"),
            digits: "#FFE4F2FF",
            digitFont: .sevenSegment,
            unlitSegments: "#1AE4F2FF",
            label: "#FFD8DEE6",
            mode: "#FF7CE38B",
            modeBorder: "#FF5A6068",
            callsign: "#FF6FB4FF",
            memoryChannel: "#FFFFA040",
            secondary: "#FF8C929B"
        )
    )

    /// A light theme after Visual Studio's Silky Pink, sampled from it:
    /// dusty rose chrome, near-white panels, warm near-black text and its
    /// deep mauve-rose accent for toggled buttons and sliders. The VFO
    /// boxes are dark mauve so the frequency still reads like a display.
    public static let dustyRose = ThemeDefinition(
        name: "Dusty Rose",
        base: .light,
        windowBackground: .vertical(("#FFF3E8E6", 0), ("#FFEEDFDC", 1)),
        panelBackground: .solid("#FFFBF8F8"),
        buttonBackground: .vertical(("#FFFFFFFF", 0), ("#FFFAF5F4", 0.5), ("#FFF1E5E2", 1)),
        buttonBackgroundHover: .vertical(("#FFFFFFFF", 0), ("#FFF6EEEC", 0.5), ("#FFEAD9D5", 1)),
        buttonBackgroundPressed: .vertical(("#FFE3CFCA", 0), ("#FFEFE2DF", 1)),
        buttonBackgroundDisabled: .solid("#FFF3EAE8"),
        buttonBorder: .vertical(("#FFE6D6D2", 0), ("#FFC9B0AA", 1)),
        buttonForeground: "#FF3B2622",
        buttonForegroundDisabled: "#FFB3A19C",
        buttonCheckedBackground: .vertical(("#FF9A6158", 0), ("#FF7A453D", 0.5), ("#FF653530", 1)),
        buttonCheckedBackgroundHover: .vertical(("#FFA86D64", 0), ("#FF88524A", 0.5), ("#FF703D37", 1)),
        buttonCheckedBackgroundPressed: .vertical(("#FF55302A", 0), ("#FF6A3B34", 1)),
        buttonCheckedForeground: "#FFFFFFFF",
        accent: "#FF7A453D",
        secondaryText: "#FF85726E",
        vfo: VFOTheme(
            background: .vertical(("#FF4A2C28", 0), ("#FF341E1B", 0.5), ("#FF261512", 1)),
            border: .vertical(("#FFD8B9B2", 0), ("#FF7A453D", 1)),
            borderInactive: .solid("#FFCDBDB9"),
            digits: "#FFFBEFEC",
            unlitSegments: "#1CFBEFEC",
            label: "#FFF6EEEC",
            mode: "#FFA8E0C0",
            modeBorder: "#FF8A645E",
            callsign: "#FF9CC7FF",
            memoryChannel: "#FFFFB86B",
            secondary: "#FFB79C96"
        )
    )

    /// A light theme after Visual Studio's Icy Mint: frosted mint
    /// backgrounds, white buttons shading to pale mint, deep teal text, a
    /// teal accent, and dark teal VFO boxes with icy digits.
    public static let icyMint = ThemeDefinition(
        name: "Icy Mint",
        base: .light,
        windowBackground: .vertical(("#FFF3FCF9", 0), ("#FFDDF3EC", 1)),
        panelBackground: .solid("#FFF7FDFB"),
        buttonBackground: .vertical(("#FFFFFFFF", 0), ("#FFEFFAF6", 0.5), ("#FFD8F1E9", 1)),
        buttonBackgroundHover: .vertical(("#FFF5FDFA", 0), ("#FFE1F6EF", 0.5), ("#FFC9EBDF", 1)),
        buttonBackgroundPressed: .vertical(("#FFB9E3D6", 0), ("#FFD3EFE6", 1)),
        buttonBackgroundDisabled: .solid("#FFEAF5F1"),
        buttonBorder: .vertical(("#FFC2E8DC", 0), ("#FF8FCDBB", 1)),
        buttonForeground: "#FF1F4D47",
        buttonForegroundDisabled: "#FF9DBDB6",
        buttonCheckedBackground: .vertical(("#FF4FCDB7", 0), ("#FF27AD97", 0.5), ("#FF1A917E", 1)),
        buttonCheckedBackgroundHover: .vertical(("#FF66D8C3", 0), ("#FF34BBA4", 0.5), ("#FF219C88", 1)),
        buttonCheckedBackgroundPressed: .vertical(("#FF147867", 0), ("#FF1A917E", 1)),
        buttonCheckedForeground: "#FFFFFFFF",
        accent: "#FF1FA08B",
        secondaryText: "#FF5F8C84",
        vfo: VFOTheme(
            background: .vertical(("#FF1C4A45", 0), ("#FF123531", 0.5), ("#FF0B2421", 1)),
            border: .vertical(("#FFB4F0E2", 0), ("#FF4FB8A2", 1)),
            borderInactive: .solid("#FFA9C9C1"),
            digits: "#FFE6FFF9",
            unlitSegments: "#1CE6FFF9",
            label: "#FFDDF7F0",
            mode: "#FFFFD88A",
            modeBorder: "#FF4E7F77",
            callsign: "#FF8CC8FF",
            memoryChannel: "#FFFFB86B",
            secondary: "#FF8DBFB5"
        )
    )

    public static let all: [ThemeDefinition] = [defaultLight, defaultDark, glossyBlack, dustyRose, icyMint]

    /// The names the picker lists, Auto first.
    public static let names: [String] = [auto] + all.map(\.name)

    /// The theme for a saved name, or nil for Auto (or a name that no
    /// longer exists): the system appearance, no overrides.
    public static func named(_ name: String?) -> ThemeDefinition? {
        all.first { $0.name == name }
    }

    /// Like Windows' `Resolve`: Auto (or an unknown name) is Default
    /// Light/Dark by the system appearance.
    public static func resolve(_ name: String?, systemIsDark: Bool) -> ThemeDefinition {
        named(name) ?? (systemIsDark ? defaultDark : defaultLight)
    }

    /// The old Light/Dark/Auto setting (`AppTheme`'s raw value under
    /// `appearance.theme`) as a theme name.
    public static func fromLegacy(_ legacy: AppTheme) -> String {
        switch legacy {
        case .light: defaultLight.name
        case .dark: defaultDark.name
        case .system: auto
        }
    }
}

/// What the 7-segment font draws: DSEG7 has no em dash, and its "!" is a
/// blank as wide as a digit, so the unlit-segment layer can be the same
/// string with every digit (and blank) an "8".
public enum SevenSegmentText {
    /// The placeholder the boxes show before the first read.
    public static let placeholder = "---.---.---"

    /// MHz padded to three places with blanks, so the digits sit in the
    /// same cells on every band, like a real LCD. Empty or a dash (the
    /// boxes' "no frequency" text) is the placeholder.
    public static func lit(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == "—" || text.allSatisfy({ $0 == "-" || $0 == "." || $0 == " " }) {
            return placeholder
        }
        let mhz = text.firstIndex(of: ".").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
        return mhz < 3 ? String(repeating: "!", count: 3 - mhz) + text : text
    }

    /// "8.888.888" behind "7.074.000"; keeps the dots in place.
    public static func unlit(_ lit: String) -> String {
        String(lit.map { $0.isNumber || $0 == "-" || $0 == "!" || $0 == " " ? "8" : $0 })
    }
}

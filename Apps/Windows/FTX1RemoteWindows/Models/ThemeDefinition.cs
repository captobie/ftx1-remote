using System.Globalization;
using System.Text.Json.Serialization;

namespace FTX1RemoteWindows.Models;

/// The WinUI theme a theme is built on: whatever a theme leaves unset
/// comes from it. Stored by name in theme JSON.
[JsonConverter(typeof(JsonStringEnumConverter<ThemeBase>))]
public enum ThemeBase
{
    Light,
    Dark,
}

/// The VFO frequency digits' font. SevenSegment is the bundled DSEG7
/// Classic (Assets/Fonts, SIL OFL). Stored by name in theme JSON.
[JsonConverter(typeof(JsonStringEnumConverter<VfoDigitFont>))]
public enum VfoDigitFont
{
    Consolas,
    CascadiaMono,
    SevenSegment,
}

/// A 32-bit ARGB colour parsed from "#RRGGBB" or "#AARRGGBB" — the form
/// theme JSON stores. Kept free of WinUI so the theme model is testable.
public readonly record struct ThemeColor(byte A, byte R, byte G, byte B)
{
    public static ThemeColor Parse(string hex)
    {
        if (!TryParse(hex, out var color))
        {
            throw new FormatException($"Not a #RRGGBB or #AARRGGBB colour: \"{hex}\"");
        }
        return color;
    }

    public static bool TryParse(string? hex, out ThemeColor color)
    {
        color = default;
        var digits = hex?.Trim().TrimStart('#') ?? "";
        if ((digits.Length != 6 && digits.Length != 8)
            || !uint.TryParse(digits, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
        {
            return false;
        }
        if (digits.Length == 6)
        {
            value |= 0xFF000000;
        }
        color = new ThemeColor((byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value);
        return true;
    }

    public override string ToString() => $"#{A:X2}{R:X2}{G:X2}{B:X2}";
}

/// A solid colour (one entry in Colors) or a top-to-bottom gradient (two or
/// more). Offsets, when given, place each colour (0 top, 1 bottom);
/// otherwise they're spread evenly. A gradient with a sharp step in the
/// middle is what reads as "glossy".
public sealed record ThemeFill(IReadOnlyList<string> Colors, IReadOnlyList<double>? Offsets = null)
{
    public static ThemeFill Solid(string color) => new([color]);

    public static ThemeFill Vertical(params (string Color, double Offset)[] stops) =>
        new(stops.Select(s => s.Color).ToArray(), stops.Select(s => s.Offset).ToArray());

    [JsonIgnore]
    public bool IsGradient => Colors.Count > 1;

    /// Each colour with its offset; throws on a bad colour or a mismatched
    /// Offsets list, so a broken custom theme fails at load, not mid-draw.
    public IReadOnlyList<(ThemeColor Color, double Offset)> Stops()
    {
        if (Colors.Count == 0)
        {
            throw new FormatException("A theme fill needs at least one colour");
        }
        if (Offsets is { } offsets && offsets.Count != Colors.Count)
        {
            throw new FormatException("A theme fill's offsets must match its colours");
        }
        return Colors.Select((c, i) => (ThemeColor.Parse(c),
            Offsets?[i] ?? (Colors.Count == 1 ? 0 : (double)i / (Colors.Count - 1)))).ToArray();
    }
}

/// The VFO boxes. These are drawn by the app, not WinUI, so every field
/// has a value — the defaults are the boxes as they always looked.
public sealed record VfoTheme
{
    public ThemeFill Background { get; init; } = ThemeFill.Solid("#FF000000");
    /// While that receiver is shown.
    public ThemeFill Border { get; init; } = ThemeFill.Solid("#B300FF00");
    /// SUB in single-receive display.
    public ThemeFill BorderInactive { get; init; } = ThemeFill.Solid("#66808080");
    public string Digits { get; init; } = "#FFFFFFFF";
    public VfoDigitFont DigitFont { get; init; } = VfoDigitFont.Consolas;
    public bool DigitsBold { get; init; }
    /// The 7-segment font's unlit segments ("8"s behind the digits), an LCD
    /// look; ignored for the other fonts.
    public string? UnlitSegments { get; init; }
    /// MAIN/SUB.
    public string Label { get; init; } = "#FFFFFFFF";
    public string Mode { get; init; } = "#FF32CD32";
    public string ModeBorder { get; init; } = "#FF808080";
    public string Callsign { get; init; } = "#FF1E90FF";
    public string MemoryChannel { get; init; } = "#FFFF8C00";
    /// The reflector / APRS / SCAN line.
    public string Secondary { get; init; } = "#FF808080";
}

/// One theme: a base WinUI theme plus overrides. A null override keeps the
/// base theme's own look. Transmit/status colours (the TXRX and RX tags,
/// PTT while keyed, the squelch light, the meters' red zone) aren't here on
/// purpose: a theme mustn't be able to make transmit look like receive.
public sealed record ThemeDefinition
{
    public required string Name { get; init; }
    public ThemeBase Base { get; init; } = ThemeBase.Dark;

    public ThemeFill? WindowBackground { get; init; }
    /// Cards and panels (Settings' cards, the filter display's frame).
    public ThemeFill? PanelBackground { get; init; }

    public ThemeFill? ButtonBackground { get; init; }
    public ThemeFill? ButtonBackgroundHover { get; init; }
    public ThemeFill? ButtonBackgroundPressed { get; init; }
    public ThemeFill? ButtonBackgroundDisabled { get; init; }
    public ThemeFill? ButtonBorder { get; init; }
    public string? ButtonForeground { get; init; }
    public string? ButtonForegroundDisabled { get; init; }
    /// Toggle buttons while on (V/M, Waterfall, Mute…).
    public ThemeFill? ButtonCheckedBackground { get; init; }
    public ThemeFill? ButtonCheckedBackgroundHover { get; init; }
    public ThemeFill? ButtonCheckedBackgroundPressed { get; init; }
    public string? ButtonCheckedForeground { get; init; }

    /// Slider fill, toggle switches, focus.
    public string? Accent { get; init; }
    /// The small captions (SQL, VOL, zoom, status lines).
    public string? SecondaryText { get; init; }
    /// The MENU grid's value line; null = Settings' Button value color.
    public string? MenuValueColor { get; init; }

    public VfoTheme Vfo { get; init; } = new();

    /// Parses every colour, so a broken theme is caught as a whole.
    public void Validate()
    {
        foreach (var fill in new[]
                 {
                     WindowBackground, PanelBackground, ButtonBackground, ButtonBackgroundHover, ButtonBackgroundPressed,
                     ButtonBackgroundDisabled, ButtonBorder, ButtonCheckedBackground, ButtonCheckedBackgroundHover,
                     ButtonCheckedBackgroundPressed, Vfo.Background, Vfo.Border, Vfo.BorderInactive,
                 })
        {
            fill?.Stops();
        }
        foreach (var color in new[]
                 {
                     ButtonForeground, ButtonForegroundDisabled, ButtonCheckedForeground, Accent, SecondaryText, MenuValueColor,
                     Vfo.Digits, Vfo.UnlitSegments, Vfo.Label, Vfo.Mode, Vfo.ModeBorder, Vfo.Callsign, Vfo.MemoryChannel, Vfo.Secondary,
                 })
        {
            if (color is not null)
            {
                ThemeColor.Parse(color);
            }
        }
    }
}

/// The built-in themes, and "Auto" (Default Light or Default Dark,
/// following Windows' app mode). Themes are chosen by name, so adding one
/// can't shift a saved choice.
public static class ThemePresets
{
    public const string Auto = "Auto";

    /// The app exactly as it looked before themes.
    public static readonly ThemeDefinition DefaultLight = new() { Name = "Default Light", Base = ThemeBase.Light };
    public static readonly ThemeDefinition DefaultDark = new() { Name = "Default Dark", Base = ThemeBase.Dark };

    /// Dark mode's black lifted to charcoal, with buttons lit from above:
    /// a lighter top half stepping down to a darker bottom, and a light
    /// top edge.
    public static readonly ThemeDefinition GlossyBlack = new()
    {
        Name = "Glossy Black",
        Base = ThemeBase.Dark,
        WindowBackground = ThemeFill.Vertical(("#FF2C2F34", 0), ("#FF1C1D20", 1)),
        PanelBackground = ThemeFill.Vertical(("#FF34373D", 0), ("#FF26282C", 1)),
        ButtonBackground = ThemeFill.Vertical(("#FF5A5E66", 0), ("#FF41444A", 0.48), ("#FF2E3035", 0.52), ("#FF26282C", 1)),
        ButtonBackgroundHover = ThemeFill.Vertical(("#FF6C717A", 0), ("#FF51555C", 0.48), ("#FF3A3D43", 0.52), ("#FF303237", 1)),
        ButtonBackgroundPressed = ThemeFill.Vertical(("#FF1E1F22", 0), ("#FF2A2C30", 0.5), ("#FF35383D", 1)),
        ButtonBackgroundDisabled = ThemeFill.Solid("#FF2A2C30"),
        ButtonBorder = ThemeFill.Vertical(("#80FFFFFF", 0), ("#30FFFFFF", 0.15), ("#40000000", 1)),
        ButtonForeground = "#FFF2F4F7",
        ButtonForegroundDisabled = "#FF6E727A",
        ButtonCheckedBackground = ThemeFill.Vertical(("#FF4F8EF0", 0), ("#FF2D6BD0", 0.48), ("#FF1C4E9E", 0.52), ("#FF163E80", 1)),
        ButtonCheckedBackgroundHover = ThemeFill.Vertical(("#FF6AA2F5", 0), ("#FF3A7AE0", 0.48), ("#FF235AAF", 0.52), ("#FF1B4890", 1)),
        ButtonCheckedBackgroundPressed = ThemeFill.Vertical(("#FF123468", 0), ("#FF1C4E9E", 1)),
        ButtonCheckedForeground = "#FFFFFFFF",
        Accent = "#FF4F8EF0",
        SecondaryText = "#FFA3A8B0",
        Vfo = new VfoTheme
        {
            Background = ThemeFill.Vertical(("#FF1A1C20", 0), ("#FF0C0D0F", 0.5), ("#FF050506", 1)),
            Border = ThemeFill.Vertical(("#FF9FC7E8", 0), ("#FF4A7392", 1)),
            BorderInactive = ThemeFill.Solid("#FF3A3D42"),
            Digits = "#FFE4F2FF",
            DigitFont = VfoDigitFont.SevenSegment,
            UnlitSegments = "#1AE4F2FF",
            Label = "#FFD8DEE6",
            Mode = "#FF7CE38B",
            ModeBorder = "#FF5A6068",
            Callsign = "#FF6FB4FF",
            MemoryChannel = "#FFFFA040",
            Secondary = "#FF8C929B",
        },
    };

    /// Dusty Rose: a light theme after Visual Studio's Silky Pink, sampled from it
    /// (2026-10-26): dusty rose chrome (#F0E3E1), near-white panels
    /// (#FBF8F8), warm near-black text and its deep mauve-rose accent
    /// (#7A453D, VS's window frame) for toggled buttons and sliders. The
    /// VFO boxes are dark mauve so the frequency still reads like a display.
    public static readonly ThemeDefinition DustyRose = new()
    {
        Name = "Dusty Rose",
        Base = ThemeBase.Light,
        WindowBackground = ThemeFill.Vertical(("#FFF3E8E6", 0), ("#FFEEDFDC", 1)),
        PanelBackground = ThemeFill.Solid("#FFFBF8F8"),
        ButtonBackground = ThemeFill.Vertical(("#FFFFFFFF", 0), ("#FFFAF5F4", 0.5), ("#FFF1E5E2", 1)),
        ButtonBackgroundHover = ThemeFill.Vertical(("#FFFFFFFF", 0), ("#FFF6EEEC", 0.5), ("#FFEAD9D5", 1)),
        ButtonBackgroundPressed = ThemeFill.Vertical(("#FFE3CFCA", 0), ("#FFEFE2DF", 1)),
        ButtonBackgroundDisabled = ThemeFill.Solid("#FFF3EAE8"),
        ButtonBorder = ThemeFill.Vertical(("#FFE6D6D2", 0), ("#FFC9B0AA", 1)),
        ButtonForeground = "#FF3B2622",
        ButtonForegroundDisabled = "#FFB3A19C",
        ButtonCheckedBackground = ThemeFill.Vertical(("#FF9A6158", 0), ("#FF7A453D", 0.5), ("#FF653530", 1)),
        ButtonCheckedBackgroundHover = ThemeFill.Vertical(("#FFA86D64", 0), ("#FF88524A", 0.5), ("#FF703D37", 1)),
        ButtonCheckedBackgroundPressed = ThemeFill.Vertical(("#FF55302A", 0), ("#FF6A3B34", 1)),
        ButtonCheckedForeground = "#FFFFFFFF",
        Accent = "#FF7A453D",
        SecondaryText = "#FF85726E",
        Vfo = new VfoTheme
        {
            Background = ThemeFill.Vertical(("#FF4A2C28", 0), ("#FF341E1B", 0.5), ("#FF261512", 1)),
            Border = ThemeFill.Vertical(("#FFD8B9B2", 0), ("#FF7A453D", 1)),
            BorderInactive = ThemeFill.Solid("#FFCDBDB9"),
            Digits = "#FFFBEFEC",
            UnlitSegments = "#1CFBEFEC",
            Label = "#FFF6EEEC",
            Mode = "#FFA8E0C0",
            ModeBorder = "#FF8A645E",
            Callsign = "#FF9CC7FF",
            MemoryChannel = "#FFFFB86B",
            Secondary = "#FFB79C96",
        },
    };

    /// A light theme after Visual Studio's Icy Mint: frosted mint
    /// backgrounds, white buttons shading to pale mint, deep teal text, a
    /// teal accent, and dark teal VFO boxes with icy digits.
    public static readonly ThemeDefinition IcyMint = new()
    {
        Name = "Icy Mint",
        Base = ThemeBase.Light,
        WindowBackground = ThemeFill.Vertical(("#FFF3FCF9", 0), ("#FFDDF3EC", 1)),
        PanelBackground = ThemeFill.Solid("#FFF7FDFB"),
        ButtonBackground = ThemeFill.Vertical(("#FFFFFFFF", 0), ("#FFEFFAF6", 0.5), ("#FFD8F1E9", 1)),
        ButtonBackgroundHover = ThemeFill.Vertical(("#FFF5FDFA", 0), ("#FFE1F6EF", 0.5), ("#FFC9EBDF", 1)),
        ButtonBackgroundPressed = ThemeFill.Vertical(("#FFB9E3D6", 0), ("#FFD3EFE6", 1)),
        ButtonBackgroundDisabled = ThemeFill.Solid("#FFEAF5F1"),
        ButtonBorder = ThemeFill.Vertical(("#FFC2E8DC", 0), ("#FF8FCDBB", 1)),
        ButtonForeground = "#FF1F4D47",
        ButtonForegroundDisabled = "#FF9DBDB6",
        ButtonCheckedBackground = ThemeFill.Vertical(("#FF4FCDB7", 0), ("#FF27AD97", 0.5), ("#FF1A917E", 1)),
        ButtonCheckedBackgroundHover = ThemeFill.Vertical(("#FF66D8C3", 0), ("#FF34BBA4", 0.5), ("#FF219C88", 1)),
        ButtonCheckedBackgroundPressed = ThemeFill.Vertical(("#FF147867", 0), ("#FF1A917E", 1)),
        ButtonCheckedForeground = "#FFFFFFFF",
        Accent = "#FF1FA08B",
        SecondaryText = "#FF5F8C84",
        Vfo = new VfoTheme
        {
            Background = ThemeFill.Vertical(("#FF1C4A45", 0), ("#FF123531", 0.5), ("#FF0B2421", 1)),
            Border = ThemeFill.Vertical(("#FFB4F0E2", 0), ("#FF4FB8A2", 1)),
            BorderInactive = ThemeFill.Solid("#FFA9C9C1"),
            Digits = "#FFE6FFF9",
            UnlitSegments = "#1CE6FFF9",
            Label = "#FFDDF7F0",
            Mode = "#FFFFD88A",
            ModeBorder = "#FF4E7F77",
            Callsign = "#FF8CC8FF",
            MemoryChannel = "#FFFFB86B",
            Secondary = "#FF8DBFB5",
        },
    };

    public static IReadOnlyList<ThemeDefinition> All { get; } = [DefaultLight, DefaultDark, GlossyBlack, DustyRose, IcyMint];

    /// The names the picker lists, Auto first.
    public static IReadOnlyList<string> Names { get; } = [Auto, .. All.Select(t => t.Name)];

    /// The theme for a saved name; Auto (or a name that no longer exists)
    /// is Default Light/Dark by Windows' app mode.
    public static ThemeDefinition Resolve(string? name, bool systemIsDark) =>
        All.FirstOrDefault(t => t.Name == name) ?? (systemIsDark ? DefaultDark : DefaultLight);

    /// The old Light/Dark/Auto setting (settings.json's "Theme" number:
    /// 0 System, 1 Light, 2 Dark) as a theme name.
    public static string FromLegacy(int legacyTheme) => legacyTheme switch
    {
        1 => DefaultLight.Name,
        2 => DefaultDark.Name,
        _ => Auto,
    };
}

/// What the 7-segment font draws: DSEG7 has no em dash, and its "!" is a
/// blank as wide as a digit, so the unlit-segment layer can be the same
/// string with every digit (and blank) an "8".
public static class SevenSegmentText
{
    /// The placeholder the boxes show before the first read ("—").
    public const string Placeholder = "---.---.---";

    /// MHz padded to three places with blanks, so the digits sit in the
    /// same cells on every band, like a real LCD.
    public static string Lit(string text)
    {
        text = text.Trim();
        if (text is "—" or "")
        {
            return Placeholder;
        }
        var dot = text.IndexOf('.');
        var mhz = dot < 0 ? text.Length : dot;
        return mhz < 3 ? new string('!', 3 - mhz) + text : text;
    }

    /// "8.888.888" behind "7.074.000"; keeps the dots in place.
    public static string Unlit(string lit) =>
        new(lit.Select(c => char.IsDigit(c) || c is '-' or '!' or ' ' ? '8' : c).ToArray());
}

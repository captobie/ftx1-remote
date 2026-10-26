using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace FTX1RemoteWindows.Settings;

/// Settings → Appearance → Theme: turns a ThemeDefinition into WinUI
/// resources. The overrides go in one dictionary merged last into the
/// app's resources, so they beat XamlControlsResources' own brushes in
/// every window, flyout and dialog — WinUI's "lightweight styling", done
/// app-wide. Controls only re-read ThemeResources on a theme change, so
/// ApplyTo flips each window root's RequestedTheme to make them.
public static class ThemeEngine
{
    /// Captions the main window draws in gray (SQL, VOL, zoom…); the
    /// themes' SecondaryText. Always in the dictionary, since XAML refers
    /// to it.
    public const string SecondaryTextKey = "AppSecondaryTextBrush";
    private static readonly Color DefaultSecondaryText = Microsoft.UI.Colors.Gray;

    private static ResourceDictionary? _overrides;

    public static ThemeDefinition Current { get; private set; } = ThemePresets.DefaultDark;

    /// Auto: no RequestedTheme, so Windows' app mode decides.
    public static bool IsAuto { get; private set; } = true;

    /// The theme the window roots ask WinUI for.
    public static ElementTheme ElementTheme =>
        IsAuto ? ElementTheme.Default : Current.Base == ThemeBase.Light ? ElementTheme.Light : ElementTheme.Dark;

    /// Resolves the saved theme and rebuilds the override dictionary. Call
    /// before the first window loads (its XAML uses SecondaryTextKey), then
    /// ApplyTo on each window root.
    public static void Load()
    {
        var name = AppSettings.ThemeName;
        var systemIsDark = Application.Current.RequestedTheme == ApplicationTheme.Dark;
        Current = ThemePresets.Resolve(name, systemIsDark);
        IsAuto = Current.Name != name;
        try
        {
            Current.Validate();
        }
        catch (FormatException ex)
        {
            AppLog.Write($"theme: \"{Current.Name}\" is broken ({ex.Message}); using the default");
            Current = systemIsDark ? ThemePresets.DefaultDark : ThemePresets.DefaultLight;
            IsAuto = true;
        }

        var merged = Application.Current.Resources.MergedDictionaries;
        if (_overrides is not null)
        {
            merged.Remove(_overrides);
        }
        _overrides = BuildOverrides(Current);
        merged.Add(_overrides);
        AppLog.Write($"theme: {(IsAuto ? $"Auto ({Current.Name})" : Current.Name)}");
    }

    /// Puts a window's root on the current theme and makes its controls
    /// re-read the overrides. A same-value RequestedTheme set does nothing,
    /// hence the flip through the other theme first.
    public static void ApplyTo(FrameworkElement root)
    {
        var target = ElementTheme;
        root.RequestedTheme = target == ElementTheme.Dark ? ElementTheme.Light : ElementTheme.Dark;
        root.RequestedTheme = target;
    }

    /// The window background for roots that set it in code.
    public static Brush WindowBackground =>
        Current.WindowBackground is { } fill ? ToBrush(fill)
            : (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];

    public static Brush SecondaryTextBrush =>
        new SolidColorBrush(Current.SecondaryText is { } c ? ToColor(c) : DefaultSecondaryText);

    public static Color ToColor(string hex)
    {
        var c = ThemeColor.Parse(hex);
        return Color.FromArgb(c.A, c.R, c.G, c.B);
    }

    /// A new brush each call: a solid colour, or a vertical gradient.
    public static Brush ToBrush(ThemeFill fill)
    {
        var stops = fill.Stops();
        if (stops.Count == 1)
        {
            return new SolidColorBrush(ToColor(stops[0].Color));
        }
        var brush = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
        foreach (var (color, offset) in stops)
        {
            brush.GradientStops.Add(new GradientStop { Color = Color.FromArgb(color.A, color.R, color.G, color.B), Offset = offset });
        }
        return brush;
    }

    private static Color ToColor(ThemeColor c) => Color.FromArgb(c.A, c.R, c.G, c.B);

    /// The WinUI resource keys each theme field stands for. Buttons,
    /// toggle buttons and repeat buttons (the MENU grid's steppers) all get
    /// the same look; DropDownButton uses the Button keys.
    private static ResourceDictionary BuildOverrides(ThemeDefinition theme)
    {
        var entries = new Dictionary<string, Func<object>>();

        void Fill(ThemeFill? fill, params string[] keys)
        {
            if (fill is not null)
            {
                foreach (var key in keys)
                {
                    entries[key] = () => ToBrush(fill);
                }
            }
        }

        void Solid(string? color, params string[] keys)
        {
            if (color is not null)
            {
                foreach (var key in keys)
                {
                    entries[key] = () => new SolidColorBrush(ToColor(color));
                }
            }
        }

        static string[] AllButtons(string suffix) =>
            [$"Button{suffix}", $"ToggleButton{suffix}", $"RepeatButton{suffix}"];

        Fill(theme.WindowBackground, "ApplicationPageBackgroundThemeBrush");
        Fill(theme.PanelBackground, "CardBackgroundFillColorDefaultBrush");

        Fill(theme.ButtonBackground, AllButtons("Background"));
        Fill(theme.ButtonBackgroundHover, AllButtons("BackgroundPointerOver"));
        Fill(theme.ButtonBackgroundPressed, AllButtons("BackgroundPressed"));
        Fill(theme.ButtonBackgroundDisabled, [.. AllButtons("BackgroundDisabled"), "ToggleButtonBackgroundCheckedDisabled"]);
        Fill(theme.ButtonBorder, [
            .. AllButtons("BorderBrush"), .. AllButtons("BorderBrushPointerOver"), .. AllButtons("BorderBrushPressed"),
            "ToggleButtonBorderBrushChecked", "ToggleButtonBorderBrushCheckedPointerOver", "ToggleButtonBorderBrushCheckedPressed",
        ]);
        Solid(theme.ButtonForeground, [.. AllButtons("Foreground"), .. AllButtons("ForegroundPointerOver"), .. AllButtons("ForegroundPressed")]);
        Solid(theme.ButtonForegroundDisabled, [.. AllButtons("ForegroundDisabled"), "ToggleButtonForegroundCheckedDisabled"]);
        Fill(theme.ButtonCheckedBackground, "ToggleButtonBackgroundChecked");
        Fill(theme.ButtonCheckedBackgroundHover, "ToggleButtonBackgroundCheckedPointerOver");
        Fill(theme.ButtonCheckedBackgroundPressed, "ToggleButtonBackgroundCheckedPressed");
        Solid(theme.ButtonCheckedForeground,
            "ToggleButtonForegroundChecked", "ToggleButtonForegroundCheckedPointerOver", "ToggleButtonForegroundCheckedPressed");

        Solid(theme.Accent,
            "AccentFillColorDefaultBrush", "AccentFillColorSecondaryBrush", "AccentFillColorTertiaryBrush",
            "SliderTrackValueFill", "SliderTrackValueFillPointerOver", "SliderTrackValueFillPressed",
            "SliderThumbBackground", "SliderThumbBackgroundPointerOver", "SliderThumbBackgroundPressed",
            "ToggleSwitchFillOn", "ToggleSwitchFillOnPointerOver", "ToggleSwitchFillOnPressed");
        if (theme.Accent is { } accent)
        {
            entries["SystemAccentColor"] = () => ToColor(accent);
        }

        entries[SecondaryTextKey] = () => SecondaryTextBrush;

        // Lookups go by the element's theme, so the same overrides go in
        // each theme dictionary (WinUI's "Default" is its dark one).
        var dictionary = new ResourceDictionary();
        foreach (var themeKey in new[] { "Default", "Light", "Dark" })
        {
            var themed = new ResourceDictionary();
            foreach (var (key, make) in entries)
            {
                themed[key] = make();
            }
            dictionary.ThemeDictionaries[themeKey] = themed;
        }
        return dictionary;
    }
}

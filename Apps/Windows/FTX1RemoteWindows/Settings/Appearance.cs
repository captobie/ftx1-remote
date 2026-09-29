using Microsoft.UI;
using Microsoft.UI.Xaml;
using Windows.UI;

namespace FTX1RemoteWindows.Settings;

/// Port of Sources/FTX1Core/Appearance/AppTheme.swift: Auto follows
/// Windows' app mode. Stored by number in settings.json, so new cases go
/// at the end.
public enum AppTheme
{
    System,
    Light,
    Dark,
}

/// Port of ButtonValueColor.swift: the color of a MENU grid button's
/// value line (the current setting), orange by default like the rig's own
/// MENU display. Stored by number, so new cases go at the end.
public enum ButtonValueColor
{
    Orange,
    Red,
    Yellow,
    Green,
    Cyan,
    Blue,
    Pink,
    White,
}

public static class AppearanceExtensions
{
    public static string DisplayName(this AppTheme theme) => theme switch
    {
        AppTheme.Light => "Light",
        AppTheme.Dark => "Dark",
        _ => "Auto",
    };

    public static ElementTheme ElementTheme(this AppTheme theme) => theme switch
    {
        AppTheme.Light => Microsoft.UI.Xaml.ElementTheme.Light,
        AppTheme.Dark => Microsoft.UI.Xaml.ElementTheme.Dark,
        _ => Microsoft.UI.Xaml.ElementTheme.Default,
    };

    public static string DisplayName(this ButtonValueColor color) => color.ToString();

    /// Named WinUI colors picked to read on both the light and dark button
    /// backgrounds (White, like on the Mac, is for dark mode only).
    public static Color Color(this ButtonValueColor color) => color switch
    {
        ButtonValueColor.Red => Colors.Red,
        ButtonValueColor.Yellow => Colors.Gold,
        ButtonValueColor.Green => Colors.LimeGreen,
        ButtonValueColor.Cyan => Colors.DarkTurquoise,
        ButtonValueColor.Blue => Colors.DodgerBlue,
        ButtonValueColor.Pink => Colors.HotPink,
        ButtonValueColor.White => Colors.White,
        _ => Colors.Orange,
    };
}

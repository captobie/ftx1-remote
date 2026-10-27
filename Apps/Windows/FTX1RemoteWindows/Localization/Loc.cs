using System.Globalization;
using System.Resources;

namespace FTX1RemoteWindows;

/// The app's user-facing strings (Localization/Strings*.resx: English, plus
/// Spanish and German — the same languages as the Mac/iPad String Catalogs,
/// whose wording they reuse). The language is Windows' display language
/// (CurrentUICulture); there's no in-app picker. Keys are namespaced like the
/// Mac's ("mainWindow.connectFailed", "common.cancel"); a missing key shows as
/// the key itself. Radio terms, rig labels (MENU grid, Deep Settings), unit-only
/// formats, wire values and log text stay English and don't go through here.
///
/// XAML uses the {l:Str Key=…} markup extension (Str.cs); code uses S/F/P.
/// Arguments go into the resource's {0}, {1}… so a translation can move them —
/// never build a sentence by concatenating pieces.
public static class Loc
{
    private static readonly ResourceManager Resources =
        new("FTX1RemoteWindows.Localization.Strings", typeof(Loc).Assembly);

    /// Windows' own regional format, before <see cref="ApplyNumberFormat"/>
    /// changes the decimal separator — for parsing what the user typed.
    public static CultureInfo OsCulture { get; private set; } = CultureInfo.CurrentCulture;

    /// The string for <paramref name="key"/> in the current UI language.
    public static string S(string key) =>
        Resources.GetString(key, CultureInfo.CurrentUICulture) ?? key;

    /// The string for <paramref name="key"/> with its {0}, {1}… filled in.
    public static string F(string key, params object?[] args) =>
        string.Format(CultureInfo.CurrentCulture, S(key), args);

    /// A counted string: "<key>.one" when <paramref name="count"/> is 1, else
    /// "<key>.other" (English, Spanish and German all split there). The count
    /// is {0}; <paramref name="args"/> follow as {1}, {2}…
    public static string P(string key, long count, params object?[] args) =>
        F(key + (count == 1 ? ".one" : ".other"), [count, .. args]);

    /// Debug builds: FTX1REMOTE_UI_LANGUAGE=es (or de, en) shows the app in
    /// that language whatever Windows' display language is — for checking
    /// translations. WinUI's own control strings still follow Windows.
    [System.Diagnostics.Conditional("DEBUG")]
    public static void ApplyDebugLanguageOverride()
    {
        if (Environment.GetEnvironmentVariable("FTX1REMOTE_UI_LANGUAGE") is { Length: > 0 } language)
        {
            CultureInfo.CurrentUICulture = CultureInfo.DefaultThreadCurrentUICulture = new CultureInfo(language);
        }
    }

    /// Frequencies never follow the locale (es/de would write "14,074"): keep
    /// Windows' regional format for dates and the like, but with "." as the
    /// decimal separator, and a no-break space for grouping where the
    /// culture used "." for that. Also fixes culture-sensitive parsing of
    /// rigctld's replies. Call once at startup, before any window.
    public static void ApplyNumberFormat()
    {
        OsCulture = CultureInfo.CurrentCulture;
        if (OsCulture.NumberFormat.NumberDecimalSeparator == ".")
            return;
        var culture = (CultureInfo)OsCulture.Clone();
        var number = culture.NumberFormat;
        if (number.NumberGroupSeparator is "." or ",")
            number.NumberGroupSeparator = number.CurrencyGroupSeparator = number.PercentGroupSeparator = " ";
        number.NumberDecimalSeparator = number.CurrencyDecimalSeparator = number.PercentDecimalSeparator = ".";
        CultureInfo.CurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
    }
}

using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// The app's strings (Localization/Strings*.resx, Loc.cs): the three
/// languages carry the same keys and placeholders, every key the code and
/// XAML ask for exists, and every formatted string formats. The Windows
/// counterpart of the Mac's Scripts/check-localization.py.
public partial class LocalizationTests
{
    private static readonly string[] Languages = ["", ".es", ".de"];

    private static string AppDirectory([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "FTX1RemoteWindows"));

    private static Dictionary<string, string> Read(string language) =>
        XDocument.Load(Path.Combine(AppDirectory(), "Localization", $"Strings{language}.resx"))
            .Root!.Elements("data")
            .ToDictionary(d => (string)d.Attribute("name")!, d => (string)d.Element("value")!);

    /// {0}, {1:0.000}, and literal {CALL}-style tokens, as a sorted set.
    private static string Placeholders(string value) =>
        string.Join(" ", PlaceholderPattern().Matches(value.Replace("{{", "").Replace("}}", ""))
            .Select(m => Regex.Replace(m.Value, @"^\{(\d+).*\}$", "{$1}")).Order(StringComparer.Ordinal));

    [Fact]
    public void LanguagesHaveTheSameKeysAndPlaceholders()
    {
        var english = Read("");
        foreach (var language in Languages.Skip(1))
        {
            var translated = Read(language);
            Assert.Empty(english.Keys.Except(translated.Keys));
            Assert.Empty(translated.Keys.Except(english.Keys));
            foreach (var (key, value) in english)
            {
                Assert.True(Placeholders(value) == Placeholders(translated[key]),
                    $"{key} in Strings{language}.resx: \"{translated[key]}\" doesn't have the placeholders of \"{value}\"");
            }
        }
    }

    [Fact]
    public void EveryKeyInTheAppExists()
    {
        var keys = Read("").Keys.ToHashSet();
        var missing = new List<string>();
        foreach (var file in Directory.EnumerateFiles(AppDirectory(), "*.*", SearchOption.AllDirectories)
                     .Where(f => (f.EndsWith(".cs") || f.EndsWith(".xaml"))
                         && !f.Contains($"{Path.DirectorySeparatorChar}Localization{Path.DirectorySeparatorChar}")
                         && !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                         && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")))
        {
            var text = File.ReadAllText(file);
            foreach (Match m in UsePattern().Matches(text))
            {
                var key = m.Groups["key"].Value;
                var wanted = m.Groups["kind"].Value == "P" ? new[] { key + ".one", key + ".other" } : [key];
                missing.AddRange(wanted.Where(k => !keys.Contains(k)).Select(k => $"{Path.GetFileName(file)}: {k}"));
            }
        }
        Assert.Empty(missing);
    }

    [Fact]
    public void FormattedStringsFormat()
    {
        var args = Enumerable.Range(0, 10).Select(i => (object)(i + 0.5)).ToArray();
        foreach (var language in Languages)
        {
            foreach (var (key, value) in Read(language))
            {
                if (!Regex.IsMatch(value, @"\{\d"))
                    continue;
                var ex = Record.Exception(() => string.Format(CultureInfo.InvariantCulture, value, args));
                Assert.True(ex is null, $"{key} in Strings{language}.resx doesn't format: {ex?.Message}");
            }
        }
    }

    [Fact]
    public void LooksUpEnglish()
    {
        var saved = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.InvariantCulture;
            Assert.Equal("Transmit disabled", Loc.S("transmitGate.transmitDisabled"));
            Assert.Equal("3 recordings", Loc.P("recordingsWindow.recordingCount", 3));
            Assert.Equal("no.such.key", Loc.S("no.such.key"));
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }
    }

    [GeneratedRegex(@"\{\d+[^{}]*\}|\{[A-Z]+\}")]
    private static partial Regex PlaceholderPattern();

    [GeneratedRegex(@"Loc\.(?<kind>[SFP])\(""(?<key>[^""]+)""|\{l:Str Key=(?<key>[^}]+)\}")]
    private static partial Regex UsePattern();
}

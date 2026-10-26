using System.Text.Json;
using FTX1RemoteWindows.Models;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// Settings → Appearance → Theme: the theme model, presets and the
/// 7-segment digit strings (Models/ThemeDefinition.cs).
public class ThemeTests
{
    [Theory]
    [InlineData("#FF8000", 255, 255, 128, 0)]
    [InlineData("#80FFFFFF", 128, 255, 255, 255)]
    [InlineData("1AE4F2FF", 0x1A, 0xE4, 0xF2, 0xFF)]
    public void ParsesColors(string hex, int a, int r, int g, int b) =>
        Assert.Equal(new ThemeColor((byte)a, (byte)r, (byte)g, (byte)b), ThemeColor.Parse(hex));

    [Theory]
    [InlineData("")]
    [InlineData("#FFF")]
    [InlineData("#GG0000")]
    [InlineData(null)]
    public void RejectsBadColors(string? hex) => Assert.False(ThemeColor.TryParse(hex, out _));

    [Fact]
    public void ColorRoundTrips() => Assert.Equal("#FF2D6BD0", ThemeColor.Parse("#2D6BD0").ToString());

    [Fact]
    public void FillSpreadsOffsetsEvenly()
    {
        var stops = new ThemeFill(["#000000", "#808080", "#FFFFFF"]).Stops();
        Assert.Equal([0, 0.5, 1], stops.Select(s => s.Offset));
    }

    [Fact]
    public void FillWithMismatchedOffsetsIsRejected() =>
        Assert.Throws<FormatException>(() => new ThemeFill(["#000000", "#FFFFFF"], [0]).Stops());

    [Fact]
    public void PresetsAreValidAndUniquelyNamed()
    {
        foreach (var theme in ThemePresets.All)
        {
            theme.Validate();
        }
        Assert.Equal(ThemePresets.Names.Count, ThemePresets.Names.Distinct().Count());
        Assert.Equal(ThemePresets.Auto, ThemePresets.Names[0]);
    }

    /// The defaults must be the app as it looked before themes.
    [Fact]
    public void DefaultThemesOverrideNothing()
    {
        foreach (var theme in new[] { ThemePresets.DefaultLight, ThemePresets.DefaultDark })
        {
            Assert.Null(theme.WindowBackground);
            Assert.Null(theme.ButtonBackground);
            Assert.Null(theme.ButtonCheckedBackground);
            Assert.Null(theme.Accent);
            Assert.Null(theme.MenuValueColor);
            Assert.Equal(JsonSerializer.Serialize(new VfoTheme()), JsonSerializer.Serialize(theme.Vfo));
        }
        Assert.Equal(ThemeBase.Light, ThemePresets.DefaultLight.Base);
        Assert.Equal(ThemeBase.Dark, ThemePresets.DefaultDark.Base);
    }

    [Fact]
    public void GlossyBlackIsGlossy()
    {
        var glossy = ThemePresets.GlossyBlack;
        Assert.Equal(ThemeBase.Dark, glossy.Base);
        Assert.True(glossy.ButtonBackground!.IsGradient);
        Assert.True(glossy.WindowBackground!.IsGradient);
        // Lighter than dark mode's black.
        Assert.True(ThemeColor.Parse(glossy.WindowBackground.Colors[^1]).R > 0x10);
        Assert.Equal(VfoDigitFont.SevenSegment, glossy.Vfo.DigitFont);
    }

    [Theory]
    [InlineData("Glossy Black", false, "Glossy Black")]
    [InlineData("Auto", true, "Default Dark")]
    [InlineData("Auto", false, "Default Light")]
    [InlineData("Gone Theme", true, "Default Dark")]
    [InlineData(null, false, "Default Light")]
    public void ResolvesNames(string? name, bool systemIsDark, string expected) =>
        Assert.Equal(expected, ThemePresets.Resolve(name, systemIsDark).Name);

    [Theory]
    [InlineData(0, "Auto")]
    [InlineData(1, "Default Light")]
    [InlineData(2, "Default Dark")]
    public void MigratesLegacyTheme(int legacy, string expected) => Assert.Equal(expected, ThemePresets.FromLegacy(legacy));

    /// Custom themes (phase 2) will be JSON; enums go by name.
    [Fact]
    public void ThemeJsonRoundTrips()
    {
        var json = JsonSerializer.Serialize(ThemePresets.GlossyBlack);
        Assert.Contains("\"SevenSegment\"", json);
        Assert.Contains("\"Dark\"", json);
        var back = JsonSerializer.Deserialize<ThemeDefinition>(json)!;
        Assert.Equal(JsonSerializer.Serialize(back), json);
    }

    [Theory]
    [InlineData("7.074.000", "!!7.074.000", "888.888.888")]
    [InlineData("14.074.000", "!14.074.000", "888.888.888")]
    [InlineData("144.390.000", "144.390.000", "888.888.888")]
    [InlineData("1296.000.000", "1296.000.000", "8888.888.888")]
    [InlineData("—", "---.---.---", "888.888.888")]
    public void SevenSegmentStrings(string text, string lit, string unlit)
    {
        Assert.Equal(lit, SevenSegmentText.Lit(text));
        Assert.Equal(unlit, SevenSegmentText.Unlit(SevenSegmentText.Lit(text)));
    }
}

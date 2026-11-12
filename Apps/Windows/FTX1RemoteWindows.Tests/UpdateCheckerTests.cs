using System.Text.Json;
using FTX1RemoteWindows.Services;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// Update check against GitHub's releases JSON: the zip and the setup exe both
/// make a Windows release, and the setup exe's URL is offered to installed copies.
public class UpdateCheckerTests
{
    private static JsonElement Releases(string json) => JsonDocument.Parse(json).RootElement;

    private static string Release(string tag, params string[] assets)
    {
        var list = string.Join(",", assets.Select(a =>
            "{\"name\":\"" + a + "\",\"browser_download_url\":\"https://x/dl/" + a + "\"}"));
        return "{\"tag_name\":\"" + tag + "\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://x/" + tag
            + "\",\"body\":\"\",\"assets\":[" + list + "]}";
    }

    [Fact]
    public void SetupOnlyReleaseCountsAndOffersItsUrl()
    {
        var json = $"[{Release("v0.10", "FTX1Remote-Windows-0.10-x64-setup.exe")}]";
        var update = UpdateChecker.Newest(Releases(json), new Version(0, 9));
        Assert.NotNull(update);
        Assert.Equal("https://x/dl/FTX1Remote-Windows-0.10-x64-setup.exe", update.DownloadUrl(true));
        Assert.Equal("https://x/v0.10", update.DownloadUrl(false));
    }

    [Fact]
    public void ZipOnlyReleaseHasNoSetupUrlSoInstalledCopiesGetThePage()
    {
        var json = $"[{Release("v0.10", "FTX1Remote-Windows-0.10-x64.zip")}]";
        var update = UpdateChecker.Newest(Releases(json), new Version(0, 9));
        Assert.NotNull(update);
        Assert.Equal("https://x/v0.10", update.DownloadUrl(true));
    }

    [Fact]
    public void MacOnlyOrOlderReleasesAreIgnored()
    {
        var json = $"[{Release("v0.11", "FTX1Remote-0.11.zip")},{Release("v0.9", "FTX1Remote-Windows-0.9-x64.zip")}]";
        Assert.Null(UpdateChecker.Newest(Releases(json), new Version(0, 9)));
    }
}

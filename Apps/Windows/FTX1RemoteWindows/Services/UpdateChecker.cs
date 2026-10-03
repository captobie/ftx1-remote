using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;

namespace FTX1RemoteWindows.Services;

/// A Windows release newer than the running build.
public sealed record UpdateInfo(Version Version, string Tag, string Name, string Notes, string PageUrl);

/// "Check for updates" (Settings → About). Notify-only: asks GitHub Releases
/// for the newest Windows release and, if it's newer than this build, hands
/// back its page so the user can download it — no self-install (the app is
/// unpackaged; see the .csproj).
///
/// Windows releases share the repo (captobie/ftx1-remote) with the Mac's, so
/// they're told apart by tag: "windows-v0.8". The version number itself
/// follows the Mac's. Drafts and pre-releases are ignored. The unauthenticated
/// API allows 60 requests an hour per IP, far more than a launch check plus
/// the odd button press.
public static class UpdateChecker
{
    public const string TagPrefix = "windows-v";
    public const string ReleasesPageUrl = "https://github.com/captobie/ftx1-remote/releases";
    private const string ApiUrl = "https://api.github.com/repos/captobie/ftx1-remote/releases?per_page=50";

    private static readonly HttpClient Http = CreateClient();

    /// The running build's version: the .csproj's &lt;Version&gt;, e.g. 0.8.
    public static Version CurrentVersion
    {
        get
        {
            var informational = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            // The SDK appends "+<commit hash>" to the informational version.
            var text = informational?.Split('+')[0];
            return text is not null && Version.TryParse(text, out var v) ? v : new Version(0, 0);
        }
    }

    /// "0.8" — what the About tab shows.
    public static string CurrentVersionText => Display(CurrentVersion);

    public static string Display(Version v) => v.Build > 0 ? v.ToString(3) : v.ToString(2);

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"FTX1RemoteWindows/{CurrentVersionText}");
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    /// The newest Windows release if it's newer than this build, else null
    /// (up to date, or no Windows release published yet). Throws on a
    /// network or parse failure; callers decide whether that's worth showing.
    public static async Task<UpdateInfo?> CheckAsync(CancellationToken cancellationToken = default)
    {
        using var response = await Http.GetAsync(ApiUrl, cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);

        UpdateInfo? newest = null;
        foreach (var release in doc.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean())
            {
                continue;
            }
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith(TagPrefix, StringComparison.OrdinalIgnoreCase)
                || !Version.TryParse(tag[TagPrefix.Length..], out var version))
            {
                continue;
            }
            if (newest is null || version > newest.Version)
            {
                var name = release.TryGetProperty("name", out var n) ? n.GetString() : null;
                var body = release.TryGetProperty("body", out var b) ? b.GetString() : null;
                newest = new UpdateInfo(version, tag, string.IsNullOrWhiteSpace(name) ? tag : name,
                    body?.Trim() ?? "", release.GetProperty("html_url").GetString() ?? ReleasesPageUrl);
            }
        }
        return newest is not null && newest.Version > CurrentVersion ? newest : null;
    }
}

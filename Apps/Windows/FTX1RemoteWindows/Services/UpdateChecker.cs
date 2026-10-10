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
/// From 0.9 on, one release ("v0.9") carries both apps: the Mac's zip and
/// deltas, plus the Windows zip uploaded from the PC. So a release counts as
/// a Windows release only if it has a Windows zip attached (the Mac half goes
/// up first, and a Windows user mustn't be sent to a page with nothing to
/// download). 0.8 was a Windows-only release tagged "windows-v0.8"; that tag
/// form still counts. The notes shown are only the sections whose "## "
/// heading names Windows, when there are any. Drafts and pre-releases are
/// ignored. The unauthenticated API allows 60 requests an hour per IP, far
/// more than a launch check plus the odd button press.
public static class UpdateChecker
{
    /// Tag prefixes, longest first: "windows-v0.8" (0.8 only) and "v0.9".
    private static readonly string[] TagPrefixes = ["windows-v", "v"];
    private const string AssetPrefix = "FTX1Remote-Windows-";
    private const string AssetSuffix = "-x64.zip";
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
            if (ParseTag(tag) is not { } version || !HasWindowsZip(release))
            {
                continue;
            }
            if (newest is null || version > newest.Version)
            {
                var name = release.TryGetProperty("name", out var n) ? n.GetString() : null;
                var body = release.TryGetProperty("body", out var b) ? b.GetString() : null;
                newest = new UpdateInfo(version, tag, string.IsNullOrWhiteSpace(name) ? tag : name,
                    WindowsNotes(body ?? ""), release.GetProperty("html_url").GetString() ?? ReleasesPageUrl);
            }
        }
        return newest is not null && newest.Version > CurrentVersion ? newest : null;
    }

    private static Version? ParseTag(string tag)
    {
        foreach (var prefix in TagPrefixes)
        {
            if (tag.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return Version.TryParse(tag[prefix.Length..], out var version) ? version : null;
            }
        }
        return null;
    }

    private static bool HasWindowsZip(JsonElement release)
    {
        if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array)
        {
            return false;
        }
        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
            if (name.StartsWith(AssetPrefix, StringComparison.OrdinalIgnoreCase)
                && name.EndsWith(AssetSuffix, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    /// The "## " sections of a combined release's notes whose heading names
    /// Windows ("## Mac and Windows", "## Windows"), each up to the next "## "
    /// heading, or the whole body if there are none.
    private static string WindowsNotes(string body)
    {
        var lines = body.Replace("\r\n", "\n").Split('\n');
        var kept = new List<string>();
        var keeping = false;
        var found = false;
        foreach (var line in lines)
        {
            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                keeping = line.Contains("Windows", StringComparison.OrdinalIgnoreCase);
                found |= keeping;
            }
            if (keeping)
            {
                kept.Add(line);
            }
        }
        return (found ? string.Join('\n', kept) : body).Trim();
    }
}

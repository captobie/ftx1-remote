using System.Net;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows.Services;

/// The public KiwiSDR directory behind the WebSDR window's Stations window
/// — the Mac's KiwiSDRDirectory.
///
/// **Source: `rx.linkfanel.net/kiwisdr_com.js`**, the community mirror of
/// kiwisdr.com/public that feeds the well-known "dyatlov" receiver map.
/// The official kiwisdr.com/public list is deliberately gated
/// (click-to-show plus an `x-kiwi-auth` header), so the app doesn't
/// imitate it. The mirror is a JS file (`var kiwisdr_com = [ … ];`) whose
/// array is JSON apart from a trailing comma; it's ~900 KB.
///
/// **Etiquette**: fetched only when the Stations window opens (and only if
/// the disk cache is older than StaleAfter) or on an explicit Refresh —
/// never polled in the background. Conditional GET (`If-None-Match`), and
/// a User-Agent naming the app. The raw file is cached in
/// %LOCALAPPDATA%\FTX1RemoteWindows, so the list shows instantly and
/// survives the mirror being down.
///
/// Used on the UI thread only; parsing runs on the thread pool.
public sealed class KiwiSdrDirectory
{
    public enum LoadState
    {
        Idle,
        Loading,
        Failed,
    }

    public static readonly Uri SourceUrl = new("http://rx.linkfanel.net/kiwisdr_com.js");
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(30);

    private static readonly HttpClient Http = CreateClient();

    public IReadOnlyList<KiwiSdrStation> Stations { get; private set; } = [];
    public LoadState State { get; private set; } = LoadState.Idle;
    public string? FailureMessage { get; private set; }
    /// When the list on screen was last fetched from the mirror (or the
    /// cache file's date, when shown from cache).
    public DateTime? FetchedAt { get; private set; }

    /// Any of the above changed.
    public event Action? Changed;

    private static string CachePath
    {
        get
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FTX1RemoteWindows");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "kiwisdr_com.js");
        }
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0";
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"FTX1RemoteWindows/{version}");
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("(KiwiSDR station directory)"));
        return client;
    }

    /// Called when the Stations window opens: shows the cached list
    /// immediately, then fetches only if it's stale (or there's no cache).
    public void LoadIfNeeded()
    {
        if (Stations.Count == 0 && CacheModificationDate() is { } cacheDate)
        {
            // Cache parse is async, so decide freshness from the file date
            // now; a fresh cache that fails to parse falls back to a fetch.
            var fresh = DateTime.Now - cacheDate < StaleAfter;
            _ = LoadFromCacheAsync(cacheDate, fetchIfUnusable: fresh);
            if (fresh)
            {
                return;
            }
        }
        else if (FetchedAt is { } fetchedAt && DateTime.Now - fetchedAt < StaleAfter)
        {
            return;
        }
        Refresh();
    }

    public void Refresh()
    {
        if (State == LoadState.Loading)
        {
            return;
        }
        State = LoadState.Loading;
        Changed?.Invoke();
        _ = FetchAsync();
    }

    private static DateTime? CacheModificationDate()
    {
        try
        {
            return File.Exists(CachePath) ? File.GetLastWriteTime(CachePath) : null;
        }
        catch
        {
            return null;
        }
    }

    private async Task LoadFromCacheAsync(DateTime date, bool fetchIfUnusable)
    {
        List<KiwiSdrStation>? parsed = null;
        try
        {
            var bytes = await File.ReadAllBytesAsync(CachePath);
            parsed = await Task.Run(() => Parse(bytes));
        }
        catch
        {
            // Unreadable cache: treated like an unusable one below.
        }
        // A network result may have landed first; don't overwrite it.
        if (Stations.Count > 0)
        {
            return;
        }
        if (parsed is { Count: > 0 })
        {
            Stations = parsed;
            FetchedAt = date;
            Changed?.Invoke();
        }
        else if (fetchIfUnusable)
        {
            Refresh();
        }
    }

    private async Task FetchAsync()
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, SourceUrl);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
            if (File.Exists(CachePath) && Stations.Count > 0 && AppSettings.WebSdrDirectoryETag is { Length: > 0 } etag
                && EntityTagHeaderValue.TryParse(etag, out var tag))
            {
                request.Headers.IfNoneMatch.Add(tag);
            }
            using var response = await Http.SendAsync(request);
            if (response.StatusCode == HttpStatusCode.NotModified)
            {
                File.SetLastWriteTime(CachePath, DateTime.Now);
                FetchedAt = DateTime.Now;
                State = LoadState.Idle;
                FailureMessage = null;
                Changed?.Invoke();
                return;
            }
            if (response.StatusCode != HttpStatusCode.OK)
            {
                throw new HttpRequestException($"HTTP {(int)response.StatusCode}");
            }
            var bytes = await response.Content.ReadAsByteArrayAsync();
            var parsed = await Task.Run(() => Parse(bytes));
            if (parsed is not { Count: > 0 })
            {
                throw new InvalidDataException("The station list couldn't be read.");
            }
            try
            {
                await File.WriteAllBytesAsync(CachePath, bytes);
            }
            catch
            {
                // Only the cache is lost.
            }
            AppSettings.WebSdrDirectoryETag = response.Headers.ETag?.ToString();
            Stations = parsed;
            FetchedAt = DateTime.Now;
            State = LoadState.Idle;
            FailureMessage = null;
            AppLog.Write($"kiwisdr-directory: fetched {parsed.Count} stations ({bytes.Length} bytes)");
        }
        catch (Exception ex)
        {
            AppLog.Write($"kiwisdr-directory: fetch failed: {ex.Message}");
            State = LoadState.Failed;
            FailureMessage = Stations.Count == 0
                ? $"Couldn't load the station list: {ex.Message}"
                : $"Couldn't refresh — showing the cached list. ({ex.Message})";
        }
        Changed?.Invoke();
    }

    /// `var kiwisdr_com = [ {…}, {…}, ];` → stations. Strips everything
    /// outside the outer array; the trailing comma JSON doesn't allow is
    /// taken care of by AllowTrailingCommas.
    public static List<KiwiSdrStation>? Parse(byte[] data)
    {
        var text = System.Text.Encoding.UTF8.GetString(data);
        var start = text.IndexOf('[');
        var end = text.LastIndexOf(']');
        if (start < 0 || end <= start)
        {
            return null;
        }
        try
        {
            using var doc = JsonDocument.Parse(text[start..(end + 1)], new JsonDocumentOptions { AllowTrailingCommas = true });
            var stations = new List<KiwiSdrStation>();
            foreach (var element in doc.RootElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }
                var entry = new Dictionary<string, string>();
                foreach (var property in element.EnumerateObject())
                {
                    if (property.Value.ValueKind == JsonValueKind.String)
                    {
                        entry[property.Name] = property.Value.GetString()!;
                    }
                }
                if (KiwiSdrStation.FromEntry(entry) is { } station)
                {
                    stations.Add(station);
                }
            }
            return stations;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

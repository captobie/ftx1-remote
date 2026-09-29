using System.Text.RegularExpressions;

namespace FTX1RemoteWindows.Services;

/// Port of Apps/Mac/FTX1RemoteMac/WPSDCallsignMonitor.swift: polls a WPSD
/// (Pi-Star-family hotspot dashboard) for the callsign of whoever is
/// transmitting through it right now and the YSF reflector it's linked to,
/// on the assumption the hotspot is relaying that C4FM traffic to the rig
/// over local RF. No CAT or rigctld involved — it scrapes the same
/// undocumented, unauthenticated HTML fragments WPSD's own dashboard polls.
///
/// Updates are raised on a thread-pool thread; the caller marshals them to
/// the UI. A failed or timed-out fetch raises nothing, so the displayed
/// callsign stays put instead of flickering (the hotspot's PHP backend
/// times out on a fair share of requests under sustained polling — see the
/// Mac's doc comment for the measurements).
public sealed class WpsdCallsignMonitor
{
    /// The Mac's defaults (Settings → Polling there). Slower than the
    /// dashboard's own ~1 s cadence: the hotspot (a Pi Zero 2 W) spends
    /// ~0.7-3.3 s of PHP per request. Not user-adjustable here until the
    /// Settings UI (parity plan step 7).
    private static readonly TimeSpan CallerInterval = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan ReflectorInterval = TimeSpan.FromSeconds(30);

    /// Null = a successful fetch found no live caller.
    public event Action<string?>? CallsignUpdated;
    /// Null = not linked (or no YSF section).
    public event Action<string?>? ReflectorUpdated;

    // The hotspot routinely takes 4-5 s to answer, so the Mac's 10 s
    // timeout. Each loop awaits its own request, so a slow one can't pile
    // up overlapping requests.
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private CancellationTokenSource? _cts;
    private string? _currentHost;

    /// No-op if already running against this exact host.
    public void Start(string host)
    {
        if (host == _currentHost)
        {
            return;
        }
        Stop();
        _currentHost = host;
        AppLog.Write($"wpsd: polling {host}");
        var cts = new CancellationTokenSource();
        _cts = cts;
        _ = RunLoopAsync(() => PollCallerAsync(host, cts.Token), CallerInterval, cts.Token);
        _ = RunLoopAsync(() => PollReflectorAsync(host, cts.Token), ReflectorInterval, cts.Token);
    }

    public void Stop()
    {
        if (_cts is null)
        {
            return;
        }
        AppLog.Write($"wpsd: stopped polling {_currentHost}");
        _cts.Cancel();
        _cts.Dispose();
        _cts = null;
        _currentHost = null;
    }

    private static async Task RunLoopAsync(Func<Task> poll, TimeSpan interval, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            await poll().ConfigureAwait(false);
            try
            {
                await Task.Delay(interval, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async Task PollCallerAsync(string host, CancellationToken token)
    {
        if (await FetchAsync($"http://{host}/mmdvmhost/caller_details_table.php", token).ConfigureAwait(false) is { } html
            && !token.IsCancellationRequested)
        {
            CallsignUpdated?.Invoke(LiveCallsign(html));
        }
    }

    private async Task PollReflectorAsync(string host, CancellationToken token)
    {
        if (await FetchAsync($"http://{host}/mmdvmhost/repeaterinfo.php", token).ConfigureAwait(false) is { } html
            && !token.IsCancellationRequested)
        {
            ReflectorUpdated?.Invoke(LinkedReflector(html));
        }
    }

    /// The page body on a 200, null on anything else (logged at most once
    /// per host until a fetch succeeds again, so an unreachable hotspot
    /// doesn't write a line every 3 s).
    private bool _loggedFailure;

    private async Task<string?> FetchAsync(string url, CancellationToken token)
    {
        try
        {
            using var response = await _http.GetAsync(url, token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                LogFailure($"{url} answered {(int)response.StatusCode}");
                return null;
            }
            _loggedFailure = false;
            return await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or UriFormatException or InvalidOperationException)
        {
            if (!token.IsCancellationRequested)
            {
                LogFailure($"{url} failed: {ex.Message}");
            }
            return null;
        }
    }

    private void LogFailure(string message)
    {
        if (!_loggedFailure)
        {
            _loggedFailure = true;
            AppLog.Write($"wpsd: {message}");
        }
    }

    private static readonly Regex TagPattern = new("<[^>]+>");
    private static readonly Regex QrzCallsignPattern = new("qrz\\.com/db/([A-Za-z0-9]+)\"");
    private static readonly Regex PillValuePattern = new("class=['\"]pill-value['\"]>([^<]*)<");

    /// WPSD's "Current / Last Caller Details" table always shows the *last*
    /// caller, so the row must also read Src "Net" (relayed from the network
    /// to the radio, not the rig's own RF keying up) and have the live "TX
    /// nn sec" cell (a finished call shows elapsed seconds instead). With
    /// the tags stripped both conditions flatten to "Net TX" — WPSD's markup
    /// doesn't reliably close the cells between them, so this doesn't parse
    /// the table. Same logic as the Mac's liveCallsign(inCallerDetailsHTML:).
    public static string? LiveCallsign(string html)
    {
        var flattened = TagPattern.Replace(html, " ");
        if (!flattened.Contains("Net TX", StringComparison.Ordinal))
        {
            return null;
        }
        var match = QrzCallsignPattern.Match(html);
        return match.Success ? match.Groups[1].Value : null;
    }

    /// The first "pill-value" in repeaterinfo.php's "YSF Status" sidebar
    /// section (the Link pill, e.g. "US-KCWide"), up to the next section
    /// title. "Not Linked" (how WPSD renders the other modes' unlinked
    /// pills) or an empty value reads as none. Same logic as the Mac's
    /// linkedReflector(inRepeaterInfoHTML:).
    public static string? LinkedReflector(string html)
    {
        var start = html.IndexOf("YSF Status", StringComparison.Ordinal);
        if (start < 0)
        {
            return null;
        }
        var section = html[(start + "YSF Status".Length)..];
        var next = section.IndexOf("sidebar-section-title", StringComparison.Ordinal);
        if (next >= 0)
        {
            section = section[..next];
        }
        var match = PillValuePattern.Match(section);
        if (!match.Success)
        {
            return null;
        }
        var value = match.Groups[1].Value.Trim();
        return value.Length == 0 || value.Equals("Not Linked", StringComparison.OrdinalIgnoreCase) ? null : value;
    }
}

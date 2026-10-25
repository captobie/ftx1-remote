using System.Globalization;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// A tune request from Wavelog's web pages (DX cluster, bandmap, DX
/// waterfall) — the Mac's WavelogTuneRequest
/// (Sources/FTX1Core/Logbook/WavelogTuneRequest.swift): the browser
/// fetches GET &lt;cat_url&gt;/&lt;frequency Hz&gt;/&lt;mode&gt; from the radio's
/// cat_url, http://127.0.0.1:54321 unless set in Wavelog's radio settings
/// — the port WaveLogGate listens on. From 3.2.3's assets/js/cat.js
/// (performRadioTuning): the mode is one of lsb, usb, cw, fm, am, rtty,
/// pkt, dig, pktlsb, pktusb, pktfm, lowercase; the request is a plain
/// cross-origin fetch, so the reply needs CORS headers or the page reports
/// a failure even though the rig tuned. Wavelog sends "rtty" for most
/// digital spots (FT8 included) and "fm" for digital voice.
public sealed record WavelogTuneRequest(long FrequencyHz, RigMode? Mode)
{
    /// An HTTP request's head, as far as the listener cares. Header names
    /// lowercased.
    public sealed record HttpHead(string Method, string Path, IReadOnlyDictionary<string, string> Headers);

    /// Parses everything up to the blank line; null if it isn't HTTP.
    public static HttpHead? ParseHead(string text)
    {
        var lines = text.Split("\r\n");
        var requestLine = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (requestLine.Length < 3 || !requestLine[2].StartsWith("HTTP/", StringComparison.Ordinal))
        {
            return null;
        }
        var headers = new Dictionary<string, string>();
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon < 0)
            {
                continue;
            }
            headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        return new HttpHead(requestLine[0], requestLine[1], headers);
    }

    /// /&lt;Hz&gt;/&lt;mode&gt; (or /&lt;Hz&gt;); null for any other path. Frequencies
    /// outside 30 kHz–470 MHz (the FTX-1's coverage, generously) are
    /// refused here rather than sent to the rig.
    public static WavelogTuneRequest? FromPath(string path)
    {
        var pathOnly = path.Split('?', 2)[0];
        var parts = pathOnly.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length is < 1 or > 2
            || !double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var hz)
            || !double.IsFinite(hz)
            || hz is < 30_000 or > 470_000_000)
        {
            return null;
        }
        return new WavelogTuneRequest((long)Math.Round(hz, MidpointRounding.AwayFromZero),
            parts.Length == 2 ? RigModeForCatMode(parts[1]) : null);
    }

    /// Wavelog's CAT mode names → the FTX-1's. There's no DATA-L, so
    /// pktlsb is DATA-U too.
    public static RigMode? RigModeForCatMode(string mode) => mode.ToLowerInvariant() switch
    {
        "lsb" => RigMode.Lsb,
        "usb" => RigMode.Usb,
        "cw" => RigMode.Cw,
        "fm" => RigMode.Fm,
        "am" => RigMode.Am,
        "rtty" => RigMode.Rtty,
        "pkt" or "dig" or "pktusb" or "pktlsb" => RigMode.DataUsb,
        "pktfm" => RigMode.DataFm,
        _ => null,
    };

    /// scheme://host[:port] of a Wavelog URL as Settings holds it (no
    /// scheme means https, as in Wavelog.ApiUrl), lowercased — compared
    /// against a request's Origin header. Null if it isn't a URL.
    public static string? OriginOfWavelogUrl(string baseUrl)
    {
        var text = baseUrl.Trim();
        if (text.Length == 0)
        {
            return null;
        }
        if (!text.Contains("://", StringComparison.Ordinal))
        {
            text = "https://" + text;
        }
        if (!Uri.TryCreate(text, UriKind.Absolute, out var url)
            || url.Scheme is not ("http" or "https")
            || url.Host.Length == 0)
        {
            return null;
        }
        var host = url.Host.ToLowerInvariant();
        return url.IsDefaultPort ? $"{url.Scheme}://{host}" : $"{url.Scheme}://{host}:{url.Port}";
    }
}

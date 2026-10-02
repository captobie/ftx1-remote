using System.Globalization;

namespace FTX1RemoteWindows.Models;

/// One receive range of a KiwiSDR or WebSDR, in Hz — Swift's
/// ClosedRange<Int> in the Mac's WebSDR files.
public readonly record struct FrequencyRange(long Low, long High)
{
    public bool Contains(long hz) => hz >= Low && hz <= High;

    /// "0–30 MHz", "1.8–30 MHz", or "10 kHz–30 MHz" for a nonzero lower
    /// bound below 1 MHz (which "0.0–30 MHz" would misrepresent) — the
    /// Mac's KiwiSDRStation.describe.
    public string Describe()
    {
        static string Mhz(long hz)
        {
            var v = hz / 1_000_000.0;
            return v == Math.Round(v)
                ? ((long)v).ToString(CultureInfo.InvariantCulture)
                : v.ToString("0.0", CultureInfo.InvariantCulture);
        }
        if (Low > 0 && Low < 1_000_000)
        {
            return $"{Low / 1000} kHz–{Mhz(High)} MHz";
        }
        return $"{Mhz(Low)}–{Mhz(High)} MHz";
    }

    public static string Describe(IEnumerable<FrequencyRange> ranges) =>
        string.Join(", ", ranges.Select(r => r.Describe()));

    /// "0-30000000" or "lo-hi,lo-hi" (the KiwiSDR directory listing's own
    /// format, also how favorites store their ranges). Empty when nothing
    /// parses; KiwiSdrStation falls back to 0–30 MHz itself.
    public static List<FrequencyRange> Parse(string raw)
    {
        var ranges = new List<FrequencyRange>();
        foreach (var part in raw.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var ends = part.Split('-');
            if (ends.Length == 2
                && long.TryParse(ends[0].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var lo)
                && long.TryParse(ends[1].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var hi)
                && lo <= hi)
            {
                ranges.Add(new FrequencyRange(lo, hi));
            }
        }
        return ranges;
    }

    public static string Encode(IEnumerable<FrequencyRange> ranges) =>
        string.Join(",", ranges.Select(r => $"{r.Low}-{r.High}"));
}

/// Which receiver software a WebSDR-window host runs — the Mac's
/// SDRPlatform: a KiwiSDR, a classic WebSDR (PA3FWM's software, the servers
/// listed on websdr.org), or an OpenWebRX (in practice the operator's own,
/// e.g. an RTL-SDR on a Pi). They differ in how they're tuned (a Kiwi by
/// `?f=` + page reload, the other two in place through the page's own
/// functions), in their mode names, and in the page functions
/// SdrPageBridge calls.
///
/// Stored per station (WebSdrFavorite.Platform). A host typed by hand has
/// no platform until its page has loaded once — it's loaded as a Kiwi
/// (`?f=`, which a WebSDR ignores), and SdrPageBridge.DetectPlatformAsync
/// then records what it actually is.
public enum SdrPlatform
{
    KiwiSdr,
    WebSdr,
    OpenWebRx,
}

/// What a retune comes to: a URL to load, or why not — the Mac's
/// KiwiSDRURLBuilder.Result.
public abstract record SdrRetune
{
    public sealed record Tune(string Url, long FrequencyHz, string? ModeToken) : SdrRetune;
    public sealed record NoHost : SdrRetune;
    public sealed record InvalidHost : SdrRetune;
    public sealed record NoFrequency : SdrRetune;
    public sealed record OutOfRange(long FrequencyHz, IReadOnlyList<FrequencyRange> Bands) : SdrRetune;
}

public static class SdrPlatformExtensions
{
    public static string DisplayName(this SdrPlatform platform) => platform switch
    {
        SdrPlatform.KiwiSdr => "KiwiSDR",
        SdrPlatform.WebSdr => "WebSDR",
        _ => "OpenWebRX",
    };

    /// Loaded once per connection and then retuned through the page's own
    /// functions (SdrPageBridge.RetuneInPlaceAsync); a Kiwi reloads instead.
    public static bool RetunesInPlace(this SdrPlatform platform) => platform != SdrPlatform.KiwiSdr;

    /// The page's mode token for a rig mode, or null to tune frequency only.
    /// A null rig mode (C4FM, or not read yet) is frequency only too.
    public static string? ModeToken(this SdrPlatform platform, RigMode? mode) => platform switch
    {
        SdrPlatform.KiwiSdr => KiwiSdrUrlBuilder.ModeToken(mode),
        SdrPlatform.WebSdr => WebSdrUrlBuilder.ModeToken(mode),
        _ => OpenWebRxUrlBuilder.ModeToken(mode),
    };

    /// A mode as the page reports it, folded to the token ModeToken would
    /// send for it; null when the rig has no equivalent.
    public static string? ModeFamily(this SdrPlatform platform, string pageMode) => platform switch
    {
        SdrPlatform.KiwiSdr => KiwiSdrUrlBuilder.ModeFamily(pageMode),
        SdrPlatform.WebSdr => WebSdrUrlBuilder.ModeFamily(pageMode),
        _ => OpenWebRxUrlBuilder.ModeFamily(pageMode),
    };

    /// The rig mode for a page mode, for click-to-tune, or null to leave the
    /// rig's mode alone: when the page mode has no rig equivalent, when it's
    /// already what the rig's mode maps to (so DATA-U stays DATA-U under a
    /// page in USB), and when the rig's mode has no page equivalent (RTTY,
    /// DATA-FM, C4FM — following never set the page's mode from those, so
    /// its mode isn't a statement about what the rig should be in).
    public static RigMode? RigModeForPageMode(this SdrPlatform platform, string pageMode, RigMode? current)
    {
        if (platform.ModeFamily(pageMode) is not { } family
            || platform.ModeToken(current) is not { } currentToken
            || family == currentToken)
        {
            return null;
        }
        foreach (var mode in new[] { RigMode.Usb, RigMode.Lsb, RigMode.Cw, RigMode.Am, RigMode.Fm })
        {
            if (platform.ModeToken(mode) == family)
            {
                return mode;
            }
        }
        return null;
    }

    /// `bands`: the station's receive ranges, or null when unknown (a WebSDR
    /// or OpenWebRX not loaded yet), which skips the range check.
    public static SdrRetune Retune(this SdrPlatform platform, string hostPort, long frequencyHz, RigMode? mode,
                                   IReadOnlyList<FrequencyRange>? bands) => platform switch
    {
        SdrPlatform.KiwiSdr => KiwiSdrUrlBuilder.Retune(hostPort, frequencyHz, mode, bands ?? KiwiSdrUrlBuilder.DefaultBands),
        SdrPlatform.WebSdr => WebSdrUrlBuilder.Retune(hostPort, frequencyHz, mode, bands),
        _ => OpenWebRxUrlBuilder.Retune(hostPort, frequencyHz, mode, bands),
    };
}

/// Pure URL logic for a KiwiSDR — the Mac's KiwiSDRURLBuilder (see there
/// for how it was verified against a live Kiwi's own `kiwisdr.min.js`):
/// `/?f=<kHz><mode>`, the same shape the Kiwi's own "copy frequency link"
/// icon builds. Omitting the mode token makes the Kiwi fall back to its
/// stored `last_mode`, which is how an unmapped rig mode leaves the Kiwi's
/// mode unchanged. Zoom is deliberately never sent, so a zoom set by hand
/// in the Kiwi page survives retunes.
public static class KiwiSdrUrlBuilder
{
    /// KiwiSDR's standard receive range — the fallback for a host typed in
    /// by hand. A station picked from the directory brings its own ranges,
    /// which can be wider (0–32 MHz) or entirely elsewhere (converter-fed
    /// Kiwis).
    public const long MaxFrequencyHz = 30_000_000;
    public static readonly IReadOnlyList<FrequencyRange> DefaultBands = [new FrequencyRange(0, MaxFrequencyHz)];

    /// The KiwiSDR mode token for a rig mode, or null to retune frequency
    /// only. Tokens are from the Kiwi's own `kiwi.modes_lc` list.
    public static string? ModeToken(RigMode? mode) => mode switch
    {
        RigMode.Usb => "usb",
        // DATA-U is plain USB demodulation on the rig, so USB on the Kiwi
        // makes FT8 etc. audible there too.
        RigMode.DataUsb => "usb",
        RigMode.Lsb => "lsb",
        RigMode.Cw => "cw",
        RigMode.Am => "am",
        RigMode.Fm => "nbfm",
        // No sensible Kiwi equivalent (RTTY's mark/space sideband is
        // ambiguous; DATA-FM/C4FM are digital) — frequency only.
        _ => null,
    };

    /// The Kiwi mode as the token ModeToken would send for it — folding the
    /// Kiwi's variants (narrow/wide/synchronous AM, narrow sideband, narrow
    /// FM) into the family the rig can match. null for modes with no rig
    /// equivalent (IQ, DRM).
    public static string? ModeFamily(string kiwiMode) => kiwiMode.ToLowerInvariant() switch
    {
        "usb" or "usn" => "usb",
        "lsb" or "lsn" => "lsb",
        "cw" or "cwn" => "cw",
        "am" or "amn" or "amw" or "sam" or "sau" or "sal" or "sas" or "qam" => "am",
        "nbfm" or "nnfm" => "nbfm",
        _ => null,
    };

    /// Normalizes what the user typed ("host:port", "http://host:port/",
    /// with or without a trailing path) to the receiver's root URL, ending
    /// in "/". Defaults to http — Kiwis and WebSDRs serve plain http.
    public static string? BaseUrl(string hostPort)
    {
        var trimmed = hostPort.Trim();
        if (trimmed.Length == 0)
        {
            return null;
        }
        var withScheme = trimmed.Contains("://", StringComparison.Ordinal) ? trimmed : "http://" + trimmed;
        if (!Uri.TryCreate(withScheme, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
            || string.IsNullOrEmpty(uri.Host))
        {
            return null;
        }
        return new UriBuilder(uri.Scheme, uri.Host, uri.Port, "/").Uri.AbsoluteUri;
    }

    public static SdrRetune Retune(string hostPort, long frequencyHz, RigMode? mode, IReadOnlyList<FrequencyRange> bands)
    {
        if (hostPort.Trim().Length == 0)
        {
            return new SdrRetune.NoHost();
        }
        if (BaseUrl(hostPort) is not { } baseUrl)
        {
            return new SdrRetune.InvalidHost();
        }
        if (frequencyHz <= 0)
        {
            return new SdrRetune.NoFrequency();
        }
        if (!bands.Any(b => b.Contains(frequencyHz)))
        {
            return new SdrRetune.OutOfRange(frequencyHz, bands);
        }
        var token = ModeToken(mode);
        return new SdrRetune.Tune(baseUrl + "?f=" + KHzString(frequencyHz) + (token ?? ""), frequencyHz, token);
    }

    /// Two decimals (10 Hz resolution), matching the Kiwi's own link format.
    public static string KHzString(long hz) => (hz / 1000.0).ToString("F2", CultureInfo.InvariantCulture);
}

/// URL and mode logic for classic WebSDRs (PA3FWM's software) — the Mac's
/// WebSDRURLBuilder. The page reads `?tune=<kHz><mode>` in `bodyonload`
/// and hands it to `setfreqtune()` — the same function its
/// `postMessage("tune …")` interface uses, and the one
/// SdrPageBridge.RetuneInPlaceAsync calls for every later retune (no
/// reload). A frequency outside every band the server has is silently
/// ignored by the page.
public static class WebSdrUrlBuilder
{
    /// The page's `set_mode()` names, lowercased. null = frequency only.
    public static string? ModeToken(RigMode? mode) => mode switch
    {
        RigMode.Usb or RigMode.DataUsb => "usb",
        RigMode.Lsb => "lsb",
        RigMode.Cw => "cw",
        RigMode.Am => "am",
        RigMode.Fm => "fm",
        _ => null,
    };

    /// The page's `mode` global ("USB", "LSB", "CW", "AM", "AMSYNC", "FM")
    /// folded to a ModeToken value.
    public static string? ModeFamily(string webSdrMode) => webSdrMode.ToLowerInvariant() switch
    {
        "usb" or "usbn" => "usb",
        "lsb" or "lsbn" => "lsb",
        "cw" or "cwn" => "cw",
        "am" or "amn" or "amsync" => "am",
        "fm" or "fmn" => "fm",
        _ => null,
    };

    /// What `?tune=` and `setfreqtune()` take: "7074.00usb", or "7074.00".
    public static string TuneValue(long frequencyHz, string? modeToken) =>
        KiwiSdrUrlBuilder.KHzString(frequencyHz) + (modeToken ?? "");

    /// `bands` null (not known until the page has loaded once) skips the
    /// range check — the page just ignores a frequency it doesn't cover.
    public static SdrRetune Retune(string hostPort, long frequencyHz, RigMode? mode, IReadOnlyList<FrequencyRange>? bands)
    {
        if (hostPort.Trim().Length == 0)
        {
            return new SdrRetune.NoHost();
        }
        if (KiwiSdrUrlBuilder.BaseUrl(hostPort) is not { } baseUrl)
        {
            return new SdrRetune.InvalidHost();
        }
        if (frequencyHz <= 0)
        {
            return new SdrRetune.NoFrequency();
        }
        if (bands is not null && !bands.Any(b => b.Contains(frequencyHz)))
        {
            return new SdrRetune.OutOfRange(frequencyHz, bands);
        }
        var token = ModeToken(mode);
        return new SdrRetune.Tune(baseUrl + "?tune=" + TuneValue(frequencyHz, token), frequencyHz, token);
    }
}

/// URL and mode logic for OpenWebRX receivers — the Mac's
/// OpenWebRXURLBuilder (checked against a live v1.2.2 server's own
/// `receiver.js`):
/// - The page reads `#freq=<Hz>,mod=<modulation>` from its URL hash, but
///   only applies it when the frequency is inside the profile the SDR is
///   *currently* on. The profile is shared server-side state, so a first
///   load can land on any profile; WebSdrFollowModel.PageDidLoad therefore
///   always follows up with an in-place retune
///   (SdrPageBridge.RetuneInPlaceAsync), which switches the profile when
///   needed.
/// - Every later retune is in place too, never a reload. The URL built here
///   is the retune's identity (WebSdrFollowModel dedups on it) and a
///   shareable link; the page itself is always loaded without the hash.
/// - Modulation names are the page's `Modes` list ("usb", "lsb", "cw",
///   "am", "nfm", "wfm", plus digital voice and digimodes, which report
///   their underlying modulation).
public static class OpenWebRxUrlBuilder
{
    /// The page's modulation for a rig mode. null = frequency only.
    public static string? ModeToken(RigMode? mode) => mode switch
    {
        RigMode.Usb or RigMode.DataUsb => "usb",
        RigMode.Lsb => "lsb",
        RigMode.Cw => "cw",
        RigMode.Am => "am",
        RigMode.Fm => "nfm",
        // C4FM has an OpenWebRX equivalent ("ysf"), but only with the
        // optional digiham decoder installed; frequency only, like the other
        // platforms, rather than a mode the page may refuse.
        _ => null,
    };

    /// The page's current modulation folded to a ModeToken value; null when
    /// the rig has no equivalent (WFM, digital voice, DRM).
    public static string? ModeFamily(string mode) => mode.ToLowerInvariant() switch
    {
        "usb" => "usb",
        "lsb" => "lsb",
        "cw" => "cw",
        "am" => "am",
        "nfm" => "nfm",
        _ => null,
    };

    /// `bands` null (not known until the page has loaded once) skips the
    /// range check — a retune outside every profile then just doesn't move
    /// the page.
    public static SdrRetune Retune(string hostPort, long frequencyHz, RigMode? mode, IReadOnlyList<FrequencyRange>? bands)
    {
        if (hostPort.Trim().Length == 0)
        {
            return new SdrRetune.NoHost();
        }
        if (KiwiSdrUrlBuilder.BaseUrl(hostPort) is not { } baseUrl)
        {
            return new SdrRetune.InvalidHost();
        }
        if (frequencyHz <= 0)
        {
            return new SdrRetune.NoFrequency();
        }
        if (bands is not null && !bands.Any(b => b.Contains(frequencyHz)))
        {
            return new SdrRetune.OutOfRange(frequencyHz, bands);
        }
        var token = ModeToken(mode);
        return new SdrRetune.Tune(baseUrl + "#freq=" + frequencyHz + (token is null ? "" : ",mod=" + token), frequencyHz, token);
    }
}

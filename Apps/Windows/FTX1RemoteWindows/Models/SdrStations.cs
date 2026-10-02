using System.Globalization;
using System.Text.Json.Serialization;

namespace FTX1RemoteWindows.Models;

/// One public KiwiSDR from the directory (Services/KiwiSdrDirectory.cs) —
/// the Mac's KiwiSDRStation. Built from one entry of
/// `rx.linkfanel.net/kiwisdr_com.js`, where every value is a string.
public sealed class KiwiSdrStation
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Location { get; init; }
    public required Uri Url { get; init; }
    public double? Latitude { get; init; }
    public double? Longitude { get; init; }
    public required string Grid { get; init; }
    public int Users { get; init; }
    public int UsersMax { get; init; }
    /// The listing's first "snr" figure (all-band; the second is HF-only).
    public int? Snr { get; init; }
    public required string Antenna { get; init; }
    /// Receive ranges in *displayed* Hz — they already include the Kiwi's
    /// `freq_offset`, so a converter-fed Kiwi (e.g. airband at 110–142 MHz)
    /// shows its real range, which is also what `?f=` expects.
    public required IReadOnlyList<FrequencyRange> Bands { get; init; }

    public bool IsFull => UsersMax > 0 && Users >= UsersMax;

    /// What goes in the WebSDR window's host field.
    public string HostPort => WebSdrFavorite.HostPortFromUrl(Url.AbsoluteUri);

    public bool Covers(long frequencyHz) => Bands.Any(b => b.Contains(frequencyHz));

    public string BandsDescription => FrequencyRange.Describe(Bands);

    /// null for entries missing a usable URL or marked offline.
    public static KiwiSdrStation? FromEntry(IReadOnlyDictionary<string, string> entry)
    {
        string Get(string key) => entry.TryGetValue(key, out var v) ? v : "";
        if (Get("offline") == "yes"
            || Get("id") is not { Length: > 0 } id
            || !Uri.TryCreate(Get("url"), UriKind.Absolute, out var url)
            || string.IsNullOrEmpty(url.Host))
        {
            return null;
        }

        // "(43.057154, 141.776868)"
        double? lat = null, lon = null;
        var numbers = Get("gps").Trim('(', ')', ' ').Split(',')
            .Select(s => double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : (double?)null)
            .Where(d => d is not null)
            .ToList();
        if (numbers.Count == 2)
        {
            lat = numbers[0];
            lon = numbers[1];
        }

        var bands = FrequencyRange.Parse(Get("bands"));
        return new KiwiSdrStation
        {
            Id = id,
            Url = url,
            Name = Get("name") is { Length: > 0 } name ? name : Get("url"),
            Location = Get("loc"),
            Grid = Get("grid"),
            Users = int.TryParse(Get("users"), out var users) ? users : 0,
            UsersMax = int.TryParse(Get("users_max"), out var max) ? max : 0,
            Snr = int.TryParse(Get("snr").Split(',')[0], out var snr) ? snr : null,
            Antenna = Get("antenna"),
            // Falls back to KiwiSDR's standard 0–30 MHz if the field is
            // missing or unparseable.
            Bands = bands.Count > 0 ? bands : KiwiSdrUrlBuilder.DefaultBands,
            Latitude = lat,
            Longitude = lon,
        };
    }
}

/// One saved WebSDR-window station, KiwiSDR or classic WebSDR — the Mac's
/// WebSDRFavorite. Picking a favorite behaves like picking from the
/// directory (WebSdrFollowModel.Select): it fills the host and, when known,
/// the receive ranges, and never connects. Also how the last pick is
/// remembered (AppSettings.WebSdrPickedStation).
public sealed record WebSdrFavorite
{
    /// The host field's value, e.g. "kiwi.example.org:8073".
    public string HostPort { get; set; } = "";
    /// Shown in the Favorites menu; the station's directory name, or the
    /// host for a typed one. Renamable in Manage Favorites.
    public string Name { get; set; } = "";
    public string Location { get; set; } = "";
    /// "lo-hi,lo-hi" (the directory listing's own format), or null if
    /// unknown. A WebSDR's come from its own page
    /// (SdrPageBridge.ReadBandsAsync) the first time it's connected.
    public string? Bands { get; set; }
    /// null until known: a host typed by hand. Treated as a KiwiSDR until
    /// the page says otherwise.
    public SdrPlatform? Platform { get; set; }

    [JsonIgnore]
    public string Id => Key(HostPort);

    [JsonIgnore]
    public IReadOnlyList<FrequencyRange>? BandRanges
    {
        get
        {
            if (Bands is null)
            {
                return null;
            }
            var parsed = FrequencyRange.Parse(Bands);
            return parsed.Count > 0 ? parsed : KiwiSdrUrlBuilder.DefaultBands;
        }
    }

    public static WebSdrFavorite Create(string hostPort, string name, string location = "",
                                        IEnumerable<FrequencyRange>? bands = null, SdrPlatform? platform = null) =>
        new()
        {
            HostPort = hostPort,
            Name = name,
            Location = location,
            Bands = bands is null ? null : FrequencyRange.Encode(bands),
            Platform = platform,
        };

    public static WebSdrFavorite FromStation(KiwiSdrStation station) =>
        Create(station.HostPort, station.Name, station.Location, station.Bands, SdrPlatform.KiwiSdr);

    /// The host field's form of a station URL: no `http://`, no trailing
    /// slash (https is kept, which KiwiSdrUrlBuilder honors).
    public static string HostPortFromUrl(string url)
    {
        var s = url;
        if (s.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            s = s["http://".Length..];
        }
        return s.TrimEnd('/');
    }

    /// Host comparison key: "Kiwi.Example.org:8073/" and "kiwi.example.org:8073"
    /// are the same station.
    public static string Key(string hostPort)
    {
        var s = hostPort.Trim().ToLowerInvariant();
        if (s.StartsWith("http://", StringComparison.Ordinal))
        {
            s = s["http://".Length..];
        }
        return s.TrimEnd('/');
    }
}

/// Maidenhead locator → coordinates and great-circle distance, for sorting
/// the directory by distance from the operator's grid square (Settings →
/// Station) — the Mac's Maidenhead.
public static class Maidenhead
{
    /// Center of a 4- or 6-character locator, or null if malformed.
    public static (double Latitude, double Longitude)? Coordinates(string locator)
    {
        var c = locator.Trim().ToUpperInvariant();
        if (c.Length < 4 || c[0] is < 'A' or > 'R' || c[1] is < 'A' or > 'R' || !char.IsAsciiDigit(c[2]) || !char.IsAsciiDigit(c[3]))
        {
            return null;
        }
        var lon = (c[0] - 'A') * 20.0 - 180 + (c[2] - '0') * 2;
        var lat = (c[1] - 'A') * 10.0 - 90 + (c[3] - '0');
        if (c.Length >= 6 && c[4] is >= 'A' and <= 'X' && c[5] is >= 'A' and <= 'X')
        {
            lon += (c[4] - 'A') * (2.0 / 24) + (1.0 / 24);
            lat += (c[5] - 'A') * (1.0 / 24) + (0.5 / 24);
        }
        else
        {
            lon += 1;
            lat += 0.5;
        }
        return (lat, lon);
    }

    public static double DistanceKm((double Latitude, double Longitude) a, (double Latitude, double Longitude) b)
    {
        const double r = 6371.0;
        var dLat = (b.Latitude - a.Latitude) * Math.PI / 180;
        var dLon = (b.Longitude - a.Longitude) * Math.PI / 180;
        var h = Math.Sin(dLat / 2) * Math.Sin(dLat / 2)
            + Math.Cos(a.Latitude * Math.PI / 180) * Math.Cos(b.Latitude * Math.PI / 180) * Math.Sin(dLon / 2) * Math.Sin(dLon / 2);
        return 2 * r * Math.Asin(Math.Min(1, Math.Sqrt(h)));
    }
}

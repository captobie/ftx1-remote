namespace FTX1RemoteWindows.Models;

/// The logbook's QSOs indexed by callsign, for "worked before?" while
/// operating — the Mac's WorkedStations (Sources/FTX1Core/Logbook/
/// WorkedStations.swift), same rules: built once from the whole log and
/// asked per callsign, so it can be consulted on every decoded-text render.
///
/// Calls are matched on their base call: the longest '/'-separated part,
/// so K6NA/P, W1/K6NA and K6NA are one station (the rule CwCallsigns uses
/// to judge a call). Bands compare case-insensitively (HRD's log has both
/// "40m" and "40M").
public sealed class WorkedStations
{
    public sealed record Qso(string Call, string Band, string Mode, DateTimeOffset Date);

    public enum Status
    {
        Never,
        /// Worked, but only on other bands than the one asked about.
        OtherBand,
        ThisBand,
    }

    /// Count, the most recent QSO, and every band worked (lowercased).
    public sealed record Summary(int Count, Qso Last, IReadOnlySet<string> Bands);

    private readonly Dictionary<string, List<Qso>> _byCall = new(StringComparer.Ordinal);

    public static readonly WorkedStations Empty = new([]);

    public WorkedStations(IEnumerable<Qso> qsos)
    {
        foreach (var qso in qsos)
        {
            var key = BaseCall(qso.Call);
            if (key.Length == 0)
            {
                continue;
            }
            if (!_byCall.TryGetValue(key, out var list))
            {
                _byCall[key] = list = [];
            }
            list.Add(qso);
        }
    }

    public int StationCount => _byCall.Count;

    public Status StatusOf(string call, string? band)
    {
        if (!_byCall.TryGetValue(BaseCall(call), out var qsos))
        {
            return Status.Never;
        }
        if (string.IsNullOrEmpty(band))
        {
            return Status.OtherBand;
        }
        return qsos.Any(q => string.Equals(q.Band, band, StringComparison.OrdinalIgnoreCase)) ? Status.ThisBand : Status.OtherBand;
    }

    public Summary? SummaryOf(string call)
    {
        if (!_byCall.TryGetValue(BaseCall(call), out var qsos) || qsos.Count == 0)
        {
            return null;
        }
        var last = qsos.MaxBy(q => q.Date)!;
        var bands = qsos.Select(q => q.Band.ToLowerInvariant()).Where(b => b.Length > 0).ToHashSet();
        return new Summary(qsos.Count, last, bands);
    }

    /// Uppercased longest '/' part — the station itself, without a
    /// portable/maritime suffix or a country prefix. On a tie the later
    /// part wins, the usual PREFIX/CALL order (VP2E/K6NA → K6NA).
    public static string BaseCall(string call)
    {
        var best = "";
        foreach (var part in call.ToUpperInvariant().Split('/'))
        {
            var trimmed = part.Trim();
            if (trimmed.Length >= best.Length)
            {
                best = trimmed;
            }
        }
        return best;
    }
}

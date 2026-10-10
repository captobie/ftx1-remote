using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;

namespace FTX1RemoteWindows.Services;

/// "Worked before?" for the CW window — the Mac's WorkedStationsStore: the
/// logbook read once into a WorkedStations index (read-only, off the UI
/// thread), plus the band the rig transmits on, which decides "this band"
/// vs "other band".
///
/// Owned by the CW window and running while it's open: the log's files are
/// checked every few seconds and the index rebuilt when they changed. HRD
/// writes in WAL mode, so the -wal file's date and size count as well as
/// the main file's.
public sealed class WorkedStationsStore : IDisposable
{
    public WorkedStations Worked { get; private set; } = WorkedStations.Empty;
    /// The transmitting side's band ("40m"), null outside the amateur bands
    /// or while the frequency is unknown.
    public string? Band { get; private set; }
    /// Why there's no index, for the Log pane; null when it loaded.
    public string? Problem { get; private set; } = "Not read yet";

    /// The index, band or problem changed — on the UI thread.
    public event Action? Changed;

    private static readonly TimeSpan CheckInterval = TimeSpan.FromSeconds(5);

    private readonly DispatcherQueue _dispatcher;
    private readonly DispatcherQueueTimer _timer;
    /// Path and file stamps of what Worked was built from.
    private string? _loadedStamp;
    private bool _isLoading;
    private bool _disposed;

    public WorkedStationsStore(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        _timer = dispatcher.CreateTimer();
        _timer.Interval = CheckInterval;
        _timer.Tick += (_, _) => ReloadIfChanged();
        _timer.Start();
        ReloadIfChanged();
    }

    public void SetBand(string? band)
    {
        if (band == Band)
        {
            return;
        }
        Band = band;
        Changed?.Invoke();
    }

    /// Re-reads the log now, e.g. right after logging a QSO.
    public void Reload()
    {
        _loadedStamp = null;
        ReloadIfChanged();
    }

    public void Dispose()
    {
        _disposed = true;
        _timer.Stop();
    }

    private void ReloadIfChanged()
    {
        if (AppSettings.Logbook != LogbookKind.HrdLogbook)
        {
            Show(WorkedStations.Empty, "No logbook selected", null);
            return;
        }
        if (_isLoading)
        {
            return;
        }
        _isLoading = true;
        var loaded = _loadedStamp;
        // Everything that touches HRD's settings or log runs off the UI
        // thread: the log can be large and lives in (OneDrive) Documents.
        Task.Run(() => Load(loaded)).ContinueWith(task => _dispatcher.TryEnqueue(() =>
        {
            _isLoading = false;
            if (_disposed)
            {
                return;
            }
            var result = task.IsCompletedSuccessfully
                ? task.Result
                : new LoadResult(null, null, task.Exception?.InnerException?.Message ?? "The log couldn't be read");
            if (result.Problem is { } problem)
            {
                // _loadedStamp is cleared, so the next check tries again;
                // logged once, not every check.
                if (problem != Problem)
                {
                    AppLog.Write($"Worked-before index: {problem}");
                }
                Show(WorkedStations.Empty, problem, null);
            }
            else if (result.Qsos is { } qsos)
            {
                var worked = new WorkedStations(qsos);
                AppLog.Write($"Worked-before index: {qsos.Count} QSOs, {worked.StationCount} stations");
                Show(worked, null, result.Stamp);
            }
        }));
    }

    /// Stamp, then QSOs (null when the files haven't changed since
    /// `loaded`), or why the log can't be read.
    private sealed record LoadResult(string? Stamp, List<WorkedStations.Qso>? Qsos, string? Problem);

    private static LoadResult Load(string? loaded)
    {
        if (HrdLogbook.LogPath is not { } path)
        {
            return new LoadResult(null, null, HrdLogbook.UnreadableDatabaseReason() ?? "HRD's log file wasn't found");
        }
        var stamp = Stamp(path);
        if (stamp == loaded)
        {
            return new LoadResult(stamp, null, null);
        }
        try
        {
            return new LoadResult(stamp, HrdLogbook.ReadWorkedQsos(path), null);
        }
        catch (HrdLogbook.LogException e)
        {
            return new LoadResult(stamp, null, e.Message);
        }
    }

    private void Show(WorkedStations worked, string? problem, string? stamp)
    {
        _loadedStamp = stamp;
        if (ReferenceEquals(worked, Worked) && problem == Problem)
        {
            return;
        }
        Worked = worked;
        Problem = problem;
        Changed?.Invoke();
    }

    private static string Stamp(string path)
    {
        static string Of(string file)
        {
            var info = new FileInfo(file);
            return info.Exists ? $"{info.LastWriteTimeUtc.Ticks}/{info.Length}" : "-";
        }
        return $"{path}|{Of(path)}|{Of(path + "-wal")}";
    }
}

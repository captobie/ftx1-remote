using System.Text.Json;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// The rig's programmed memory channels, for the memory list window — the
/// Mac's MemoryListStore. CAT has no "list memories" command, so a refresh
/// reads every channel in turn (RigctldClient.ReadMemoryChannelAsync: "MR",
/// plus "MT" for each programmed one). That's a few hundred round trips
/// sharing the link with the poll, so the result is cached in
/// %LOCALAPPDATA%\FTX1RemoteWindows\memory-channels.json and the window
/// shows the cache until the user clicks Refresh; a scan runs on its own
/// only when there's no cache yet. UI thread only: the scan's awaits
/// resume there.
public sealed class MemoryListStore
{
    private sealed class Snapshot
    {
        public List<MemoryChannelEntry> Entries { get; set; } = [];
        public DateTimeOffset Scanned { get; set; }
    }

    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FTX1RemoteWindows",
        "memory-channels.json");

    /// A scan stops after this many blank channels in a row. Blank channels
    /// are cheap (one "MR" answered "?;" at once), but channels are
    /// normally filled from 1, and reading all 999 would take several times
    /// longer than a typical list plus this margin. A gap this long would
    /// hide the channels past it. Same as the Mac.
    public const int BlankRunLimit = 100;

    private CancellationTokenSource? _scanCts;

    /// Raised when the list's contents change (not on every channel read).
    public event Action? EntriesChanged;
    /// Raised on scan progress, start/end, or an error — the status line.
    public event Action? StatusChanged;

    public IReadOnlyList<MemoryChannelEntry> Entries { get; private set; }
    /// The channel being read while a scan runs, null otherwise.
    public int? ScanningChannel { get; private set; }
    public DateTimeOffset? LastScanned { get; private set; }
    /// Why the last scan stopped early, if it did.
    public string? ScanError { get; private set; }

    public bool IsScanning => _scanCts is not null;

    public MemoryListStore()
    {
        var snapshot = Load();
        Entries = snapshot?.Entries ?? [];
        LastScanned = snapshot?.Scanned;
    }

    /// Re-reads the list through <paramref name="clientProvider"/>'s client
    /// (MainWindow's current one; null or a different one means the session
    /// ended, which stops the scan). While it runs, rows past the scan
    /// position keep their cached values, so the list doesn't empty out;
    /// channels found blank are dropped as it passes them. Saved only when
    /// the scan completes.
    public async void Refresh(Func<RigctldClient?> clientProvider)
    {
        if (_scanCts is not null || clientProvider() is not { } client)
        {
            return;
        }
        var cts = new CancellationTokenSource();
        _scanCts = cts;
        ScanError = null;
        try
        {
            await ScanAsync(client, clientProvider, cts.Token);
        }
        finally
        {
            _scanCts = null;
            ScanningChannel = null;
            cts.Dispose();
            StatusChanged?.Invoke();
        }
    }

    public void Cancel() => _scanCts?.Cancel();

    private async Task ScanAsync(RigctldClient client, Func<RigctldClient?> clientProvider, CancellationToken cancellationToken)
    {
        var found = new List<MemoryChannelEntry>();
        var blankRun = 0;
        for (var channel = 1; channel <= 999; channel++)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                ScanError = $"Stopped at channel {channel}.";
                return;
            }
            ScanningChannel = channel;
            StatusChanged?.Invoke();
            try
            {
                if (await client.ReadMemoryChannelAsync(channel) is { } entry)
                {
                    found.Add(entry);
                    blankRun = 0;
                }
                else
                {
                    blankRun++;
                }
            }
            catch (Exception ex)
            {
                // A timed-out read (the client has already reconnected)
                // counts as blank; a session that's gone ends the scan.
                if (!ReferenceEquals(clientProvider(), client) || ex.Message.StartsWith("Not connected", StringComparison.Ordinal)
                    || ex.Message.StartsWith("Connection closed", StringComparison.Ordinal))
                {
                    ScanError = $"Lost the rig connection at channel {channel}.";
                    AppLog.Write($"memory-list: scan stopped at channel {channel}: {ex.Message}");
                    return;
                }
                blankRun++;
            }
            var current = channel;
            SetEntries([.. found, .. Entries.Where(e => e.Channel > current)]);
            if (blankRun >= BlankRunLimit)
            {
                break;
            }
        }
        SetEntries(found);
        LastScanned = DateTimeOffset.Now;
        AppLog.Write($"memory-list: read {found.Count} channels");
        Save(new Snapshot { Entries = found, Scanned = LastScanned.Value });
    }

    private void SetEntries(List<MemoryChannelEntry> entries)
    {
        var same = entries.Count == Entries.Count && entries.Zip(Entries).All(pair => pair.First.SameAs(pair.Second));
        Entries = entries;
        if (!same)
        {
            EntriesChanged?.Invoke();
        }
    }

    private static void Save(Snapshot snapshot)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(snapshot));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception ex)
        {
            AppLog.Write($"memory-list: save failed: {ex.Message}");
        }
    }

    private static Snapshot? Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                return JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(FilePath));
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"memory-list: can't read {FilePath}: {ex.Message}");
        }
        return null;
    }
}

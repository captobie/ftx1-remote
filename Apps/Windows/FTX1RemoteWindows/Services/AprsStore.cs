using System.Text.Json;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows.Services;

/// The decoded station/message history the APRS windows show — the Mac's
/// APRSStore plus APRSPersistence. UI thread only (MainWindow marshals the
/// decoders' callbacks there). Loaded on startup and saved after every
/// update to %LOCALAPPDATA%\FTX1RemoteWindows\aprs-history.json; APRS
/// traffic is a few packets a minute at most, so a synchronous save each
/// time needs no debouncing.
public sealed class AprsStore
{
    private sealed class Snapshot
    {
        public List<AprsStation> Stations { get; set; } = [];
        public List<AprsMessage> Messages { get; set; } = [];
    }

    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FTX1RemoteWindows",
        "aprs-history.json");

    private readonly List<AprsStation> _stations;
    private readonly List<AprsMessage> _messages;

    /// Raised after any change (including a clear).
    public event Action? Changed;

    public IReadOnlyList<AprsStation> Stations => _stations;
    public IReadOnlyList<AprsMessage> Messages => _messages;

    public AprsStore()
    {
        var loaded = Load();
        _stations = loaded.Stations;
        _messages = loaded.Messages;
        // Also on load: covers a limit lowered since the file was written.
        TrimStations();
        TrimMessages();
    }

    /// Upserts by callsign (SSID included). Null fields leave the stored
    /// value alone; LastHeardAt and Source always update.
    public void RecordStation(string callsign, double? latitude, double? longitude, string? symbolTable,
        string? symbolCode, string? comment, DateTimeOffset heardAt, AprsSource source)
    {
        var station = _stations.Find(s => s.Callsign == callsign);
        if (station is null)
        {
            station = new AprsStation { Callsign = callsign };
            _stations.Add(station);
        }
        station.Latitude = latitude ?? station.Latitude;
        station.Longitude = longitude ?? station.Longitude;
        station.SymbolTable = symbolTable ?? station.SymbolTable;
        station.SymbolCode = symbolCode ?? station.SymbolCode;
        station.Comment = comment ?? station.Comment;
        station.LastHeardAt = heardAt;
        station.Source = source;
        TrimStations();
        Persist();
    }

    public void RecordMessage(string from, string to, string text, string? messageId, DateTimeOffset receivedAt, AprsSource source)
    {
        _messages.Add(new AprsMessage { From = from, To = to, Text = text, MessageId = messageId, ReceivedAt = receivedAt, Source = source });
        TrimMessages();
        Persist();
    }

    public void ClearHistory()
    {
        _stations.Clear();
        _messages.Clear();
        try
        {
            File.Delete(FilePath);
        }
        catch
        {
            // Best-effort, like every other file write here.
        }
        Changed?.Invoke();
    }

    /// Drops the least recently heard stations past the limit — only a new
    /// callsign grows the list, so this is the one place it can overflow.
    private void TrimStations()
    {
        var limit = AppSettings.AprsMaxStations;
        if (_stations.Count > limit)
        {
            _stations.Sort((a, b) => b.LastHeardAt.CompareTo(a.LastHeardAt));
            _stations.RemoveRange(limit, _stations.Count - limit);
        }
    }

    private void TrimMessages()
    {
        var limit = AppSettings.AprsMaxMessages;
        if (_messages.Count > limit)
        {
            _messages.Sort((a, b) => b.ReceivedAt.CompareTo(a.ReceivedAt));
            _messages.RemoveRange(limit, _messages.Count - limit);
        }
    }

    /// Applies a lowered limit from Settings straight away.
    public void ApplyLimits()
    {
        var before = (_stations.Count, _messages.Count);
        TrimStations();
        TrimMessages();
        if (before != (_stations.Count, _messages.Count))
        {
            Persist();
        }
    }

    private void Persist()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var json = JsonSerializer.Serialize(new Snapshot { Stations = _stations, Messages = _messages });
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, json);
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception ex)
        {
            AppLog.Write($"aprs-store: save failed: {ex.Message}");
        }
        Changed?.Invoke();
    }

    /// A missing or unreadable file starts an empty history rather than
    /// failing startup.
    private static Snapshot Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                return JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(FilePath)) ?? new Snapshot();
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"aprs-store: can't read {FilePath}: {ex.Message}");
        }
        return new Snapshot();
    }
}

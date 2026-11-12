using System.Text.Json;
using FTX1RemoteWindows.Models;

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

    /// %LOCALAPPDATA%\\FTX1RemoteWindows\\aprs-history.json.
    public static readonly string DefaultFilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FTX1RemoteWindows",
        "aprs-history.json");

    private readonly string _filePath;
    private readonly Func<int> _maxStations;
    private readonly Func<int> _maxMessages;

    private readonly List<AprsStation> _stations;
    private readonly List<AprsMessage> _messages;

    /// Raised after any change (including a clear).
    public event Action? Changed;

    public IReadOnlyList<AprsStation> Stations => _stations;
    public IReadOnlyList<AprsMessage> Messages => _messages;

    public AprsStore(string filePath, Func<int> maxStations, Func<int> maxMessages)
    {
        _filePath = filePath;
        _maxStations = maxStations;
        _maxMessages = maxMessages;
        var loaded = Load(filePath);
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

    /// A message with an id that's already listed (same sender, addressee,
    /// id and text within <see cref="DuplicateWindow"/>) is a retry of one
    /// already heard, or its digipeated copy: not listed again. Returns
    /// whether it was added.
    public bool RecordMessage(string from, string to, string text, string? messageId, DateTimeOffset receivedAt, AprsSource source)
    {
        if (messageId is not null && _messages.Any(m =>
                m.Delivery is null && m.From == from && m.To == to && m.MessageId == messageId && m.Text == text
                && receivedAt - m.ReceivedAt < DuplicateWindow))
        {
            return false;
        }
        _messages.Add(new AprsMessage { From = from, To = to, Text = text, MessageId = messageId, ReceivedAt = receivedAt, Source = source });
        TrimMessages();
        Persist();
        return true;
    }

    public static readonly TimeSpan DuplicateWindow = TimeSpan.FromMinutes(30);

    /// One of this station's own messages (Delivery set).
    public void RecordOutgoing(AprsMessage message)
    {
        _messages.Add(message);
        TrimMessages();
        Persist();
    }

    /// Changes an own message's delivery state; nothing if it's gone.
    public void UpdateDelivery(string id, Action<AprsDelivery> change)
    {
        var message = _messages.Find(m => m.Id == id);
        if (message?.Delivery is not { } delivery)
        {
            return;
        }
        var edited = delivery.Copy();
        change(edited);
        if (edited.SameAs(delivery))
        {
            return;
        }
        message.Delivery = edited;
        Persist();
    }

    public void ClearHistory()
    {
        _stations.Clear();
        _messages.Clear();
        try
        {
            File.Delete(_filePath);
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
        var limit = _maxStations();
        if (_stations.Count > limit)
        {
            _stations.Sort((a, b) => b.LastHeardAt.CompareTo(a.LastHeardAt));
            _stations.RemoveRange(limit, _stations.Count - limit);
        }
    }

    private void TrimMessages()
    {
        var limit = _maxMessages();
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
            Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
            var json = JsonSerializer.Serialize(new Snapshot { Stations = _stations, Messages = _messages });
            var temp = _filePath + ".tmp";
            File.WriteAllText(temp, json);
            File.Move(temp, _filePath, overwrite: true);
        }
        catch (Exception ex)
        {
            AppLog.Write($"aprs-store: save failed: {ex.Message}");
        }
        Changed?.Invoke();
    }

    /// A missing or unreadable file starts an empty history rather than
    /// failing startup.
    private static Snapshot Load(string filePath)
    {
        try
        {
            if (File.Exists(filePath))
            {
                return JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(filePath)) ?? new Snapshot();
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"aprs-store: can't read {filePath}: {ex.Message}");
        }
        return new Snapshot();
    }
}

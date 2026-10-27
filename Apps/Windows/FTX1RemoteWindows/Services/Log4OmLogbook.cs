using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Security;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows.Services;

/// What this app knows about Log4OM (Log4OM 2 "NextGen"). Everything here
/// was worked out against Log4OM 2.42.1.0 on the user's PC (2026-10-20) —
/// its settings file, its assemblies' enums and type names, and live tests —
/// not from documentation:
///
/// - **QSOs go in through a UDP inbound connection of type ADIF_MESSAGE**
///   (Settings → Program Configuration → Software Integration →
///   Connections): plain ADIF text in one datagram (AdifRecord.File), as
///   for HRD. None exists until the user adds one; it listens on 0.0.0.0 at
///   its port. A QSO was in the log within a second, every field right;
///   Log4OM replaces programid with its own and looks the call up itself.
/// - **Remote control** (UDP, port 2241 by default, on by default) takes
///   an XML RemoteControlRequest and answers to the sender's port with a
///   RemoteControlResponse (Done, ErrorMessage). SetCallsign fills Log4OM's
///   call field and looks it up — the Log pane's Lookup. WorkedBefore also
///   exists (WorkedSameBandMode / WorkedSameMode / Undefined) but answers
///   one call at a time, so worked-before still reads the log file.
/// - **The log is SQLite** (DbConfiguration.DatabaseType 1; 2/3 are MySQL
///   and MariaDB, not read here), path in the settings file; table Log with
///   callsign, band ("40m"), mode, freq (**kHz**) and qsodate (UTC text,
///   "2026-10-20 14:05:13Z"). Rollback journal, not WAL.
///
/// Log4OM keeps its settings in %APPDATA%\Log4OM2\user\config.json; its
/// process is L4ONG.exe.
public static class Log4OmLogbook
{
    public static readonly string ConfigPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Log4OM2", "user", "config.json");

    public const int DefaultRemoteControlPort = 2241;

    /// An enabled UDP inbound ADIF_MESSAGE connection, or the first
    /// disabled one when none is on.
    public sealed record AdifConnection(string Name, int Port, bool Enabled);

    /// The parts of Log4OM's running configuration this app uses.
    public sealed record Config(
        int DatabaseType,
        string DatabasePath,
        AdifConnection? Adif,
        bool RemoteControlEnabled,
        int RemoteControlPort);

    private const int SqliteDatabase = 1;
    private const int UdpInbound = 1;
    private const int AdifMessage = 1;

    /// Read from config.json (the running configuration); null if Log4OM's
    /// settings can't be read (not installed, or never configured).
    public static Config? ReadConfig()
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(ConfigPath));
            var root = document.RootElement;
            var running = root.TryGetProperty("RunningConfigurationId", out var id) ? id.GetString() : null;
            if (!root.TryGetProperty("UserConfigs", out var configs) || configs.ValueKind != JsonValueKind.Array)
            {
                return null;
            }
            JsonElement? chosen = null;
            foreach (var config in configs.EnumerateArray())
            {
                chosen ??= config;
                if (config.TryGetProperty("ConfigurationId", out var cid) && cid.GetString() == running)
                {
                    chosen = config;
                    break;
                }
            }
            if (chosen is not { } user)
            {
                return null;
            }

            var databaseType = 0;
            var databasePath = "";
            if (user.TryGetProperty("DbConfiguration", out var db) && db.ValueKind == JsonValueKind.Object)
            {
                databaseType = Int(db, "DatabaseType");
                databasePath = Str(db, "Path");
            }

            AdifConnection? adif = null;
            if (user.TryGetProperty("Connections", out var connections) && connections.ValueKind == JsonValueKind.Array)
            {
                foreach (var c in connections.EnumerateArray())
                {
                    if (Int(c, "NetworkConnectionType") != UdpInbound || Int(c, "NetworkInboundMessageType") != AdifMessage)
                    {
                        continue;
                    }
                    var found = new AdifConnection(Str(c, "Name"), Int(c, "SourcePort"),
                        c.TryGetProperty("Enabled", out var e) && e.ValueKind == JsonValueKind.True);
                    if (found.Enabled)
                    {
                        adif = found;
                        break;
                    }
                    adif ??= found;
                }
            }

            var remotePort = Int(user, "RemoteControlPort");
            return new Config(
                databaseType,
                databasePath,
                adif,
                user.TryGetProperty("RemoteControlEnabled", out var rc) && rc.ValueKind == JsonValueKind.True,
                remotePort is >= 1 and <= 65535 ? remotePort : DefaultRemoteControlPort);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    private static int Int(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var i) ? i : 0;

    private static string Str(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";

    /// Log4OM's own log, when it's a SQLite file.
    public static string? DetectedLogPath() =>
        ReadConfig() is { DatabaseType: SqliteDatabase, DatabasePath.Length: > 0 } config ? config.DatabasePath : null;

    /// Why Log4OM's log can't be read here.
    public static string UnreadableDatabaseReason() => ReadConfig() switch
    {
        null => Loc.S("log4OmLogbook.log4OMsSettingsWerentFound"),
        { DatabaseType: 2 or 3 } => Loc.S("log4OmLogbook.log4OMsLogIsOn"),
        { DatabasePath.Length: 0 } => Loc.S("log4OmLogbook.log4OMHasNoLog"),
        _ => Loc.S("log4OmLogbook.log4OMsLogFileWasnt"),
    };

    /// The log file to read: the hand-picked one if set, otherwise Log4OM's.
    public static string? LogPath =>
        AppSettings.Log4OmLogPath is { Length: > 0 } path ? path : DetectedLogPath();

    /// Where QSOs are sent: Settings → Logbook's override, else this PC and
    /// Log4OM's ADIF_MESSAGE connection port.
    public static (string Host, int Port)? Destination()
    {
        var host = AppSettings.Log4OmUdpHost is { Length: > 0 } h ? h : "127.0.0.1";
        var port = AppSettings.Log4OmUdpPort is > 0 and var p ? p : ReadConfig()?.Adif?.Port ?? 0;
        return port > 0 ? (host, port) : null;
    }

    public static bool IsRunning
    {
        get
        {
            var processes = Process.GetProcessesByName("L4ONG");
            foreach (var process in processes)
            {
                process.Dispose();
            }
            return processes.Length > 0;
        }
    }

    /// Log4OM as QsoLogger and WorkedStationsStore see it.
    public static readonly ILogbookProgram Program = new Log4OmProgram();

    private sealed class Log4OmProgram : ILogbookProgram
    {
        public string Name => "Log4OM";
        public string? LogPath => Log4OmLogbook.LogPath;
        public string MissingLogReason => UnreadableDatabaseReason();
        public (string Host, int Port)? Destination() => Log4OmLogbook.Destination();
        public string MissingDestinationReason =>
            Loc.S("log4OmLogbook.log4OMHasNoADIF");
        public string UnconfirmedReason(string host, int port)
        {
            if (!IsRunning)
            {
                return Loc.S("common.log4OMIsntRunning");
            }
            if (AppSettings.Log4OmUdpPort == 0 && ReadConfig()?.Adif is { Enabled: false } adif)
            {
                return Loc.F("log4OmLogbook.log4OMsXConnectionIs", adif.Name);
            }
            return LogbookPrograms.IsLocalHost(host) && !LogbookPrograms.IsListening(port)
                ? Loc.F("common.nothingIsListeningOn", port)
                : Loc.F("common.itDidntShowUp", QsoLogger.ConfirmationTimeout.TotalSeconds);
        }
        public List<WorkedStations.Qso> ReadWorkedQsos(string path) => Log4OmLogbook.ReadWorkedQsos(path);
        public bool ContainsQso(string call, DateTimeOffset start, string path) => Log4OmLogbook.ContainsQso(call, start, path);
        public bool SupportsLookup => true;
    }

    /// Every QSO in the log, for worked-before. Off the UI thread.
    public static List<WorkedStations.Qso> ReadWorkedQsos(string path)
    {
        return LogbookDatabase.Query(path, connection =>
        {
            RequireLogTable(connection);
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT callsign, band, mode, freq, qsodate FROM Log";
            using var reader = command.ExecuteReader();
            var qsos = new List<WorkedStations.Qso>();
            while (reader.Read())
            {
                var call = LogbookDatabase.Text(reader, 0);
                if (call.Length == 0)
                {
                    continue;
                }
                var band = LogbookDatabase.Text(reader, 1);
                if (band.Length == 0 && Hz(LogbookDatabase.Text(reader, 3)) is { } hz)
                {
                    band = BandPlan.BandContaining(hz)?.Name ?? "";
                }
                qsos.Add(new WorkedStations.Qso(call, band, LogbookDatabase.Text(reader, 2),
                    Date(LogbookDatabase.Text(reader, 4)) ?? DateTimeOffset.MinValue));
            }
            return qsos;
        });
    }

    /// Whether a QSO with this call starting at `start` (±2 s) is in the
    /// log. The callsign column is COLLATE NOCASE.
    public static bool ContainsQso(string call, DateTimeOffset start, string path)
    {
        return LogbookDatabase.Query(path, connection =>
        {
            RequireLogTable(connection);
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT qsodate FROM Log WHERE callsign = $call";
            command.Parameters.AddWithValue("$call", call);
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                if (Date(LogbookDatabase.Text(reader, 0)) is { } logged && Math.Abs((logged - start).TotalSeconds) <= 2)
                {
                    return true;
                }
            }
            return false;
        });
    }

    private static void RequireLogTable(Microsoft.Data.Sqlite.SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'Log' COLLATE NOCASE";
        if (command.ExecuteScalar() is null)
        {
            throw new LogbookDatabase.LogException(Loc.S("log4OmLogbook.thisIsntALog4OM"));
        }
    }

    /// freq is kHz ("7030.5").
    private static long? Hz(string kHz) =>
        decimal.TryParse(kHz, NumberStyles.Float, CultureInfo.InvariantCulture, out var k) && k > 0 ? (long)Math.Round(k * 1000) : null;

    /// qsodate, UTC ("2026-10-20 14:05:13Z").
    private static DateTimeOffset? Date(string text) =>
        DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var date)
            ? date
            : null;

    // Remote control.

    /// Log4OM's answer to a remote-control request.
    public sealed record RemoteReply(bool Done, string? Error);

    /// Where remote-control requests go: the Send-to host override (so
    /// Lookup follows a Log4OM on another computer), Log4OM's port.
    public static (string Host, int Port) RemoteControlEndpoint()
    {
        var host = AppSettings.Log4OmUdpHost is { Length: > 0 } h ? h : "127.0.0.1";
        return (host, ReadConfig()?.RemoteControlPort ?? DefaultRemoteControlPort);
    }

    /// Fills Log4OM's call field and looks the call up (SetCallsign).
    public static Task<RemoteReply?> SetCallsignAsync(string call)
    {
        var (host, port) = RemoteControlEndpoint();
        return RequestAsync(host, port, "SetCallsign", $"<Callsign>{SecurityElement.Escape(call)}</Callsign>");
    }

    /// Whether remote control answers at all (Alive) — Settings → Logbook,
    /// which checks the host typed there, not yet saved.
    public static Task<RemoteReply?> AliveAsync(string host, int port) => RequestAsync(host, port, "Alive", "");

    /// Sends one request and waits up to 2 s for its answer (matched by
    /// MessageId); null when nothing answered.
    private static async Task<RemoteReply?> RequestAsync(string host, int port, string message, string fields)
    {
        var id = Guid.NewGuid();
        var xml = $"<?xml version=\"1.0\" encoding=\"utf-8\"?><RemoteControlRequest><MessageId>{id}</MessageId>"
                  + $"<RemoteControlMessage>{message}</RemoteControlMessage>{fields}</RemoteControlRequest>";
        try
        {
            using var udp = new UdpClient(0);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await udp.SendAsync(Encoding.UTF8.GetBytes(xml), host, port, timeout.Token);
            while (true)
            {
                var result = await udp.ReceiveAsync(timeout.Token);
                if (Parse(result.Buffer, id) is { } reply)
                {
                    return reply;
                }
            }
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException)
        {
            AppLog.Write($"Log4OM remote control: {message} to {host}:{port} got no answer: {e.Message}");
            return null;
        }
    }

    private static RemoteReply? Parse(byte[] datagram, Guid id)
    {
        try
        {
            var root = XDocument.Parse(Encoding.UTF8.GetString(datagram)).Root;
            if (root is null || (string?)root.Element("MessageId") != id.ToString())
            {
                return null;
            }
            var error = ((string?)root.Element("ErrorMessage"))?.Trim();
            return new RemoteReply(
                string.Equals((string?)root.Element("Done"), "true", StringComparison.OrdinalIgnoreCase),
                string.IsNullOrEmpty(error) ? null : error);
        }
        catch (System.Xml.XmlException)
        {
            return null;
        }
    }
}

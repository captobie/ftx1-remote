using System.Diagnostics;
using System.Globalization;
using System.Net.NetworkInformation;
using System.Xml.Linq;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.Data.Sqlite;

namespace FTX1RemoteWindows.Services;

/// What this app knows about Ham Radio Deluxe's logbook (HRD Logbook 6.x),
/// the Windows counterpart of the Mac's MacLoggerDX.swift. Everything here
/// was worked out against HRD Logbook 6.9.0.18083 on the user's PC
/// (2026-10-09), not from documentation:
///
/// - **QSOs go in through its ADIF receiver**: QSO Forwarding's "Receive
///   QSO notifications using UDP9/ADIF from other logging programs (eg.
///   WSJT-X)" — plain ADIF text in one UDP datagram (AdifRecord.File), the
///   form WSJT-X's secondary "ADIF broadcast" server sends. Off by default;
///   on that PC it listens on 127.0.0.1:2339 once ticked. HRD's other UDP
///   listener, the WSJT-X ALERT dock on 2237, only shows decodes: neither
///   a "QSO Logged" nor a "Logged ADIF" message sent there was logged.
///   HRD fills in the station callsign and looks the call up (name,
///   country) itself.
/// - **The log is SQLite** ("Local/SQLite" database type), path in HRD's
///   own LogbookDatabases*.xml; one table, TABLE_HRD_CONTACTS_V07, with
///   COL_CALL, COL_BAND ("40m", sometimes "40M"), COL_MODE, COL_FREQ (Hz),
///   COL_QSO_DATE ("yyyy-MM-dd") and COL_TIME_ON ("HH:mm:ss.fff"), UTC.
///   WAL journal. Always opened read-only and unpooled, so no handle on the
///   user's log outlives a read; never written.
///
/// HRD keeps its settings in %APPDATA%\HRDLLC\HRD Logbook\.
public static class HrdLogbook
{
    public static readonly string SettingsDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HRDLLC", "HRD Logbook");

    /// HRD's ADIF receiver as configured in its own settings.
    public sealed record ReceiverConfig(bool Enabled, string Address, int Port, string TargetDatabase);

    /// Read from LogbookUserSettings.xml (the UDP9 keys); null if HRD's
    /// settings can't be read (not installed, or never configured).
    public static ReceiverConfig? Receiver()
    {
        try
        {
            var root = XDocument.Load(Path.Combine(SettingsDirectory, "LogbookUserSettings.xml")).Root;
            if (root is null)
            {
                return null;
            }
            string Value(string name) => root.Element(name)?.Value.Trim() ?? "";
            var port = int.TryParse(Value("UDPReceivePortSection9"), out var p) && p is >= 1 and <= 65535 ? p : 0;
            var address = Value("UDP9AddressV3");
            return new ReceiverConfig(
                Value("UDPReceiveSection9Enable") == "1",
                address.Length == 0 || address == "0.0.0.0" ? "127.0.0.1" : address,
                port,
                Value("UDPTargetDB9"));
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// One database in HRD's database list.
    public sealed record Database(string Title, string Type, string Path);

    /// HRD's configured logbooks, from the newest LogbookDatabases*.xml
    /// (HRD 6.9 writes LogbookDatabases8.xml and leaves older versions'
    /// files in place).
    public static IReadOnlyList<Database> Databases()
    {
        try
        {
            var file = new DirectoryInfo(SettingsDirectory)
                .GetFiles("LogbookDatabases*.xml")
                .OrderByDescending(f => f.LastWriteTimeUtc)
                .FirstOrDefault();
            if (file is null)
            {
                return [];
            }
            return XDocument.Load(file.FullName).Root?.Elements("Database")
                .Select(e => new Database(
                    (string?)e.Attribute("Title") ?? "",
                    (string?)e.Attribute("DatabaseType") ?? "",
                    (string?)e.Attribute("Database") ?? ""))
                .ToList() ?? [];
        }
        catch (Exception)
        {
            return [];
        }
    }

    /// The log QSOs are received into: the ADIF receiver's target database
    /// if it's a local SQLite one, otherwise the first local SQLite log.
    public static string? DetectedLogPath()
    {
        var sqlite = Databases().Where(IsSqlite).ToList();
        var target = Receiver()?.TargetDatabase;
        var match = sqlite.FirstOrDefault(d => d.Title == target) ?? sqlite.FirstOrDefault();
        return match?.Path;
    }

    /// Why HRD's log can't be read here, when its target database isn't a
    /// local SQLite file (HRD also supports Access, MySQL and SQL Server).
    public static string? UnreadableDatabaseReason()
    {
        var target = Receiver()?.TargetDatabase;
        var database = Databases().FirstOrDefault(d => d.Title == target);
        return database is not null && !IsSqlite(database)
            ? $"HRD's \"{database.Title}\" log is {database.Type}; only a local SQLite log can be read"
            : null;
    }

    private static bool IsSqlite(Database d) => d.Type.Contains("SQLite", StringComparison.OrdinalIgnoreCase);

    /// The log file to read: the hand-picked one if set, otherwise the one
    /// HRD receives QSOs into.
    public static string? LogPath =>
        AppSettings.HrdLogPath is { Length: > 0 } path ? path : DetectedLogPath();

    /// Where QSOs are sent: Settings → Logbook's override, else HRD's own.
    public static (string Host, int Port)? Destination()
    {
        var receiver = Receiver();
        var host = AppSettings.HrdUdpHost is { Length: > 0 } h ? h : receiver?.Address ?? "127.0.0.1";
        var port = AppSettings.HrdUdpPort is > 0 and var p ? p : receiver?.Port ?? 0;
        return port > 0 ? (host, port) : null;
    }

    public static bool IsRunning
    {
        get
        {
            var processes = Process.GetProcessesByName("HRDLogbook");
            foreach (var process in processes)
            {
                process.Dispose();
            }
            return processes.Length > 0;
        }
    }

    /// Whether anything on this PC has the UDP port open — HRD's receiver,
    /// when it's the one that's running. Only meaningful for a local host.
    public static bool IsListening(int port) =>
        IPGlobalProperties.GetIPGlobalProperties().GetActiveUdpListeners().Any(e => e.Port == port);

    /// Why the log couldn't be read, in words for the window.
    public sealed class LogException(string message, Exception? inner = null) : Exception(message, inner);

    /// Every QSO in the log, for worked-before. Off the UI thread: the log
    /// can be large and lives in the user's (OneDrive) Documents.
    public static List<WorkedStations.Qso> ReadWorkedQsos(string path)
    {
        return Query(path, connection =>
        {
            var table = ContactsTable(connection);
            using var command = connection.CreateCommand();
            command.CommandText = $"SELECT COL_CALL, COL_BAND, COL_MODE, COL_FREQ, COL_QSO_DATE, COL_TIME_ON FROM \"{table}\"";
            using var reader = command.ExecuteReader();
            var qsos = new List<WorkedStations.Qso>();
            while (reader.Read())
            {
                var call = Text(reader, 0);
                if (call.Length == 0)
                {
                    continue;
                }
                var band = Text(reader, 1);
                if (band.Length == 0 && Hz(reader, 3) is { } hz)
                {
                    band = BandPlan.BandContaining(hz)?.Name ?? "";
                }
                qsos.Add(new WorkedStations.Qso(call, band, Text(reader, 2), Start(Text(reader, 4), Text(reader, 5)) ?? DateTimeOffset.MinValue));
            }
            return qsos;
        });
    }

    /// Whether a QSO with this call starting at `start` (to the second, ±2
    /// s) is in the log — how a sent QSO is confirmed, since UDP gets no
    /// reply.
    public static bool ContainsQso(string call, DateTimeOffset start, string path)
    {
        return Query(path, connection =>
        {
            var table = ContactsTable(connection);
            using var command = connection.CreateCommand();
            command.CommandText = $"SELECT COL_QSO_DATE, COL_TIME_ON FROM \"{table}\" WHERE UPPER(COL_CALL) = $call";
            command.Parameters.AddWithValue("$call", call.ToUpperInvariant());
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                if (Start(Text(reader, 0), Text(reader, 1)) is { } logged && Math.Abs((logged - start).TotalSeconds) <= 2)
                {
                    return true;
                }
            }
            return false;
        });
    }

    /// QSO and station counts for Settings → Logbook.
    public static (int Qsos, int Stations) Summary(string path)
    {
        var qsos = ReadWorkedQsos(path);
        return (qsos.Count, new WorkedStations(qsos).StationCount);
    }

    private static T Query<T>(string path, Func<SqliteConnection, T> body)
    {
        if (!File.Exists(path))
        {
            throw new LogException($"No log file at {path}");
        }
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
            DefaultTimeout = 5,
        };
        try
        {
            using var connection = new SqliteConnection(builder.ToString());
            connection.Open();
            return body(connection);
        }
        catch (SqliteException e)
        {
            throw new LogException($"Couldn't read the log: {e.Message}", e);
        }
    }

    /// The newest TABLE_HRD_CONTACTS_V* table (V07 in HRD 6.9).
    private static string ContactsTable(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'TABLE_HRD_CONTACTS_V%' ORDER BY name DESC LIMIT 1";
        return command.ExecuteScalar() as string
            ?? throw new LogException("This isn't an HRD log (no TABLE_HRD_CONTACTS table)");
    }

    private static string Text(SqliteDataReader reader, int column) =>
        reader.IsDBNull(column) ? "" : Convert.ToString(reader.GetValue(column), CultureInfo.InvariantCulture)?.Trim() ?? "";

    private static long? Hz(SqliteDataReader reader, int column) =>
        long.TryParse(Text(reader, column), NumberStyles.Integer, CultureInfo.InvariantCulture, out var hz) && hz > 0 ? hz : null;

    private static readonly string[] TimeFormats = ["HH:mm:ss.fff", "HH:mm:ss", "HH:mm", "HHmmss", "HHmm"];

    /// COL_QSO_DATE + COL_TIME_ON, both UTC.
    private static DateTimeOffset? Start(string date, string time)
    {
        if (!DateTime.TryParseExact(date.Length >= 10 ? date[..10] : date, ["yyyy-MM-dd", "yyyyMMdd"], CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var day))
        {
            return null;
        }
        var timeOfDay = DateTime.TryParseExact(time, TimeFormats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var t)
            ? t.TimeOfDay
            : TimeSpan.Zero;
        return new DateTimeOffset(day.Date + timeOfDay, TimeSpan.Zero);
    }
}

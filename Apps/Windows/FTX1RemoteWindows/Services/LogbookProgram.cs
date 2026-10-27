using System.Globalization;
using System.Net.NetworkInformation;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.Data.Sqlite;

namespace FTX1RemoteWindows.Services;

/// A logging program the CW window logs to and reads worked-before from
/// (Settings → Logbook): HRD Logbook or Log4OM. Both take a QSO as one UDP
/// datagram of ADIF text and keep their log in a SQLite file this app only
/// reads, so QsoLogger and WorkedStationsStore work the same for either.
public interface ILogbookProgram
{
    /// "HRD Logbook", "Log4OM" — for the Log pane's messages.
    string Name { get; }

    /// The log file to read, or null when it can't be found or read here.
    string? LogPath { get; }

    /// Why LogPath is null, in words for the window.
    string MissingLogReason { get; }

    /// Where QSOs are sent; null when the program's receiver port isn't
    /// known.
    (string Host, int Port)? Destination();

    /// Why Destination() is null.
    string MissingDestinationReason { get; }

    /// Why a sent QSO didn't show up in the log within the timeout.
    string UnconfirmedReason(string host, int port);

    /// Every QSO in the log, for worked-before. Throws LogbookDatabase.LogException.
    List<WorkedStations.Qso> ReadWorkedQsos(string path);

    /// Whether a QSO with this call starting at `start` (±2 s) is in the
    /// log. Throws LogbookDatabase.LogException.
    bool ContainsQso(string call, DateTimeOffset start, string path);

    /// Whether the program can be asked to look a call up (the Log pane's
    /// Lookup button).
    bool SupportsLookup { get; }
}

public static class LogbookPrograms
{
    /// The program chosen in Settings → Logbook, or null for None.
    public static ILogbookProgram? Current => For(AppSettings.Logbook);

    public static ILogbookProgram? For(LogbookKind kind) => kind switch
    {
        LogbookKind.HrdLogbook => HrdLogbook.Program,
        LogbookKind.Log4Om => Log4OmLogbook.Program,
        _ => null,
    };

    /// Whether anything on this PC has the UDP port open. Only meaningful
    /// for a local host.
    public static bool IsListening(int port) =>
        IPGlobalProperties.GetIPGlobalProperties().GetActiveUdpListeners().Any(e => e.Port == port);

    public static bool IsLocalHost(string host) => host is "127.0.0.1" or "localhost" or "::1";
}

/// Read-only access to a logging program's SQLite log.
public static class LogbookDatabase
{
    /// Why the log couldn't be read, in words for the window.
    public sealed class LogException(string message, Exception? inner = null) : Exception(message, inner);

    /// Opens the log read-only and unpooled, so no handle on the user's log
    /// outlives a read; never written.
    public static T Query<T>(string path, Func<SqliteConnection, T> body)
    {
        if (!File.Exists(path))
        {
            throw new LogException(Loc.F("logbookProgram.noLogFileAt", path));
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
            throw new LogException(Loc.F("logbookProgram.couldntReadTheLog", e.Message), e);
        }
    }

    public static string Text(SqliteDataReader reader, int column) =>
        reader.IsDBNull(column) ? "" : Convert.ToString(reader.GetValue(column), CultureInfo.InvariantCulture)?.Trim() ?? "";

    /// QSO and station counts for Settings → Logbook.
    public static (int Qsos, int Stations) Summary(ILogbookProgram program, string path)
    {
        var qsos = program.ReadWorkedQsos(path);
        return (qsos.Count, new WorkedStations(qsos).StationCount);
    }
}

using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows.Services;

/// What happened to a QSO handed to the logbook.
public abstract record QsoLogOutcome
{
    /// Found in the logbook's file afterward.
    public sealed record Logged : QsoLogOutcome;
    /// Sent, but not (yet) in the log — the program not running, its ADIF
    /// receiver off, or the log can't be read here.
    public sealed record SentUnconfirmed(string Reason) : QsoLogOutcome;
    public sealed record Failed(string Reason) : QsoLogOutcome;
    /// Wavelog only: it already had this QSO (its own duplicate check).
    public sealed record AlreadyLogged : QsoLogOutcome;
}

/// What each logbook made of one Log QSO; null = not sent there.
public sealed record QsoLogOutcomes(QsoLogOutcome? Primary, QsoLogOutcome? Wavelog);

/// Sends a finished QSO to the logbook chosen in Settings → Logbook and,
/// when it's turned on there, to Wavelog too (Wavelog, its REST API v2 —
/// both at once, each with its own outcome) — the Mac's QSOLogger. For
/// HRD Logbook and Log4OM alike that's one UDP
/// datagram of ADIF text to the program's ADIF receiver (see HrdLogbook,
/// Log4OmLogbook); UDP gets no answer, so the QSO is then looked for in
/// the program's log to confirm it arrived. Lookup is Log4OM's only: HRD
/// has no way found to be asked for one from outside, but looks up a
/// received call itself.
public static class QsoLogger
{
    /// How long to look for the QSO in the log after sending.
    public static readonly TimeSpan ConfirmationTimeout = TimeSpan.FromSeconds(5);

    /// Whether Log QSO has anywhere to send to.
    public static bool HasLogbook => LogbookPrograms.Current is not null || AppSettings.WavelogEnabled;

    /// Sends to the primary logbook and Wavelog, whichever are set up.
    public static async Task<QsoLogOutcomes> LogAsync(LoggedQso qso)
    {
        var primary = LogbookPrograms.Current is { } program ? LogToProgramAsync(program, qso) : null;
        var wavelog = AppSettings.WavelogEnabled ? LogToWavelogAsync(qso) : null;
        return new QsoLogOutcomes(
            primary is null ? null : await primary,
            wavelog is null ? null : await wavelog);
    }

    /// Wavelog alone — also the Log pane's retry after the primary took a
    /// QSO Wavelog didn't. There's an answer, so Logged is confirmed.
    public static async Task<QsoLogOutcome> LogToWavelogAsync(LoggedQso qso)
    {
        var (url, token, stationId, problem) = WavelogTarget();
        if (problem is not null)
        {
            return new QsoLogOutcome.Failed(problem);
        }
        try
        {
            switch (await Wavelog.LogAsync(qso, url, token, stationId))
            {
                case Wavelog.LogResult.Created:
                    AppLog.Write($"Logbook: logged {qso.Call} to Wavelog");
                    return new QsoLogOutcome.Logged();
                case Wavelog.LogResult.Duplicate:
                    AppLog.Write($"Logbook: {qso.Call} was already in Wavelog");
                    return new QsoLogOutcome.AlreadyLogged();
                case Wavelog.LogResult.Rejected(var reason):
                    AppLog.Write($"Logbook: Wavelog refused {qso.Call}: {reason}");
                    return new QsoLogOutcome.Failed(reason);
            }
        }
        catch (Wavelog.ApiException e)
        {
            AppLog.Write($"Logbook: logging {qso.Call} to Wavelog failed: {e.Message}");
            return new QsoLogOutcome.Failed(e.Message);
        }
        return new QsoLogOutcome.Failed(Loc.S("common.wavelogDidntImportThe"));
    }

    /// Where Wavelog QSOs go, or why they can't, in words for the Log pane.
    private static (string Url, string Token, string StationId, string? Problem) WavelogTarget()
    {
        var url = AppSettings.WavelogUrl.Trim();
        if (url.Length == 0)
        {
            return ("", "", "", Loc.S("qsoLogger.wavelogHasNoURL"));
        }
        var token = WavelogToken.Read();
        if (token.Length == 0)
        {
            return ("", "", "", Loc.S("qsoLogger.wavelogHasNoAPI"));
        }
        var station = AppSettings.WavelogStationId;
        if (station.Length == 0)
        {
            return ("", "", "", Loc.S("qsoLogger.noWavelogStationLocation"));
        }
        return (url, token, station, null);
    }

    private static async Task<QsoLogOutcome> LogToProgramAsync(ILogbookProgram program, LoggedQso qso)
    {
        if (program.Destination() is not { } destination)
        {
            return new QsoLogOutcome.Failed(program.MissingDestinationReason);
        }
        var (host, port) = destination;
        try
        {
            using var udp = new UdpClient();
            var datagram = Encoding.UTF8.GetBytes(AdifRecord.File(qso));
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await udp.SendAsync(datagram, host, port, timeout.Token);
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException)
        {
            AppLog.Write($"Logbook: sending {qso.Call} to {host}:{port} failed: {e.Message}");
            return new QsoLogOutcome.Failed(e is SocketException { SocketErrorCode: SocketError.HostNotFound }
                ? Loc.F("common.couldntFindTheHost", host)
                : Loc.F("qsoLogger.couldntSendToX", host, port, e.Message));
        }
        AppLog.Write($"Logbook: sent {qso.Call} ({qso.Mode}, {qso.FrequencyHz} Hz) to {program.Name} at {host}:{port}");
        return await ConfirmAsync(program, qso, host, port);
    }

    /// Polls the log until the QSO shows up or the timeout passes.
    private static async Task<QsoLogOutcome> ConfirmAsync(ILogbookProgram program, LoggedQso qso, string host, int port)
    {
        if (program.LogPath is not { } path)
        {
            return new QsoLogOutcome.SentUnconfirmed(Loc.F("qsoLogger.sentButXTo", program.MissingLogReason));
        }
        var clock = Stopwatch.StartNew();
        string? lastError = null;
        do
        {
            await Task.Delay(500);
            try
            {
                if (await Task.Run(() => program.ContainsQso(qso.Call, qso.Start, path)))
                {
                    AppLog.Write($"Logbook: {qso.Call} confirmed in the {program.Name} log");
                    return new QsoLogOutcome.Logged();
                }
                lastError = null;
            }
            catch (LogbookDatabase.LogException e)
            {
                lastError = e.Message;
            }
        }
        while (clock.Elapsed < ConfirmationTimeout);

        if (lastError is not null)
        {
            return new QsoLogOutcome.SentUnconfirmed(Loc.F("qsoLogger.sentButTheLog", lastError));
        }
        var reason = await Task.Run(() => program.UnconfirmedReason(host, port));
        AppLog.Write($"Logbook: {qso.Call} not found in the {program.Name} log: {reason}");
        return new QsoLogOutcome.SentUnconfirmed(Loc.F("qsoLogger.sentButX", reason));
    }

    /// Asks Log4OM to fill its call field and look the call up — the Mac's
    /// Lookup (there through WSJT-X's Status message to MacLoggerDX). Null
    /// when it worked, else why not.
    public static async Task<string?> LookUpAsync(string call)
    {
        if (LogbookPrograms.Current is not { SupportsLookup: true } program)
        {
            return Loc.S("qsoLogger.lookupNeedsLog4OMAs");
        }
        var reply = await Log4OmLogbook.SetCallsignAsync(call);
        AppLog.Write($"Logbook: lookup of {call} in {program.Name}: {(reply is null ? "no answer" : reply.Done ? "done" : reply.Error ?? "refused")}");
        if (reply is null)
        {
            var (host, port) = Log4OmLogbook.RemoteControlEndpoint();
            return await Task.Run(() => !Log4OmLogbook.IsRunning && LogbookPrograms.IsLocalHost(host)
                ? Loc.S("common.log4OMIsntRunning")
                : Log4OmLogbook.ReadConfig() is { RemoteControlEnabled: false }
                    ? Loc.S("qsoLogger.log4OMsRemoteControlIs")
                    : Loc.F("qsoLogger.log4OMDidntAnswerOn", port));
        }
        return reply.Done ? null : Loc.F("qsoLogger.log4OMRefusedTheLookup", reply.Error ?? Loc.S("qsoLogger.noReasonGiven"));
    }
}

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
    /// Sent, but not (yet) in the log — HRD not running, its ADIF receiver
    /// off, or the log can't be read here.
    public sealed record SentUnconfirmed(string Reason) : QsoLogOutcome;
    public sealed record Failed(string Reason) : QsoLogOutcome;
}

/// Sends a finished QSO to the logbook chosen in Settings → Logbook — the
/// Mac's QSOLogger. For HRD Logbook that's one UDP datagram of ADIF text
/// to its ADIF receiver (see HrdLogbook); UDP gets no answer, so the QSO is
/// then looked for in HRD's log to confirm it arrived. Unlike the Mac
/// there's no Lookup: HRD has no way found to be asked for one from
/// outside, but it looks up a received call itself.
public static class QsoLogger
{
    /// How long to look for the QSO in the log after sending.
    public static readonly TimeSpan ConfirmationTimeout = TimeSpan.FromSeconds(5);

    public static async Task<QsoLogOutcome> LogAsync(LoggedQso qso)
    {
        if (AppSettings.Logbook != LogbookKind.HrdLogbook)
        {
            return new QsoLogOutcome.Failed("No logbook is selected in Settings → Logbook");
        }
        if (HrdLogbook.Destination() is not { } destination)
        {
            return new QsoLogOutcome.Failed("HRD's ADIF receiver port isn't known — turn on its UDP9/ADIF receive (see Settings → Logbook)");
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
                ? $"Couldn't find the host {host}"
                : $"Couldn't send to {host}:{port}: {e.Message}");
        }
        AppLog.Write($"Logbook: sent {qso.Call} ({qso.Mode}, {qso.FrequencyHz} Hz) to {host}:{port}");
        return await ConfirmAsync(qso, port);
    }

    /// Polls the log until the QSO shows up or the timeout passes.
    private static async Task<QsoLogOutcome> ConfirmAsync(LoggedQso qso, int port)
    {
        if (HrdLogbook.LogPath is not { } path)
        {
            return new QsoLogOutcome.SentUnconfirmed(HrdLogbook.UnreadableDatabaseReason() is { } why
                ? $"Sent, but {why} to check it"
                : "Sent, but HRD's log file wasn't found to check it");
        }
        var clock = Stopwatch.StartNew();
        string? lastError = null;
        do
        {
            await Task.Delay(500);
            try
            {
                if (await Task.Run(() => HrdLogbook.ContainsQso(qso.Call, qso.Start, path)))
                {
                    AppLog.Write($"Logbook: {qso.Call} confirmed in the HRD log");
                    return new QsoLogOutcome.Logged();
                }
                lastError = null;
            }
            catch (HrdLogbook.LogException e)
            {
                lastError = e.Message;
            }
        }
        while (clock.Elapsed < ConfirmationTimeout);

        if (lastError is not null)
        {
            return new QsoLogOutcome.SentUnconfirmed($"Sent, but the log couldn't be checked: {lastError}");
        }
        var reason = !HrdLogbook.IsRunning
            ? "HRD Logbook isn't running"
            : HrdLogbook.Receiver() is { Enabled: false }
                ? "HRD's UDP9/ADIF receive is off"
                : !HrdLogbook.IsListening(port)
                    ? $"nothing is listening on UDP {port}"
                    : $"it didn't show up in the log within {ConfirmationTimeout.TotalSeconds:0} s";
        AppLog.Write($"Logbook: {qso.Call} not found in the HRD log: {reason}");
        return new QsoLogOutcome.SentUnconfirmed($"Sent, but {reason}");
    }
}

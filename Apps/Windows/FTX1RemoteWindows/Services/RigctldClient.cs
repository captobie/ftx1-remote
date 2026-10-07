using System.Net.Sockets;
using System.Text;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

public sealed class RigctldError : Exception
{
    public RigctldError(string message) : base(message) { }
}

/// C# port of Sources/FTX1Core/Networking/RigctldClient.swift's protocol
/// handling (get/set command shapes, level names, "currVFO" convention) —
/// see Apps/Windows/README.md's porting table. Not a line-for-line
/// translation: no actor isolation here, just a plain async lock, since
/// this app has no SwiftUI/actor equivalent to match.
///
/// Talks to rigctld's plain-text TCP protocol directly — this app connects
/// straight to the Pi's rigctld.service (see repo root CLAUDE.md's "Remote
/// rigctld (Option A)"), never through a Mac hub.
public sealed class RigctldClient : IAsyncDisposable
{
    /// rigctld's own keyword for "whichever VFO is active" — matches the
    /// Swift client's currentVFOArg. The Pi's rigctld runs with -o (per
    /// RigctldProcessController's doc comments), which requires *set*
    /// commands to name an explicit VFO rather than defaulting to the
    /// active one; "currVFO" satisfies that while still tracking whichever
    /// VFO is actually active.
    private const string CurrentVfoArg = "currVFO";

    private readonly string _host;
    private readonly int _port;
    private TcpClient? _tcpClient;
    private NetworkStream? _stream;
    private readonly StringBuilder _readBuffer = new();

    /// Guards each write+read round trip so two callers (the poll loop and
    /// a user-triggered set) can never interleave on the wire — same
    /// reasoning as RigctldClient.swift's roundTripBusy/roundTripWaiters.
    private readonly SemaphoreSlim _roundTripLock = new(1, 1);

    /// The last command written and when (UTC) — for MainWindow's stuck-poll
    /// watchdog, which logs them when a round trip never completes.
    public string LastCommand { get; private set; } = "";
    public DateTime LastCommandAt { get; private set; }

    public RigctldClient(string host, int port = 4532)
    {
        _host = host;
        _port = port;
    }

    public async Task ConnectAsync(TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        var effectiveTimeout = timeout ?? TimeSpan.FromSeconds(5);
        var client = new TcpClient { NoDelay = true };
        using var timeoutCts = new CancellationTokenSource(effectiveTimeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        try
        {
            await client.ConnectAsync(_host, _port, linkedCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested)
        {
            client.Dispose();
            throw new RigctldError($"Timed out connecting to {_host}:{_port}");
        }
        catch (Exception ex)
        {
            client.Dispose();
            throw new RigctldError($"Failed to connect to {_host}:{_port}: {ex.Message}");
        }

        _tcpClient = client;
        _stream = client.GetStream();
        _readBuffer.Clear();
    }

    public void Disconnect()
    {
        _stream?.Dispose();
        _tcpClient?.Dispose();
        _stream = null;
        _tcpClient = null;
    }

    public ValueTask DisposeAsync()
    {
        Disconnect();
        return ValueTask.CompletedTask;
    }

    /// How long a hamlib-verb reply may take before the round trip is
    /// abandoned. Longer than raw CAT's 1 s: these go through hamlib's own
    /// retries, over Tailscale in Remote mode. Without it, one reply that
    /// never comes held the round-trip lock forever and every later
    /// command queued behind it (2026-09-29: "m currVFO" on a memory
    /// channel after a swap).
    private static readonly TimeSpan ReplyTimeout = TimeSpan.FromSeconds(3);

    /// Sends a raw rigctld command (e.g. "f currVFO") and returns the
    /// single-line reply.
    public async Task<string> SendAsync(string command, CancellationToken cancellationToken = default)
    {
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteAsync(command, cancellationToken).ConfigureAwait(false);
            return await ReadReplyLineAsync(command, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// Sends a command that returns a fixed number of lines on success (e.g.
    /// "m currVFO" -> mode + passband). A failure comes back as a single
    /// "RPRT -n" line instead, which is thrown rather than waiting for the
    /// lines that will never follow.
    private async Task<string[]> QueryAsync(string command, int lines, CancellationToken cancellationToken)
    {
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteAsync(command, cancellationToken).ConfigureAwait(false);
            var result = new string[lines];
            for (var i = 0; i < lines; i++)
            {
                result[i] = await ReadReplyLineAsync(command, cancellationToken).ConfigureAwait(false);
                if (i == 0 && lines > 1 && result[0].StartsWith("RPRT ", StringComparison.Ordinal))
                {
                    throw new RigctldError($"'{command}' failed: {result[0]}");
                }
            }
            return result;
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// One reply line, bounded by ReplyTimeout. On timeout the connection
    /// is reset, since a late reply would otherwise be read as the answer
    /// to the next command — same recovery as SendRawCommandAsync. Caller
    /// holds the round-trip lock.
    private async Task<string> ReadReplyLineAsync(string command, CancellationToken cancellationToken)
    {
        using var timeoutCts = new CancellationTokenSource(ReplyTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        try
        {
            return await ReadLineAsync(linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            AppLog.Write($"rigctld: no reply to '{command}' within {ReplyTimeout.TotalSeconds:F0} s, reconnecting");
            Disconnect();
            try
            {
                await ConnectAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
            }
            catch (RigctldError ex)
            {
                AppLog.Write($"rigctld: reconnect failed: {ex.Message}");
            }
            throw new RigctldError($"No reply to '{command}'");
        }
    }

    public async Task<long> GetFrequencyAsync(CancellationToken cancellationToken = default)
    {
        var line = await SendAsync($"f {CurrentVfoArg}", cancellationToken).ConfigureAwait(false);
        if (!long.TryParse(line, out var hz))
        {
            throw new RigctldError($"Bad frequency reply: '{line}'");
        }
        return hz;
    }

    public async Task SetFrequencyAsync(long hz, CancellationToken cancellationToken = default)
    {
        _ = await SendAsync($"F {CurrentVfoArg} {hz}", cancellationToken).ConfigureAwait(false);
    }

    public async Task<RigMode?> GetModeAsync(CancellationToken cancellationToken = default)
    {
        var lines = await QueryAsync($"m {CurrentVfoArg}", 2, cancellationToken).ConfigureAwait(false);
        return RigModeExtensions.FromRawValue(lines[0]);
    }

    public async Task SetModeAsync(RigMode mode, CancellationToken cancellationToken = default)
    {
        _ = await SendAsync($"M {CurrentVfoArg} {mode.RawValue()} 0", cancellationToken).ConfigureAwait(false);
    }

    public async Task<bool> GetPttAsync(CancellationToken cancellationToken = default)
    {
        var line = await SendAsync($"t {CurrentVfoArg}", cancellationToken).ConfigureAwait(false);
        // hamlib: 0 off, 1 on, 2 on (mic), 3 on (data). The FTX-1 reports
        // its TX2 state as 3, so any nonzero value is transmitting.
        return int.TryParse(line, out var value) && value != 0;
    }

    public async Task SetPttAsync(bool on, CancellationToken cancellationToken = default)
    {
        _ = await SendAsync($"T {CurrentVfoArg} {(on ? 1 : 0)}", cancellationToken).ConfigureAwait(false);
    }

    /// Raw CAT "MX" (MOX), same as CommandQueue.swift's .setMox. Set-only,
    /// no reply. Used by the force-unkey when Enable Transmit is switched
    /// off and by the MENU grid's MOX button; an "on" caller must pass
    /// TransmitGate first.
    public Task SetMoxAsync(bool on, CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync(on ? "MX1" : "MX0", cancellationToken);

    /// Reads a rigctld level (e.g. "SWR", "RFPOWER_METER_WATTS",
    /// "RFPOWER"). Returns null rather than throwing when the rig/backend
    /// doesn't support the requested level — rigctld reports that as an
    /// "RPRT -N" line, which isn't parseable as a number, matching
    /// RigctldClient.swift's getLevel(_:).
    public async Task<double?> GetLevelAsync(string name, CancellationToken cancellationToken = default)
    {
        var line = await SendAsync($"l {CurrentVfoArg} {name}", cancellationToken).ConfigureAwait(false);
        return double.TryParse(line, out var value) ? value : null;
    }

    /// RFPOWER setting, 0.0-1.0 relative — matches CommandQueue.apply's
    /// .setPowerLevel case ("L currVFO RFPOWER <level:F3>").
    public async Task SetPowerLevelAsync(double level, CancellationToken cancellationToken = default)
    {
        _ = await SendAsync($"L {CurrentVfoArg} RFPOWER {level:F3}", cancellationToken).ConfigureAwait(false);
    }

    /// MAIN's frequency from raw "FA", whichever side is active. The poll
    /// reads each box by side (2026-10-06, like the Mac's fast tier):
    /// "f currVFO"/"m currVFO" and GetSecondaryFrequencyAsync follow hamlib's
    /// active VFO, which is SUB whenever "VS"/"FT" is (TX:SUB, or a SUB
    /// memory scan) — then the two boxes traded places.
    public async Task<long> GetMainFrequencyAsync(CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync("FA", cancellationToken: cancellationToken).ConfigureAwait(false);
        var digits = reply.StartsWith("FA", StringComparison.Ordinal)
            ? new string(reply.Skip(2).TakeWhile(char.IsAsciiDigit).ToArray())
            : "";
        if (!long.TryParse(digits, out var hz))
        {
            throw new RigctldError($"Bad FA reply: '{reply}'");
        }
        return hz;
    }

    /// SUB's frequency ("f Sub", explicitly — see GetMainFrequencyAsync).
    /// It read 0 or a wrong ~51 MHz value while MAIN sat on a 6 m channel
    /// in the 2026-10-06 probes (as did raw "FB"); the memory scan reads
    /// SUB's channel from its "MR" entry for that reason.
    public async Task<long> GetSubFrequencyAsync(CancellationToken cancellationToken = default)
    {
        var line = await SendAsync("f Sub", cancellationToken).ConfigureAwait(false);
        if (!long.TryParse(line, out var hz))
        {
            throw new RigctldError($"Bad sub-frequency reply: '{line}'");
        }
        return hz;
    }

    /// Raw "RI0" (RADIO INFORMATION), parsed — see RadioInformation.
    public async Task<RadioInformation?> GetRadioInformationAsync(CancellationToken cancellationToken = default) =>
        RadioInformation.Parse(await SendRawCommandAsync("RI0", cancellationToken: cancellationToken).ConfigureAwait(false));

    /// Starts or stops the rig's own scan on one side: raw "SC<side><n>",
    /// n 0 off, 1 up, 2 down (CommandQueue.swift's .setMemoryScan). In
    /// Memory mode it's a memory scan. A stop with either side's P1 stops
    /// both sides' scans; starting one moves the rig's TX/RX side ("VS",
    /// the same setting as "FT") to that side. All rig-confirmed 2026-10-06.
    public Task SetMemoryScanAsync(bool sub, int direction, CancellationToken cancellationToken = default) =>
        SetRawIntAsync(sub ? "SC1" : "SC0", direction, 1, cancellationToken);

    /// The side "SC;" last told to scan ("SC11;" → true), for a scan the
    /// app didn't start. Null for an odd reply.
    public async Task<bool?> GetMemoryScanSideAsync(CancellationToken cancellationToken = default) =>
        await GetRawDigitAsync("SC", cancellationToken).ConfigureAwait(false) is { } p1 ? p1 == 1 : null;

    public async Task<long> GetSecondaryFrequencyAsync(CancellationToken cancellationToken = default)
    {
        var currentVfo = await SendAsync("v", cancellationToken).ConfigureAwait(false);
        var otherVfo = currentVfo == "Sub" ? "Main" : "Sub";
        var line = await SendAsync($"f {otherVfo}", cancellationToken).ConfigureAwait(false);
        if (!long.TryParse(line, out var hz))
        {
            throw new RigctldError($"Bad secondary-frequency reply: '{line}'");
        }
        return hz;
    }

    /// Writes the frequency of whichever VFO isn't currently active, then
    /// verifies the active VFO didn't move and switches back if it did —
    /// same defensive shape as RigctldClient.swift's
    /// setSecondaryFrequency(_:), since it isn't confirmed on real
    /// hardware whether "F <VFO> <hz>" on a non-active VFO can shift which
    /// one is active as a side effect.
    public async Task SetSecondaryFrequencyAsync(long hz, CancellationToken cancellationToken = default)
    {
        var currentVfo = await SendAsync("v", cancellationToken).ConfigureAwait(false);
        var otherVfo = currentVfo == "Sub" ? "Main" : "Sub";
        _ = await SendAsync($"F {otherVfo} {hz}", cancellationToken).ConfigureAwait(false);
        var vfoAfterSet = await SendAsync("v", cancellationToken).ConfigureAwait(false);
        if (vfoAfterSet != currentVfo)
        {
            _ = await SendAsync($"V {currentVfo}", cancellationToken).ConfigureAwait(false);
        }
    }

    /// Swaps the MAIN-side and SUB-side VFO contents, like the rig's
    /// front-panel swap button, via the raw CAT "SV" (SWAP VFO) command,
    /// ported from RigctldClient.swift's swapActiveVFO(). This used to send
    /// hamlib's "V <other VFO>", but that maps to the CAT manual's "VS" (VFO
    /// SELECT) on this rig, which changes which side is *active* instead of
    /// swapping the two (confirmed on hardware 2026-09-17, see the Swift
    /// doc comment). Set-only, no reply.
    public Task SwapActiveVfoAsync(CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync("SV", cancellationToken);

    /// Raw CAT passthrough via rigctld's "W" command, for FTX-1 settings
    /// hamlib has no verb for. Port of RigctldClient.swift's
    /// sendRawCommand: "W <cmd>; ;" returns the rig's own reply (e.g.
    /// "FR00;"), terminated by "\n" or "\0" depending on hamlib's internal
    /// ";" counting, so both are accepted. If the rig doesn't answer,
    /// rigctld writes nothing back at all, so the wait is bounded by
    /// <paramref name="timeout"/> (default 1 s, the Swift client's value).
    /// On timeout the connection is reset, because a read abandoned
    /// mid-flight would leave a late reply in the stream for the next
    /// command. The next call then works again, or fails with the real
    /// reason if the Pi is gone.
    public async Task<string> SendRawCommandAsync(string cmd, TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteAsync($"W {cmd}; ;", cancellationToken).ConfigureAwait(false);
            using var timeoutCts = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(1));
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
            try
            {
                return await ReadLineAsync(linked.Token, acceptNul: true).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                AppLog.Write($"rigctld: no reply to raw {cmd} within {(timeout ?? TimeSpan.FromSeconds(1)).TotalSeconds:F1} s, reconnecting");
                Disconnect();
                try
                {
                    await ConnectAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                }
                catch (RigctldError ex)
                {
                    AppLog.Write($"rigctld: reconnect failed: {ex.Message}");
                }
                throw new RigctldError($"No reply to raw command {cmd}");
            }
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// For Set-only raw commands the rig doesn't answer (e.g. "SV") —
    /// RigctldClient.swift's sendRawCommandFireAndForget, whose doc comment
    /// has the measurements (Pi, 2026-10-06). Sent as "W <cmd>; 0" (expect
    /// 0 reply bytes): with "; ;" rigctld waits out its serial timeout for
    /// an answer a set never gets (~2.1 s against the Pi) and holds every
    /// later command behind it; with "; 0" it answers an empty "\0" reply
    /// at once (~55 ms) and still applies the set. A rejected set's "?;" is
    /// flushed by rigctld, not left for the next read.
    public async Task SendRawFireAndForgetAsync(string cmd, CancellationToken cancellationToken = default)
    {
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteRawSetAsync(cmd, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// The body of SendRawFireAndForgetAsync, for callers that already hold
    /// the round-trip lock: writes "W <cmd>; 0" and reads rigctld's empty
    /// reply, so it can't be taken for the next command's answer. An error
    /// reply ("RPRT -N") is logged, not thrown. No reply within 1 s resets
    /// the connection, like SendRawCommandAsync.
    private async Task WriteRawSetAsync(string cmd, CancellationToken cancellationToken)
    {
        await WriteAsync($"W {cmd}; 0", cancellationToken).ConfigureAwait(false);
        using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        string reply;
        try
        {
            reply = await ReadLineAsync(linked.Token, acceptNul: true).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            AppLog.Write($"rigctld: no reply to raw set {cmd} within 1.0 s, reconnecting");
            Disconnect();
            try
            {
                await ConnectAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
            }
            catch (RigctldError ex)
            {
                AppLog.Write($"rigctld: reconnect failed: {ex.Message}");
            }
            throw new RigctldError($"No reply to raw set {cmd}");
        }
        if (reply.StartsWith("RPRT", StringComparison.Ordinal))
        {
            AppLog.Write($"rigctld: raw set {cmd} failed: {reply}");
        }
    }

    /// Reads a "<CMD><digits>;" reply as an int, e.g. "FR" -> "FR01;" -> 1.
    /// Returns null if the reply isn't for this command. Same shape as the
    /// Swift client's getRawInt.
    public async Task<int?> GetRawIntAsync(string cmd, CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync(cmd, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith(cmd, StringComparison.Ordinal))
        {
            return null;
        }
        var digits = new string(reply.Skip(cmd.Length).TakeWhile(char.IsAsciiDigit).ToArray());
        return int.TryParse(digits, out var value) ? value : null;
    }

    /// Raw "RM" (READ METER): P1 picks the meter (1 S main, 2 S sub, 3 COMP,
    /// 4 ALC, 5 PO, 6 SWR, 7 IDD, 8 VDD), and the reply's next three digits
    /// are its 0-255 value. Port of the Swift client's getMeterReading.
    public async Task<int?> GetMeterReadingAsync(int p1, CancellationToken cancellationToken = default)
    {
        var cmd = $"RM{p1}";
        var reply = await SendRawCommandAsync(cmd, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith(cmd, StringComparison.Ordinal))
        {
            return null;
        }
        var digits = new string(reply.Skip(cmd.Length).Take(3).TakeWhile(char.IsAsciiDigit).ToArray());
        return int.TryParse(digits, out var value) ? value : null;
    }

    /// Whether a receiver (false MAIN, true SUB) is in C4FM, from raw
    /// "MD0"/"MD1": P2 "H"/"I" are C4FM (RigState.swift's
    /// RigMode(catModeCode:)). hamlib's "m" can't tell — it answers "RPRT -8"
    /// in C4FM — and this app's RigMode has no C4FM. Null if the reply
    /// isn't an "MD" one.
    public async Task<bool?> IsC4fmAsync(bool sub, CancellationToken cancellationToken = default) =>
        await GetModeCodeAsync(sub, cancellationToken).ConfigureAwait(false) is { } code ? code is 'H' or 'I' : null;

    /// The P2 mode character of raw "MD0"/"MD1" (the Swift getModeCode),
    /// decoded by RigModeExtensions.FromCatModeCode. Null if the reply isn't
    /// an "MD" one.
    public async Task<char?> GetModeCodeAsync(bool sub, CancellationToken cancellationToken = default)
    {
        var cmd = sub ? "MD1" : "MD0";
        var reply = await SendRawCommandAsync(cmd, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith(cmd, StringComparison.Ordinal) || reply.Length <= cmd.Length)
        {
            return null;
        }
        return reply[cmd.Length];
    }

    /// IF SHIFT, "IS<p1>0" + sign + 4-digit magnitude ("IS00-0240;") —
    /// signed, so GetRawIntAsync can't parse it. The Swift getIFShiftHz.
    public async Task<int?> GetIFShiftHzAsync(int p1, CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync($"IS{p1}", cancellationToken: cancellationToken).ConfigureAwait(false);
        var prefix = $"IS{p1}0";
        if (!reply.StartsWith(prefix, StringComparison.Ordinal))
        {
            return null;
        }
        var value = new string(reply.Skip(prefix.Length).TakeWhile(c => char.IsAsciiDigit(c) || c is '+' or '-').ToArray());
        return int.TryParse(value, System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture, out var hz) ? hz : null;
    }

    /// Always an explicit sign and a zero-padded 4-digit magnitude:
    /// "IS00+0240", "IS00-1200", "IS00+0000". Pass a value already on the
    /// 20 Hz grid (IFShift.Snapped).
    public Task SetIFShiftHzAsync(int p1, int hz, CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync($"IS{p1}0{(hz < 0 ? "-" : "+")}{Math.Abs(hz):0000}", cancellationToken);

    /// Reads a "<CMD><0|1>;" on/off setting, e.g. "VX" -> "VX1;" -> true.
    /// Looks only at the first character after the prefix, so it must not
    /// be used for on/off states carried in a multi-digit field (the Swift
    /// client's getRawBool, same trap noted in the repo's CLAUDE.md).
    public async Task<bool?> GetRawBoolAsync(string cmd, CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync(cmd, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith(cmd, StringComparison.Ordinal) || reply.Length <= cmd.Length)
        {
            return null;
        }
        return reply[cmd.Length] switch
        {
            '1' => true,
            '0' => false,
            _ => null,
        };
    }

    public Task SetRawBoolAsync(string cmd, bool on, CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync($"{cmd}{(on ? 1 : 0)}", cancellationToken);

    /// "<CMD><value zero-padded to digits>;", e.g. ("MG", 50, 3) -> "MG050".
    public Task SetRawIntAsync(string cmd, int value, int digits, CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync(cmd + value.ToString().PadLeft(digits, '0'), cancellationToken);

    /// The first digit after the prefix only, for replies that pack several
    /// fields together (e.g. "SS01" PEAK answers "SS01" + P3..P7) — the
    /// Swift client's getRawDigit.
    public async Task<int?> GetRawDigitAsync(string cmd, CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync(cmd, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith(cmd, StringComparison.Ordinal) || reply.Length <= cmd.Length || !char.IsAsciiDigit(reply[cmd.Length]))
        {
            return null;
        }
        return reply[cmd.Length] - '0';
    }

    /// One digit followed by the fixed "0" fields the manual documents after
    /// it, e.g. ("SS01", 2, 4) -> "SS0120000" — the Swift client's
    /// setRawPackedDigit.
    public Task SetRawPackedDigitAsync(string cmd, int digit, int trailingZeros, CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync($"{cmd}{digit}{new string('0', trailingZeros)}", cancellationToken);

    /// "SS" LEVEL (P2=4): a signed "+15.0"-style value, -30.0 to +30.0 dB.
    /// Only the leading sign/digit/"." run is parsed, so the reply's own ";"
    /// terminator can't break it (the bug the Swift getSpectrumScopeLevel's
    /// doc comment describes).
    public async Task<double?> GetSpectrumScopeLevelAsync(CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync("SS04", cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith("SS04", StringComparison.Ordinal))
        {
            return null;
        }
        var value = new string(reply.Skip(4).TakeWhile(c => char.IsAsciiDigit(c) || c is '.' or '+' or '-').ToArray());
        return double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var db) ? db : null;
    }

    /// Always an explicit sign plus a zero-padded "XX.X" magnitude, e.g.
    /// -8.5 -> "SS04-08.5". Invariant culture so a comma-decimal locale
    /// can't send "08,5".
    public Task SetSpectrumScopeLevelAsync(double db, CancellationToken cancellationToken = default)
    {
        var sign = db < 0 ? "-" : "+";
        var magnitude = Math.Abs(db).ToString("00.0", System.Globalization.CultureInfo.InvariantCulture);
        return SendRawFireAndForgetAsync($"SS04{sign}{magnitude}", cancellationToken);
    }

    /// Tuner on/off: P3 of "AC"'s answer ("AC" + P1 + P2 + P3). The read
    /// takes no parameters, unlike the set ("AC10x") — see the Swift
    /// getTunerEnabled.
    public async Task<bool?> GetTunerEnabledAsync(CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync("AC", cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith("AC", StringComparison.Ordinal) || reply.Length < 5)
        {
            return null;
        }
        return reply[4] == '1';
    }

    /// "DA" (DIMMER): fixed "00", then contrast, TFT brightness (the MENU
    /// grid's DIMMER) and LED brightness, two digits each.
    public async Task<(int Contrast, int Brightness, int LedBrightness)?> GetDisplaySettingsAsync(CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync("DA", cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith("DA", StringComparison.Ordinal))
        {
            return null;
        }
        var digits = new string(reply.Skip(2).TakeWhile(char.IsAsciiDigit).ToArray());
        if (digits.Length < 8)
        {
            return null;
        }
        return (int.Parse(digits[2..4]), int.Parse(digits[4..6]), int.Parse(digits[6..8]));
    }

    /// "DA" can only be set as a whole triple — callers changing one field
    /// read the other two first (CommandQueue.swift's .setDisplayContrast).
    public Task SetDisplaySettingsAsync(int contrast, int brightness, int ledBrightness, CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync($"DA00{contrast:00}{brightness:00}{ledBrightness:00}", cancellationToken);

    /// One "EX" (MENU) item addressed by P1/P2/P3, returning its raw P4 —
    /// the Swift getMenuItem. Used here for the fixed-address items with no
    /// mnemonic of their own (HF ANT SELECT); Deep Settings will use it too.
    public async Task<string?> GetMenuItemAsync(int p1, int p2, int p3, CancellationToken cancellationToken = default)
    {
        var prefix = $"EX{p1:00}{p2:00}{p3:00}";
        var reply = await SendRawCommandAsync(prefix, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith(prefix, StringComparison.Ordinal))
        {
            return null;
        }
        return reply[prefix.Length..].TrimEnd(';');
    }

    public Task SetMenuItemAsync(int p1, int p2, int p3, string rawValue, CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync($"EX{p1:00}{p2:00}{p3:00}{rawValue}", cancellationToken);

    /// "VM" (VFO / MEMORY CHANNEL) P2 for Main (P1 0) or Sub (P1 1): 00 VFO,
    /// 11 Memory, other values the rig's PMS/5 MHz/EMG sub-modes — see
    /// RigState.swift's VFOMemoryMode.
    public Task<int?> GetVfoMemoryModeAsync(bool sub, CancellationToken cancellationToken = default) =>
        GetRawIntAsync(sub ? "VM1" : "VM0", cancellationToken);

    /// Main's VFO/Memory switch — CommandQueue.swift's .setVFOMemoryMode.
    /// Entering Memory mode only takes effect if "MC0" is written right
    /// before "VM011", even with the channel it already holds (found by
    /// live probing on the rig, undocumented), so the tracked channel
    /// (1 if none) is re-asserted first. Leaving it has no such
    /// precondition, but leaves Main parked on the channel's frequency/mode
    /// — the caller restores the VFO afterwards (MainWindow.SetVfoMemoryModeAsync).
    public async Task SetVfoMemoryModeAsync(bool memory, CancellationToken cancellationToken = default)
    {
        if (!memory)
        {
            await SetRawIntAsync("VM0", 0, digits: 2, cancellationToken).ConfigureAwait(false);
            return;
        }
        int channel;
        try
        {
            channel = await GetRawIntAsync("MC0", cancellationToken).ConfigureAwait(false) ?? 1;
        }
        catch (RigctldError)
        {
            channel = 1;
        }
        // Both writes under one lock hold, so a poll read can't land
        // between them and break "immediately before".
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteRawSetAsync($"MC0{channel:00000}", cancellationToken).ConfigureAwait(false);
            await WriteRawSetAsync("VM011", cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// "MC" (MEMORY CHANNEL) for Main (P1 0) or Sub (P1 1): the 5-digit
    /// channel number. Readable in VFO mode too (the channel Memory mode
    /// would recall).
    public Task<int?> GetMemoryChannelAsync(bool sub, CancellationToken cancellationToken = default) =>
        GetRawIntAsync(sub ? "MC1" : "MC0", cancellationToken);

    public Task SetMemoryChannelAsync(int channel, CancellationToken cancellationToken = default) =>
        SetRawIntAsync("MC0", channel, digits: 5, cancellationToken);

    public Task SetSubMemoryChannelAsync(int channel, CancellationToken cancellationToken = default) =>
        SetRawIntAsync("MC1", channel, digits: 5, cancellationToken);

    /// Sub's channel up/down: "CH" has no side selector, so this steps
    /// through "MC1" like CommandQueue.swift's .stepSubMemoryChannel — the
    /// rig ignores an "MC" set to a blank channel, so each candidate is set
    /// and read back until one sticks (that skips blanks). Up wraps past the
    /// last programmed channel to the first; down doesn't.
    public async Task StepSubMemoryChannelAsync(bool up, CancellationToken cancellationToken = default)
    {
        const int scanLimit = 30;
        if (await GetRawIntAsync("MC1", cancellationToken).ConfigureAwait(false) is not { } current)
        {
            throw new RigctldError("No reply to MC1");
        }
        var step = up ? 1 : -1;
        var candidates = new List<int>();
        for (var c = current + step; c is >= 1 and <= 999 && candidates.Count < scanLimit; c += step)
        {
            candidates.Add(c);
        }
        if (up)
        {
            candidates.AddRange(Enumerable.Range(1, Math.Max(0, current - 1)).Take(scanLimit));
        }
        foreach (var candidate in candidates)
        {
            await SetRawIntAsync("MC1", candidate, digits: 5, cancellationToken).ConfigureAwait(false);
            if (await GetRawIntAsync("MC1", cancellationToken).ConfigureAwait(false) == candidate)
            {
                break;
            }
        }
    }

    /// "CH" (CHANNEL UP/DOWN): CH0 up, CH1 down. It documents no MAIN/SUB
    /// selector; the Mac sends the same thing (CommandQueue.swift's
    /// .stepMemoryChannel).
    public Task StepMemoryChannelAsync(bool up, CancellationToken cancellationToken = default) =>
        SendRawFireAndForgetAsync(up ? "CH0" : "CH1", cancellationToken);

    /// A channel's TAG (name, up to 12 characters) via "MT" + 5-digit
    /// channel, whose reply pads it with spaces. Null for an untagged
    /// channel — the Swift getMemoryChannelTag.
    public async Task<string?> GetMemoryChannelTagAsync(int channel, CancellationToken cancellationToken = default)
    {
        var prefix = $"MT{channel:00000}";
        var reply = await SendRawCommandAsync(prefix, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!reply.StartsWith(prefix, StringComparison.Ordinal))
        {
            return null;
        }
        var tag = reply[prefix.Length..].TrimEnd(';').Trim();
        return tag.Length == 0 ? null : tag;
    }

    /// One memory channel's contents ("MR") plus its tag ("MT", read only
    /// for a programmed channel) — the Swift readMemoryChannel. Null for a
    /// blank channel, which answers "MR" with "?;" right away. A failed
    /// tag read leaves the tag null rather than dropping the channel.
    public async Task<MemoryChannelEntry?> ReadMemoryChannelAsync(int channel, CancellationToken cancellationToken = default)
    {
        var reply = await SendRawCommandAsync($"MR{channel:00000}", cancellationToken: cancellationToken).ConfigureAwait(false);
        if (MemoryChannelEntry.Parse(reply) is not { } entry || entry.Channel != channel)
        {
            return null;
        }
        try
        {
            entry.Tag = await GetMemoryChannelTagAsync(channel, cancellationToken).ConfigureAwait(false);
        }
        catch (RigctldError)
        {
        }
        return entry;
    }

    /// The memory list's MAIN/SUB buttons — CommandQueue.swift's
    /// .recallMemoryChannel: select the channel with "MC", then enter
    /// Memory mode with "VM…11" unless that side already reads 11. Writing
    /// "MC" right before "VM" is also the undocumented precondition
    /// SetVfoMemoryModeAsync re-asserts the current channel for — here it's
    /// the new one, and both writes go out under one lock hold for the same
    /// reason as there.
    public async Task RecallMemoryChannelAsync(int channel, bool sub, CancellationToken cancellationToken = default)
    {
        var p1 = sub ? "1" : "0";
        int? mode;
        try
        {
            mode = await GetRawIntAsync("VM" + p1, cancellationToken).ConfigureAwait(false);
        }
        catch (RigctldError)
        {
            mode = null;
        }
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteRawSetAsync($"MC{p1}{channel:00000}", cancellationToken).ConfigureAwait(false);
            if (mode != 11)
            {
                await WriteRawSetAsync($"VM{p1}11", cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// Writes CW TEXT keyer memory <paramref name="slot"/> (1-5) with "KM"
    /// and returns what the rig stored, without the "}" end marker it
    /// appends itself — RigctldClient.swift's writeKeyerMemory, whose doc
    /// comment has what was probed on the rig (2026-10-02): rigctld's "W"
    /// splits on whitespace, so the write goes through lowercase "w", which
    /// passes the line whole but then waits out rigctld's own timeout
    /// (~2 s) for a reply an accepted write never gets; a rejected one (over
    /// 50 characters) answers "?;" at once. So a "KM&lt;slot&gt;" read goes
    /// out in the same write, and its answer both ends the wait and
    /// confirms what was stored. <paramref name="text"/> must not contain
    /// ";" or a newline.
    public async Task<string> WriteKeyerMemoryAsync(int slot, string text, CancellationToken cancellationToken = default)
    {
        var read = $"KM{slot}";
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteAsync($"w {read}{text};\nW {read}; ;", cancellationToken).ConfigureAwait(false);
            using var timeoutCts = new CancellationTokenSource(KeyerMemoryWriteTimeout);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
            var rejected = false;
            string reply;
            try
            {
                while (true)
                {
                    var line = await ReadLineAsync(linked.Token, acceptNul: true).ConfigureAwait(false);
                    if (line.StartsWith(read, StringComparison.Ordinal))
                    {
                        reply = line;
                        break;
                    }
                    if (line.StartsWith('?'))
                    {
                        rejected = true;
                    }
                }
            }
            catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                AppLog.Write($"rigctld: no reply to keyer memory write {read} within {KeyerMemoryWriteTimeout.TotalSeconds:F0} s, reconnecting");
                Disconnect();
                try
                {
                    await ConnectAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                }
                catch (RigctldError ex)
                {
                    AppLog.Write($"rigctld: reconnect failed: {ex.Message}");
                }
                throw new RigctldError("rigctld didn't answer the keyer memory write in time. If this keeps happening, the rig may be off or its USB connection may have dropped.");
            }
            if (rejected)
            {
                throw new RigctldError("The rig rejected the keyer memory write.");
            }
            var stored = reply[read.Length..];
            if (stored.EndsWith(';'))
            {
                stored = stored[..^1];
            }
            if (stored.EndsWith('}'))
            {
                stored = stored[..^1];
            }
            return stored;
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// The running rigctld's Hamlib version (e.g. "Hamlib 4.7.2
    /// 2026-06-21T13:07:37Z SHA=40f63488f 32-bit"), from the "Hamlib
    /// version:" line near the top of "\dump_caps" — rigctld has no version
    /// verb. Port of RigctldClient.swift's readHamlibVersion: the dump is
    /// ~2300 lines, so this reads only up to that line and disconnects
    /// rather than draining the rest. For a short-lived client of its own
    /// (the Settings dialog's version box), never the main one; a timeout
    /// just disconnects, without ReadReplyLineAsync's reconnect.
    public async Task<string?> ReadHamlibVersionAsync(CancellationToken cancellationToken = default)
    {
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteAsync("\\dump_caps", cancellationToken).ConfigureAwait(false);
            using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
            for (var i = 0; i < 20; i++)
            {
                var line = await ReadLineAsync(linked.Token).ConfigureAwait(false);
                if (line.StartsWith("RPRT", StringComparison.Ordinal))
                {
                    throw new RigctldError($"'\\dump_caps' failed: {line}");
                }
                if (line.StartsWith("Hamlib version:", StringComparison.Ordinal))
                {
                    return line["Hamlib version:".Length..].Trim();
                }
            }
            return null;
        }
        finally
        {
            Disconnect();
            _roundTripLock.Release();
        }
    }

    /// The write itself takes ~2 s (see WriteKeyerMemoryAsync), so this is
    /// the Mac's 6 s, not raw CAT's 1 s.
    private static readonly TimeSpan KeyerMemoryWriteTimeout = TimeSpan.FromSeconds(6);

    private async Task WriteAsync(string command, CancellationToken cancellationToken)
    {
        if (_stream is null)
        {
            throw new RigctldError("Not connected");
        }
        // Every round trip reads its whole reply before releasing the lock,
        // so anything still buffered now is stale. Drop it, as
        // RigctldClient.swift's write() does.
        _readBuffer.Clear();
        LastCommand = command;
        LastCommandAt = DateTime.UtcNow;
        var bytes = Encoding.UTF8.GetBytes(command + "\n");
        await _stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
    }

    private readonly byte[] _recvBuffer = new byte[4096];

    private async Task<string> ReadLineAsync(CancellationToken cancellationToken, bool acceptNul = false)
    {
        while (true)
        {
            var buffered = _readBuffer.ToString();
            var newlineIndex = acceptNul ? buffered.IndexOfAny(['\n', '\0']) : buffered.IndexOf('\n');
            if (newlineIndex >= 0)
            {
                var line = buffered[..newlineIndex].TrimEnd('\r');
                _readBuffer.Remove(0, newlineIndex + 1);
                return line.Trim();
            }

            if (_stream is null)
            {
                throw new RigctldError("Not connected");
            }
            var read = await _stream.ReadAsync(_recvBuffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new RigctldError("Connection closed by remote end");
            }
            _readBuffer.Append(Encoding.UTF8.GetString(_recvBuffer, 0, read));
        }
    }
}

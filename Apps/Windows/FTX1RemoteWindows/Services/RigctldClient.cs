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

    /// Sends a raw rigctld command (e.g. "f currVFO") and returns the
    /// single-line reply.
    public async Task<string> SendAsync(string command, CancellationToken cancellationToken = default)
    {
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteAsync(command, cancellationToken).ConfigureAwait(false);
            return await ReadLineAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// Sends a command that always returns a fixed number of lines (e.g.
    /// "m currVFO" -> mode + passband).
    private async Task<string[]> QueryAsync(string command, int lines, CancellationToken cancellationToken)
    {
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteAsync(command, cancellationToken).ConfigureAwait(false);
            var result = new string[lines];
            for (var i = 0; i < lines; i++)
            {
                result[i] = await ReadLineAsync(cancellationToken).ConfigureAwait(false);
            }
            return result;
        }
        finally
        {
            _roundTripLock.Release();
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
    /// no reply. Only the off direction is used so far (the force-unkey
    /// when Enable Transmit is switched off); an "on" caller must pass
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
                Disconnect();
                try
                {
                    await ConnectAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                }
                catch (RigctldError)
                {
                }
                throw new RigctldError($"No reply to raw command {cmd}");
            }
        }
        finally
        {
            _roundTripLock.Release();
        }
    }

    /// For Set-only raw commands the rig doesn't answer (e.g. "SV"). Any
    /// stray bytes that come back anyway are dropped by the next
    /// WriteAsync.
    public async Task SendRawFireAndForgetAsync(string cmd, CancellationToken cancellationToken = default)
    {
        await _roundTripLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await WriteAsync($"W {cmd}; ;", cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _roundTripLock.Release();
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

    private async Task WriteAsync(string command, CancellationToken cancellationToken)
    {
        if (_stream is null)
        {
            throw new RigctldError("Not connected");
        }
        // Every ordinary round trip reads its whole reply before releasing
        // the lock, so anything still buffered now is stale, e.g. from a
        // fire-and-forget raw command. Drop it, as RigctldClient.swift's
        // write() does.
        _readBuffer.Clear();
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

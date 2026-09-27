using System.ComponentModel;
using System.Diagnostics;

namespace FTX1RemoteWindows.Services;

/// Launches hamlib's rigctld.exe on this PC for Local mode — the Windows
/// counterpart of Apps/Mac/FTX1RemoteMac/RigctldProcessController.swift.
/// The rest of the app still only talks to rigctld over TCP (localhost
/// here, the Pi in Remote mode); this class just makes sure one is there.
///
/// Like the Mac's, it adopts an already-running, responsive rigctld on the
/// port instead of replacing it — another client (e.g. WSJT-X) may be
/// mid-session with it — and only kills one that's listening but not
/// answering. An adopted rigctld is never stopped by Stop().
public sealed class RigctldProcessController
{
    public sealed record Configuration(
        string BinaryPath,
        int ModelNumber,
        string ComPort,
        int BaudRate,
        string Host,
        int Port);

    public enum StartResult
    {
        /// We spawned rigctld; it may still be opening the serial port and
        /// binding its TCP listener, so the first connects can fail.
        Spawned,
        /// A responsive rigctld was already listening; left as-is.
        Adopted,
    }

    private Process? _process;

    /// Last few stderr lines from the rigctld we spawned — shown when it
    /// exits unexpectedly, since hamlib explains a bad COM port / baud rate
    /// there (e.g. "rig_open: error = IO error") and nowhere else.
    private readonly Queue<string> _stderrTail = new();
    private const int StderrTailLines = 5;

    /// Raised (on a thread-pool thread) when a rigctld we spawned exits
    /// without Stop() having been called. The argument is a user-facing
    /// description including rigctld's last stderr output.
    public event Action<string>? UnexpectedExit;

    public bool IsOwnedProcessRunning => _process is { HasExited: false };

    /// Throws RigctldError when rigctld can't be started (missing binary,
    /// no COM port). Doesn't wait for the spawned rigctld to be ready —
    /// callers retry their connect for a short grace period, same as the
    /// Mac's HubService.connectRigctld(isFreshStart: true).
    public async Task<StartResult> StartAsync(Configuration config)
    {
        if (_process is not null)
        {
            return StartResult.Spawned;
        }

        switch (await ProbeAsync(config.Host, config.Port).ConfigureAwait(false))
        {
            case ProbeResult.Healthy:
                return StartResult.Adopted;
            case ProbeResult.Unresponsive:
                await KillStaleRigctldAsync().ConfigureAwait(false);
                break;
            case ProbeResult.NothingListening:
                break;
        }

        if (config.BinaryPath.Length == 0 || !File.Exists(config.BinaryPath))
        {
            throw new RigctldError(config.BinaryPath.Length == 0
                ? "Set the path to rigctld.exe first."
                : $"rigctld.exe not found at {config.BinaryPath}");
        }
        if (config.ComPort.Length == 0)
        {
            throw new RigctldError("Pick the radio's COM port first.");
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = config.BinaryPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
        };
        // Same arguments as the Mac's RigctldProcessController — see its
        // comments for why each is there. In short: -T pins the listen
        // address so the IPv4 client and rigctld agree; -o makes VFO
        // arguments actually count (RigctldClient passes "currVFO" and
        // "Main"/"Sub"); -C shrinks hamlib's serial timeout/retry so a CAT
        // command that gets no reply fails fast instead of holding
        // rigctld's global lock for ~4s.
        foreach (var arg in new[]
        {
            "-m", config.ModelNumber.ToString(),
            "-r", config.ComPort,
            "-s", config.BaudRate.ToString(),
            "-t", config.Port.ToString(),
            "-T", config.Host,
            "-o",
            "-C", "timeout=300,retry=0",
        })
        {
            startInfo.ArgumentList.Add(arg);
        }

        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        lock (_stderrTail)
        {
            _stderrTail.Clear();
        }
        process.ErrorDataReceived += (_, e) => RecordStderr(e.Data);
        // rigctld prints little to stdout, but an unread redirected pipe
        // can still fill and block it, so drain it too.
        process.OutputDataReceived += (_, _) => { };
        process.Exited += (_, _) => OnExited(process);

        try
        {
            process.Start();
        }
        catch (Win32Exception ex)
        {
            process.Dispose();
            throw new RigctldError($"Couldn't start rigctld: {ex.Message}");
        }
        process.BeginErrorReadLine();
        process.BeginOutputReadLine();
        _process = process;
        return StartResult.Spawned;
    }

    /// Stops the rigctld we spawned, if any. An adopted one is left
    /// running for whoever else is using it.
    public void Stop()
    {
        var process = _process;
        _process = null;
        if (process is null)
        {
            return;
        }
        try
        {
            if (!process.HasExited)
            {
                process.Kill();
                process.WaitForExit(2000);
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or Win32Exception)
        {
            // Already gone.
        }
        process.Dispose();
    }

    /// Last stderr lines from the spawned rigctld, for connect-failure
    /// messages during the startup grace period.
    public string StderrTail()
    {
        lock (_stderrTail)
        {
            return string.Join(" / ", _stderrTail);
        }
    }

    private void RecordStderr(string? line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return;
        }
        lock (_stderrTail)
        {
            _stderrTail.Enqueue(line.Trim());
            while (_stderrTail.Count > StderrTailLines)
            {
                _stderrTail.Dequeue();
            }
        }
    }

    private void OnExited(Process process)
    {
        // Stop() clears _process before killing, so a deliberate stop
        // never reports as unexpected.
        if (!ReferenceEquals(_process, process))
        {
            return;
        }
        _process = null;
        int code;
        try
        {
            // Let the async stderr reader flush its last lines first.
            process.WaitForExit();
            code = process.ExitCode;
        }
        catch (InvalidOperationException)
        {
            code = -1;
        }
        var tail = StderrTail();
        var message = $"rigctld exited unexpectedly (code {code})" + (tail.Length > 0 ? $": {tail}" : "");
        process.Dispose();
        UnexpectedExit?.Invoke(message);
    }

    private enum ProbeResult
    {
        NothingListening,
        Healthy,
        Unresponsive,
    }

    /// Connects and does one round trip, like the Mac's isHealthy — a
    /// liveness check only, not whether the running rigctld was started
    /// with the same COM port/baud rate (it has no way to report that).
    private static async Task<ProbeResult> ProbeAsync(string host, int port)
    {
        await using var client = new RigctldClient(host, port);
        try
        {
            await client.ConnectAsync(TimeSpan.FromMilliseconds(500)).ConfigureAwait(false);
        }
        catch (RigctldError)
        {
            return ProbeResult.NothingListening;
        }
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            _ = await client.GetFrequencyAsync(cts.Token).ConfigureAwait(false);
            return ProbeResult.Healthy;
        }
        catch (Exception)
        {
            return ProbeResult.Unresponsive;
        }
    }

    /// Clears out a stale rigctld still holding the port — typically one
    /// orphaned when this app was killed from the debugger or crashed
    /// without its window's Closed handler running. Unlike the Mac (which
    /// asks lsof for the listening PID), Windows has no port→PID lookup
    /// without P/Invoke, so this kills processes *named* rigctld; it never
    /// touches anything else that happens to be on the port.
    private static async Task KillStaleRigctldAsync()
    {
        foreach (var stale in Process.GetProcessesByName("rigctld"))
        {
            using (stale)
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1)))
            {
                try
                {
                    stale.Kill();
                    await stale.WaitForExitAsync(cts.Token).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or OperationCanceledException)
                {
                    // Already exited, access denied, or slow to exit — the
                    // spawn below will fail visibly if the port is still held.
                }
            }
        }
    }
}

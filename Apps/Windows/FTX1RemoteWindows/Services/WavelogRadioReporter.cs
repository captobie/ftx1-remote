using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows.Services;

/// Wavelog CAT: reports the rig's transmit frequency, mode and RF power
/// setting to Wavelog as a radio (Wavelog.ReportRadioAsync, API v2's radio
/// resource), so Wavelog's QSO form and bandmap follow the rig the way
/// WaveLogGate makes them — the Mac's WavelogRadioReporter. Settings →
/// Logbook → Wavelog's "Send rig frequency and mode" switch; off by
/// default; the token needs radio:write.
///
/// MainWindow hands it the status after every poll (Update; null while
/// disconnected, and then nothing is sent). Sent when it changes, at most
/// every MinimumInterval, and again every KeepAliveInterval while it
/// doesn't (Wavelog shows how many minutes ago a radio last reported).
/// After a failure it waits RetryInterval, so a bad token doesn't send a
/// request per tuning step. Lives on the UI thread; settings are read at
/// each send.
public sealed class WavelogRadioReporter
{
    public static readonly TimeSpan MinimumInterval = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan KeepAliveInterval = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(30);

    /// The last send's outcome, for Settings: Error null = it worked.
    public (DateTimeOffset At, string? Error)? LastResult { get; private set; }

    /// LastResult changed (raised on the UI thread).
    public event Action? Changed;

    private Wavelog.RadioStatus? _current;
    private (Wavelog.RadioStatus Status, string Radio, int Generation, DateTimeOffset At)? _lastSent;
    /// Bumped by Resend, so a send already out when the settings changed
    /// doesn't count as sent with the new ones.
    private int _generation;
    private DateTimeOffset? _lastAttemptAt;
    private DateTimeOffset? _lastFailedAt;
    /// A request is out: a change then waits for it (the loop picks up the
    /// newest status afterwards) rather than cancelling it.
    private bool _isSending;
    private bool _running;
    private CancellationTokenSource? _loop;

    public void Start()
    {
        _running = true;
        Wake();
    }

    public void Stop()
    {
        _running = false;
        _loop?.Cancel();
        _loop = null;
    }

    /// The rig's state now, or null while disconnected.
    public void Update(Wavelog.RadioStatus? status)
    {
        if (status == _current)
        {
            return;
        }
        _current = status;
        Wake();
    }

    /// Sends now, skipping the wait after a failure — after Settings saved
    /// a change to the switch, URL, token or radio name.
    public void Resend()
    {
        _generation++;
        _lastFailedAt = null;
        LastResult = null;
        Changed?.Invoke();
        Wake();
    }

    /// One loop at a time: it sends whatever's newest when it gets there,
    /// then sleeps until the next keep-alive or the next change.
    private void Wake()
    {
        if (!_running || _isSending)
        {
            return;
        }
        _loop?.Cancel();
        var cts = new CancellationTokenSource();
        _loop = cts;
        _ = RunAsync(cts.Token);
    }

    private async Task RunAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            if (NextSendDelay() is not { } delay)
            {
                return;
            }
            if (delay > TimeSpan.Zero)
            {
                try
                {
                    await Task.Delay(delay, token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                continue;
            }
            await SendAsync();
        }
    }

    /// Time until the next send is due, zero for now, null for nothing to
    /// send until something changes.
    private TimeSpan? NextSendDelay()
    {
        if (!AppSettings.WavelogCatEnabled || _current is not { } status)
        {
            return null;
        }
        var now = DateTimeOffset.Now;
        var due = now;
        if (_lastSent is { } sent && sent.Status == status && sent.Radio == AppSettings.WavelogRadioName && sent.Generation == _generation)
        {
            due = sent.At + KeepAliveInterval;
        }
        if (_lastAttemptAt is { } attempt && attempt + MinimumInterval > due) due = attempt + MinimumInterval;
        if (_lastFailedAt is { } failed && failed + RetryInterval > due) due = failed + RetryInterval;
        return due > now ? due - now : TimeSpan.Zero;
    }

    private async Task SendAsync()
    {
        if (_current is not { } status)
        {
            return;
        }
        var radio = AppSettings.WavelogRadioName;
        var generation = _generation;
        _lastAttemptAt = DateTimeOffset.Now;
        var url = AppSettings.WavelogUrl.Trim();
        var token = WavelogToken.Read();
        if (url.Length == 0 || token.Length == 0)
        {
            Fail("Wavelog needs a URL and an API token");
            return;
        }
        _isSending = true;
        try
        {
            await Wavelog.ReportRadioAsync(status, radio, url, token);
            _lastSent = (status, radio, generation, DateTimeOffset.Now);
            _lastFailedAt = null;
            if (LastResult is { Error: not null })
            {
                AppLog.Write("Wavelog: radio updates working again");
            }
            LastResult = (DateTimeOffset.Now, null);
            Changed?.Invoke();
        }
        catch (Wavelog.ApiException e)
        {
            Fail(e.Message);
        }
        finally
        {
            _isSending = false;
        }
    }

    private void Fail(string message)
    {
        if (LastResult?.Error != message)
        {
            AppLog.Write($"Wavelog: radio update failed: {message}");
        }
        _lastFailedAt = DateTimeOffset.Now;
        LastResult = (DateTimeOffset.Now, message);
        Changed?.Invoke();
    }
}

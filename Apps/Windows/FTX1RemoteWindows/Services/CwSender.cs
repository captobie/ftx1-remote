using System.Text;
using System.Text.RegularExpressions;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows.Services;

/// What the sender needs from MainWindow (the Mac's CWSender reaches into
/// HubService instead).
public sealed class CwRigLink
{
    /// The connected client, or null.
    public required Func<RigctldClient?> Client { get; init; }
    /// Why the rig can't send right now, or null (see CwSendBlock).
    public required Func<CwSendBlock?> BlockReason { get; init; }
    /// The rig's keyer speed ("KS"), if read.
    public required Func<int?> SpeedWpm { get; init; }
    /// Whether the last poll saw the rig transmitting.
    public required Func<bool> Ptt { get; init; }
    /// Awaited right before each chunk keys ("KY0n"): MainWindow stops a
    /// running memory scan there, as before PTT. Not part of BlockReason,
    /// which the pane also reads just to show its status.
    public Func<Task>? BeforeKeyAsync { get; init; }
}

/// The send side of the CW window — the Mac's CWSender (Apps/Mac/
/// FTX1RemoteMac/CWSender.swift), which has the full story. Typed lines are
/// keyed by the rig's own keyer through one dedicated CW TEXT keyer memory
/// (<see cref="Slot"/>, default 1): write up to 50 characters there ("KM",
/// <see cref="RigctldClient.WriteKeyerMemoryAsync"/>), play it ("KY0n",
/// transmit-gated), wait for the rig to finish, repeat. The rig does the
/// timing, so network lag can't distort the CW; a line over 50 characters
/// pauses a few seconds between chunks.
///
/// Rig facts behind this, probed on the real rig by the Mac work
/// (2026-10-02): it keys only with break-in on; it appends the "}" end
/// marker itself and keeps exactly 50 characters; it keyed every character
/// in <see cref="CwText.Allowed"/>; PTT reads 3 while keying, with the odd
/// spurious 0; a second play while one runs restarts the message (so chunks
/// go strictly one after another); "KY00" stops it.
///
/// Lives on the UI thread and is owned by MainWindow, so closing the CW
/// window doesn't stop a queued line (Stop does), as on the Mac.
public sealed class CwSender
{
    /// Items, activity or settings changed (UI thread).
    public event Action? Changed;
    /// True from the first write of a run until the queue is done, so the
    /// decoder can pause (CwReceiver.SetSenderActive).
    public event Action<bool>? ActiveChanged;

    private readonly CwRigLink _rig;
    private readonly List<CwSendItem> _items = [];
    private CancellationTokenSource? _run;
    private int? _slotCheckedAsText;
    private DateTime _lastPttOnAt = DateTime.MinValue;
    private int _slot;
    private List<CwMacro> _macros;
    private string _theirCall = "";

    private const int MaxItems = 200;

    public CwSender(CwRigLink rig)
    {
        _rig = rig;
        _slot = AppSettings.CwKeyerSlot;
        _macros = AppSettings.CwMacros;
    }

    public IReadOnlyList<CwSendItem> Items => _items;

    /// What the rig is doing for the send pane right now, e.g. "Writing
    /// keyer memory 1…" — null when idle.
    public string? Activity { get; private set; }

    public bool IsSending => _run is not null;
    public bool HasWaiting => _items.Any(i => i.IsWaiting);
    public bool HasFinished => _items.Any(i => !i.IsWaiting);

    /// The station being worked ("Their call" in the pane), for {CALL};
    /// also filled by clicking a callsign in the decoded text. Session only.
    public string TheirCall
    {
        get => _theirCall;
        set
        {
            if (value == _theirCall)
            {
                return;
            }
            _theirCall = value;
            Changed?.Invoke();
        }
    }

    public int Slot
    {
        get => _slot;
        set
        {
            if (value == _slot || value is < 1 or > 5)
            {
                return;
            }
            _slot = value;
            AppSettings.CwKeyerSlot = value;
            Changed?.Invoke();
        }
    }

    public IReadOnlyList<CwMacro> Macros => _macros;

    public void SetMacros(List<CwMacro> macros)
    {
        _macros = macros;
        AppSettings.CwMacros = macros;
        Changed?.Invoke();
    }

    public CwSendBlock? BlockReason => _rig.BlockReason();
    public int? SpeedWpm => _rig.SpeedWpm();

    /// From MainWindow after every poll: finish detection needs to know
    /// when PTT last read on.
    public void OnPtt(bool ptt)
    {
        if (ptt)
        {
            _lastPttOnAt = DateTime.UtcNow;
        }
    }

    /// A new connection: re-check the slot's TEXT/MESSAGE setting before
    /// the next write (the Mac's once-per-session check).
    public void OnConnected() => _slotCheckedAsText = null;

    // Queueing

    /// Queues a typed line. Returns why nothing was queued, if so.
    public string? Enqueue(string line)
    {
        var (text, dropped) = CwText.Prepare(line);
        if (text.Length == 0)
        {
            return dropped.Length == 0 ? null : "Nothing the keyer can send in that line";
        }
        _items.Add(new CwSendItem(text, CwText.Chunks(text), dropped));
        if (_items.Count > MaxItems)
        {
            _items.RemoveRange(0, _items.Count - MaxItems);
        }
        Changed?.Invoke();
        StartIfNeeded();
        return null;
    }

    /// A macro with its placeholders filled in, for the pane to put in the
    /// send line (macros don't send directly — the Mac's 2026-10-03
    /// decision, so the text can be edited first). Null text means a
    /// placeholder had nothing to fill it; <c>Problem</c> says which.
    public (string? Text, string? Problem) TextFor(CwMacro macro) =>
        macro.Expanded(AppSettings.Callsign, AppSettings.GridSquare, TheirCall);

    /// Stops keying at once and drops everything not yet sent.
    public void Stop()
    {
        if (_run is null && !HasWaiting)
        {
            return;
        }
        _run?.Cancel();
        _run = null;
        if (_rig.Client() is { } client)
        {
            // Never gated: stopping must always get through.
            _ = SendQuietlyAsync(() => client.SetRawIntAsync("KY0", 0, 1));
        }
        foreach (var item in _items.Where(i => i.IsWaiting))
        {
            item.State = CwSendState.Stopped;
        }
        Activity = null;
        ActiveChanged?.Invoke(false);
        AppLog.Write("cw-sender: stopped");
        Changed?.Invoke();
    }

    public void ClearLog()
    {
        _items.RemoveAll(i => !i.IsWaiting);
        Changed?.Invoke();
    }

    private static async Task SendQuietlyAsync(Func<Task> send)
    {
        try
        {
            await send();
        }
        catch (Exception ex)
        {
            AppLog.Write($"cw-sender: {ex.Message}");
        }
    }

    // The send loop

    private void StartIfNeeded()
    {
        if (_run is not null || !HasWaiting)
        {
            return;
        }
        ActiveChanged?.Invoke(true);
        var run = new CancellationTokenSource();
        _run = run;
        _ = RunAsync(run);
    }

    private async Task RunAsync(CancellationTokenSource run)
    {
        try
        {
            while (!run.IsCancellationRequested && _items.FirstOrDefault(i => i.IsWaiting) is { } item)
            {
                try
                {
                    await SendAsync(item, run.Token);
                }
                catch (OperationCanceledException) when (run.IsCancellationRequested)
                {
                    return;
                }
                catch (Exception ex)
                {
                    item.State = CwSendState.Failed;
                    item.FailureReason = ex.Message;
                    AppLog.Write($"cw-sender: send failed: {ex.Message}");
                    // Don't carry on with later lines out of order.
                    foreach (var later in _items.Where(i => i.IsWaiting))
                    {
                        later.State = CwSendState.Stopped;
                    }
                    Changed?.Invoke();
                    return;
                }
            }
        }
        finally
        {
            // A cancelled run finishing late mustn't clear a newer one.
            if (ReferenceEquals(_run, run))
            {
                _run = null;
                Activity = null;
                ActiveChanged?.Invoke(false);
                Changed?.Invoke();
            }
            run.Dispose();
        }
    }

    private async Task SendAsync(CwSendItem item, CancellationToken token)
    {
        while (item.SentChunks < item.Chunks.Count)
        {
            var chunk = item.Chunks[item.SentChunks];
            var client = await WaitUntilSendableAsync(token);
            item.State = CwSendState.Sending;
            Changed?.Invoke();

            var slot = _slot;
            if (_slotCheckedAsText != slot)
            {
                SetActivity($"Checking keyer memory {slot}…");
                await EnsureTextMemoryAsync(client, slot);
                _slotCheckedAsText = slot;
                token.ThrowIfCancellationRequested();
            }
            SetActivity($"Writing keyer memory {slot}…");
            // Not cancelled mid-write: an abandoned read would leave the
            // rig's late reply in the stream. Checked right after instead.
            var stored = await client.WriteKeyerMemoryAsync(slot, chunk);
            token.ThrowIfCancellationRequested();
            if (stored != chunk)
            {
                AppLog.Write($"cw-sender: keyer memory holds \"{stored}\", sent \"{chunk}\"");
            }

            // The rig may have changed (TX disabled, band, BK-IN) during the
            // ~2 s write.
            if (_rig.BlockReason() is { } block)
            {
                throw new InvalidOperationException($"Not sent: {block.Message}");
            }
            var wpm = Math.Max(_rig.SpeedWpm() ?? 20, 4);
            var expected = CwText.Duration(chunk, wpm);
            SetActivity($"Sending at {wpm} WPM…");
            if (_rig.BeforeKeyAsync is { } beforeKey)
            {
                await beforeKey();
            }
            var startedAt = DateTime.UtcNow;
            await client.SetRawIntAsync("KY0", slot, 1);
            await WaitUntilKeyedAsync(startedAt, expected, token);
            item.SentChunks++;
            Changed?.Invoke();
        }
        item.State = CwSendState.Sent;
        Changed?.Invoke();
    }

    /// The slot must be a TEXT memory (CW SETTING → KEYER → CW MEMORY 1-5,
    /// "EX" 02 02 06-10: 0 TEXT, 1 MESSAGE); a MESSAGE slot would play
    /// recorded audio instead — HubService.ensureCWTextMemory.
    private static async Task EnsureTextMemoryAsync(RigctldClient client, int slot)
    {
        var value = await client.GetMenuItemAsync(2, 2, 5 + slot);
        if (value != "0")
        {
            AppLog.Write($"cw-sender: CW MEMORY {slot} was {value ?? "unreadable"}; setting it to TEXT");
            await client.SetMenuItemAsync(2, 2, 5 + slot, "0");
        }
    }

    /// Waits while something blocks sending, showing it in the pane.
    private async Task<RigctldClient> WaitUntilSendableAsync(CancellationToken token)
    {
        while (true)
        {
            if (_rig.BlockReason() is { } block)
            {
                SetActivity($"Waiting: {block.Message}");
            }
            else if (_rig.Client() is { } client)
            {
                return client;
            }
            await Task.Delay(500, token);
        }
    }

    /// The rig keys the memory on its own; there's no "done" readback. Done
    /// means: most of the expected keying time has passed and PTT has read
    /// off for a second (a single spurious 0 mid-message was seen, so one 0
    /// isn't trusted). Capped, in case PTT never shows TX at all.
    private async Task WaitUntilKeyedAsync(DateTime startedAt, double expected, CancellationToken token)
    {
        while (true)
        {
            await Task.Delay(250, token);
            var elapsed = (DateTime.UtcNow - startedAt).TotalSeconds;
            if (elapsed >= expected * 0.9 && !_rig.Ptt() && (DateTime.UtcNow - _lastPttOnAt).TotalSeconds >= 1)
            {
                if (_lastPttOnAt < startedAt)
                {
                    AppLog.Write("cw-sender: no TX seen while the keyer memory played (break-in off?)");
                }
                return;
            }
            if (elapsed > expected * 1.5 + 5)
            {
                AppLog.Write($"cw-sender: keying still not finished after {elapsed:F1} s (expected {expected:F1} s); moving on");
                return;
            }
        }
    }

    private void SetActivity(string? activity)
    {
        if (activity == Activity)
        {
            return;
        }
        Activity = activity;
        Changed?.Invoke();
    }
}

public enum CwSendState
{
    Queued,
    Sending,
    Sent,
    Stopped,
    Failed,
}

/// A line in the send log (the Mac's CWSendItem).
public sealed class CwSendItem(string text, IReadOnlyList<string> chunks, string dropped)
{
    /// What will be keyed, after CwText.Prepare.
    public string Text { get; } = text;
    public IReadOnlyList<string> Chunks { get; } = chunks;
    /// Characters left out because the keyer can't send them.
    public string Dropped { get; } = dropped;
    public int SentChunks { get; set; }
    public CwSendState State { get; set; } = CwSendState.Queued;
    public string? FailureReason { get; set; }

    public bool IsWaiting => State is CwSendState.Queued or CwSendState.Sending;
}

/// Why the rig can't send (the Mac's CWSendBlock).
public sealed record CwSendBlock(CwSendBlockKind Kind, string Message)
{
    public static readonly CwSendBlock NotConnected = new(CwSendBlockKind.NotConnected, "the rig isn't connected");
    public static CwSendBlock TransmitBlocked(string gateReason) => new(CwSendBlockKind.TransmitBlocked,
        gateReason == "Transmit disabled"
            ? "transmit is turned off (Enable Transmit)"
            : "the rig is outside the amateur bands");
    public static CwSendBlock NotCw(string modeName) => new(CwSendBlockKind.NotCw, $"the rig is in {modeName}, not CW");
    public static readonly CwSendBlock BreakInOff = new(CwSendBlockKind.BreakInOff, "break-in is off — the rig only keys its memory with BK-IN on");
}

public enum CwSendBlockKind
{
    NotConnected,
    TransmitBlocked,
    NotCw,
    BreakInOff,
}

/// Turning typed text into what the FTX-1's keyer memory takes (the Mac's
/// CWText).
public static class CwText
{
    /// Every character here was keyed correctly by the rig (2026-10-02).
    /// ";" can never be allowed: it ends the CAT command.
    public static readonly HashSet<char> Allowed = [.. "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /?,.=+-()@:"];

    /// Prosigns in angle brackets, sent as the punctuation the keyer keys
    /// for them. Others (e.g. &lt;SK&gt;) have no single character the keyer
    /// is known to take, so their letters are sent as a word.
    private static readonly (string Prosign, string Character)[] Prosigns = [("<BT>", "="), ("<AR>", "+"), ("<KN>", "(")];

    public const int MemoryLength = 50;

    /// Uppercased, prosigns mapped, other characters dropped, whitespace
    /// collapsed. <c>Dropped</c> lists what was removed, for the pane to show.
    public static (string Text, string Dropped) Prepare(string line)
    {
        var text = line.ToUpperInvariant();
        foreach (var (prosign, character) in Prosigns)
        {
            text = text.Replace(prosign, character, StringComparison.Ordinal);
        }
        text = text.Replace("<", "", StringComparison.Ordinal).Replace(">", "", StringComparison.Ordinal);
        var kept = new StringBuilder();
        var dropped = new StringBuilder();
        foreach (var character in text)
        {
            if (char.IsWhiteSpace(character))
            {
                kept.Append(' ');
            }
            else if (Allowed.Contains(character))
            {
                kept.Append(character);
            }
            else if (!dropped.ToString().Contains(character))
            {
                dropped.Append(character);
            }
        }
        var words = kept.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return (string.Join(' ', words), dropped.ToString());
    }

    /// Splits at word boundaries into pieces of at most MemoryLength
    /// characters (a longer word is cut).
    public static List<string> Chunks(string text)
    {
        var chunks = new List<string>();
        var current = "";
        foreach (var w in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var word = w;
            while (word.Length > MemoryLength)
            {
                if (current.Length > 0)
                {
                    chunks.Add(current);
                    current = "";
                }
                chunks.Add(word[..MemoryLength]);
                word = word[MemoryLength..];
            }
            if (current.Length == 0)
            {
                current = word;
            }
            else if (current.Length + 1 + word.Length <= MemoryLength)
            {
                current += " " + word;
            }
            else
            {
                chunks.Add(current);
                current = word;
            }
        }
        if (current.Length > 0)
        {
            chunks.Add(current);
        }
        return chunks;
    }

    /// Keying time at <paramref name="wpm"/> (PARIS timing: a dit is
    /// 1.2/wpm s; elements are 1 or 3 units with 1-unit gaps, 3 units
    /// between characters, 7 between words). The rig may weight or space
    /// differently; this only sets when finish detection starts looking.
    public static double Duration(string text, int wpm)
    {
        var units = 0;
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (var index = 0; index < words.Length; index++)
        {
            if (index > 0)
            {
                units += 7;
            }
            for (var position = 0; position < words[index].Length; position++)
            {
                if (position > 0)
                {
                    units += 3;
                }
                var pattern = Morse.GetValueOrDefault(words[index][position], "....");
                units += pattern.Sum(c => c == '-' ? 3 : 1) + pattern.Length - 1;
            }
        }
        return units * 1.2 / wpm;
    }

    private static readonly Dictionary<char, string> Morse = new()
    {
        ['A'] = ".-", ['B'] = "-...", ['C'] = "-.-.", ['D'] = "-..", ['E'] = ".", ['F'] = "..-.", ['G'] = "--.",
        ['H'] = "....", ['I'] = "..", ['J'] = ".---", ['K'] = "-.-", ['L'] = ".-..", ['M'] = "--", ['N'] = "-.",
        ['O'] = "---", ['P'] = ".--.", ['Q'] = "--.-", ['R'] = ".-.", ['S'] = "...", ['T'] = "-", ['U'] = "..-",
        ['V'] = "...-", ['W'] = ".--", ['X'] = "-..-", ['Y'] = "-.--", ['Z'] = "--..",
        ['0'] = "-----", ['1'] = ".----", ['2'] = "..---", ['3'] = "...--", ['4'] = "....-",
        ['5'] = ".....", ['6'] = "-....", ['7'] = "--...", ['8'] = "---..", ['9'] = "----.",
        ['/'] = "-..-.", ['?'] = "..--..", [','] = "--..--", ['.'] = ".-.-.-", ['='] = "-...-",
        ['+'] = ".-.-.", ['-'] = "-....-", ['('] = "-.--.", [')'] = "-.--.-", ['@'] = ".--.-.", [':'] = "---...",
    };
}

/// One macro button (the Mac's CWMacro). Persisted in settings.json.
public sealed class CwMacro
{
    public string Label { get; set; } = "";
    public string Text { get; set; } = "";

    /// {MYCALL}/{MYGRID} from Settings → Station, {CALL} from the pane's
    /// Their call field. A placeholder with nothing to fill it gives
    /// (null, which one).
    public (string? Text, string? Problem) Expanded(string myCall, string myGrid, string theirCall)
    {
        var values = new[]
        {
            ("{MYCALL}", myCall, "Your callsign (Settings → Station)"),
            ("{MYGRID}", myGrid, "Your grid square (Settings → Station)"),
            ("{CALL}", theirCall, "Their call"),
        };
        var result = Text;
        foreach (var (placeholder, value, name) in values)
        {
            if (!result.Contains(placeholder, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var trimmed = value.Trim();
            if (trimmed.Length == 0)
            {
                return (null, $"{name} is empty");
            }
            result = result.Replace(placeholder, trimmed, StringComparison.OrdinalIgnoreCase);
        }
        return (result, null);
    }

    public static List<CwMacro> Defaults() =>
    [
        new() { Label = "CQ", Text = "CQ CQ CQ DE {MYCALL} {MYCALL} K" },
        new() { Label = "Answer", Text = "{CALL} DE {MYCALL} {MYCALL} K" },
        new() { Label = "Report", Text = "{CALL} DE {MYCALL} TNX FER CALL <BT> UR RST 599 599 <BT> BK" },
        new() { Label = "73", Text = "{CALL} DE {MYCALL} TNX FER QSO 73 E E" },
        new() { Label = "QRZ?", Text = "QRZ? DE {MYCALL} K" },
        new() { Label = "AGN?", Text = "AGN? AGN?" },
    ];
}

/// Finds amateur callsigns in decoded CW text, so the CW window can make
/// them clickable (the Mac's CWCallsigns): 1–2 letters, a digit+letter or a
/// letter+digit, then a digit, then 1–4 letters (W1AW, KA3ROC, 2E0ABC,
/// E73XYZ), optionally with "/"-separated parts (DL5ABC/P, VE3/W1AW),
/// judged on its longest part. That rules out reports (5NN, 599), numbers
/// (73, 40M), Q-codes and abbreviations.
public static partial class CwCallsigns
{
    [GeneratedRegex("[A-Z0-9/]+")]
    private static partial Regex Token();

    [GeneratedRegex("^([A-Z]{1,2}|[0-9][A-Z]|[A-Z][0-9])[0-9][A-Z]{1,4}$")]
    private static partial Regex Base();

    public static bool IsCallsign(string candidate)
    {
        if (candidate.Length is < 3 or > 12)
        {
            return false;
        }
        var parts = candidate.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
        {
            return false;
        }
        var longest = parts.MaxBy(p => p.Length)!;
        return Base().IsMatch(longest);
    }

    /// (start, length) of each callsign in <paramref name="text"/>, minus
    /// the operator's own call in any of its "/" forms.
    public static IEnumerable<(int Start, int Length)> Find(string text, string ownCall)
    {
        var own = ownCall.Trim().ToUpperInvariant();
        foreach (Match match in Token().Matches(text))
        {
            if (!IsCallsign(match.Value))
            {
                continue;
            }
            if (own.Length > 0 && match.Value.Split('/').Contains(own))
            {
                continue;
            }
            yield return (match.Index, match.Length);
        }
    }
}

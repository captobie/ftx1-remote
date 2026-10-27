using System.Text.Json.Serialization;

namespace FTX1RemoteWindows.Services.Hub;

/// iPad → hub: `{"type":"cw_keyer","id":…,"slot":…,"text":…}` (Swift's
/// CWKeyerRequest). With text: write that CW TEXT keyer memory. Without:
/// make the slot a TEXT memory. With an `action` (slot 0): the keyer lease,
/// which this hub doesn't have (Apps/Windows/README.md, phase 6) — acquire
/// is always granted, release does nothing.
public sealed class CwKeyerRequestWire
{
    public const string AcquireAction = "acquire";
    public const string ReleaseAction = "release";

    [JsonPropertyName("type")] public string Type { get; set; } = "cw_keyer";
    [JsonPropertyName("id")] public int Id { get; set; }
    [JsonPropertyName("slot")] public int Slot { get; set; }
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("action")] public string? Action { get; set; }
}

/// Hub → the asking client only (Swift's CWKeyerReply), carrying the
/// request's `id`: `stored` = what the rig kept after a write, `error` if it
/// failed or was refused, neither for a successful check, acquire or
/// release. `busy` is never sent here (no lease). `errorCode` is a stable
/// code beside the English `error` (Swift's CWKeyerReply.ErrorCode), so the
/// iPad words the message in its own language; older iPads use the text.
public sealed class CwKeyerReplyWire
{
    public const string BadSlotCode = "keyer_bad_slot";
    public const string BadTextCode = "keyer_bad_text";
    public const string NotConnectedCode = "rigctld_not_connected";

    [JsonPropertyName("type")] public string Type { get; set; } = "cw_keyer_reply";
    [JsonPropertyName("id")] public int Id { get; set; }
    [JsonPropertyName("stored")] public string? Stored { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("busy")] public string? Busy { get; set; }
    [JsonPropertyName("errorCode")] public string? ErrorCode { get; set; }
    [JsonPropertyName("busyCode")] public string? BusyCode { get; set; }
}

/// The checks the hub makes on a client's keyer request before anything
/// reaches the rig — the Mac's HubService.remoteCWKeyer — and before a
/// client's keyer play.
public static class HubKeyerPolicy
{
    /// What the rig's keyer keyed correctly (2026-10-02). Must equal Swift's
    /// CWText.allowed (Sources/FTX1CW/CWSender.swift) and this app's
    /// CwText.Allowed; a test compares all three. ";" can never be in it: it
    /// ends the CAT command. Lowercase isn't either — the iPad uppercases
    /// before sending (CWText.prepare), and the Mac refuses it too.
    public const string AllowedCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /?,.=+-()@:";
    public const int MemoryLength = 50;
    private static readonly HashSet<char> Allowed = [.. AllowedCharacters];

    /// Why a write (text non-null) or a TEXT check (text null) is refused,
    /// or null. The English goes on the wire as is (not Loc: it's for every
    /// client), beside <see cref="RequestRefusalCode"/>.
    public static string? RequestRefusal(int slot, string? text)
    {
        if (slot is < 1 or > 5)
        {
            return $"Keyer memory {slot} doesn't exist (1–5)";
        }
        if (text is null)
        {
            return null;
        }
        if (text.Length == 0)
        {
            return "Nothing to write: the text is empty";
        }
        if (text.Length > MemoryLength)
        {
            return $"Too long for the keyer memory: {text.Length} characters ({MemoryLength} at most)";
        }
        foreach (var c in text)
        {
            if (!Allowed.Contains(c))
            {
                return $"The keyer can't send \"{c}\" (allowed: A–Z 0–9 space / ? , . = + - ( ) @ :)";
            }
        }
        return null;
    }

    /// The wire code for <see cref="RequestRefusal"/>'s refusal, or null.
    public static string? RequestRefusalCode(int slot, string? text) =>
        RequestRefusal(slot, text) is null ? null
        : slot is < 1 or > 5 ? CwKeyerReplyWire.BadSlotCode
        : CwKeyerReplyWire.BadTextCode;

    /// Why a hub client's keyer play (KY0n, n ≠ 0) must not start now, or
    /// null: something else is already transmitting — this window's PTT or
    /// MOX, a hub client's PTT, or any TX the rig reports that isn't the
    /// hub's own keyer play (a straight key through the Pi's ftx1-cwkey,
    /// this PC's own CW window, the front panel). Called after the transmit
    /// gate.
    public static string? PlayRefusal(bool windowPtt, bool mox, bool hubPtt, bool rigTransmitting, bool hubKeyerActive)
    {
        if (windowPtt)
        {
            return "this PC's PTT is held";
        }
        if (mox)
        {
            return "MOX is on";
        }
        if (hubPtt)
        {
            return "a hub client is keyed with PTT";
        }
        if (rigTransmitting && !hubKeyerActive)
        {
            return "the rig is already transmitting (not the hub's keyer)";
        }
        return null;
    }
}

/// Whether hub clients have played the keyer since the last stop (so a
/// lock, hub off or disconnect sends "KY00"), and whether the TX the rig
/// reports is the hub's own keyer play. UI thread; times in ms
/// (Environment.TickCount64).
public sealed class HubKeyerTracker
{
    /// The rig takes a moment to start keying after "KY0n"; until then a
    /// PTT-off poll doesn't end the play.
    public const long StartGraceMs = 2000;
    /// PTT off this long ends the play — the iPad's own "done" rule, which
    /// also rides out the odd spurious 0 mid-message.
    public const long OffForMs = 1000;

    private long _playAt;
    private long? _offSince;

    /// A hub client played since the last stop.
    public bool PlayedSinceStop { get; private set; }

    /// The hub's keyer play is still running, as far as the polls show.
    public bool Active { get; private set; }

    public void Played(long now)
    {
        PlayedSinceStop = true;
        Active = true;
        _playAt = now;
        _offSince = null;
    }

    /// "KY00" went out (any stop the hub sent or forwarded).
    public void Stopped()
    {
        PlayedSinceStop = false;
        Active = false;
        _offSince = null;
    }

    /// Every poll's PTT reading.
    public void OnPtt(bool ptt, long now)
    {
        if (!Active)
        {
            return;
        }
        if (ptt)
        {
            _offSince = null;
            return;
        }
        _offSince ??= now;
        if (now - _playAt >= StartGraceMs && now - _offSince.Value >= OffForMs)
        {
            Active = false;
        }
    }
}

public enum HubKeyerStopResult
{
    /// The rig read not transmitting after a "KY00".
    Confirmed,
    /// Still transmitting after every "KY00"; PTT off stopped it.
    StoppedByPttOff,
    /// Still transmitting after the PTT off too.
    StillTransmitting,
    /// The TX state couldn't be read at the end (e.g. the link is gone).
    Unconfirmed,
}

/// A keyer stop the hub sends on its own (the player's disconnect, the
/// lock, hub off, disconnecting from the rig), confirmed — the straight
/// key's lesson: under RF an un-key command failed once and the rig kept
/// transmitting. "KY00", then the rig's TX state ~1 s later; still
/// transmitting → "KY00" again, up to <see cref="Tries"/> in all ~1 s
/// apart, then PTT off ("T currVFO 0"). Every try and the result are
/// logged; a failed stop is never silent.
public static class HubKeyerStop
{
    public const int Tries = 5;
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(1);

    /// <paramref name="readTransmitting"/> returns null when the state can't
    /// be read. None of the delegates' exceptions escape.
    public static async Task<HubKeyerStopResult> RunAsync(string reason, Func<Task> sendStop,
        Func<Task<bool?>> readTransmitting, Func<Task> pttOff, Func<TimeSpan, Task> delay, Action<string> log)
    {
        for (var attempt = 1; attempt <= Tries; attempt++)
        {
            try
            {
                await sendStop();
                log($"hub: keyer stop (KY00) try {attempt} — {reason}");
            }
            catch (Exception ex)
            {
                log($"hub: keyer stop (KY00) try {attempt} failed to send: {ex.Message} — {reason}");
            }
            await delay(Interval);
            var transmitting = await ReadAsync(readTransmitting);
            if (transmitting == false)
            {
                log($"hub: keyer stop confirmed (try {attempt}) — {reason}");
                return HubKeyerStopResult.Confirmed;
            }
            log(transmitting == true
                ? $"hub: keyer still transmitting after {attempt} {(attempt == 1 ? "try" : "tries")}"
                : $"hub: couldn't read the rig's TX state after try {attempt}");
        }

        try
        {
            await pttOff();
            log($"hub: keyer still transmitting after {Tries} tries — sent PTT off");
        }
        catch (Exception ex)
        {
            log($"hub: keyer still transmitting after {Tries} tries — PTT off failed to send: {ex.Message}");
        }
        await delay(Interval);
        switch (await ReadAsync(readTransmitting))
        {
            case false:
                log($"hub: keyer stopped by PTT off — {reason}");
                return HubKeyerStopResult.StoppedByPttOff;
            case true:
                log($"hub: KEYER STILL TRANSMITTING after {Tries} stops and PTT off — check the rig now ({reason})");
                return HubKeyerStopResult.StillTransmitting;
            default:
                log($"hub: COULDN'T CONFIRM the keyer stopped after {Tries} stops and PTT off — check the rig ({reason})");
                return HubKeyerStopResult.Unconfirmed;
        }
    }

    private static async Task<bool?> ReadAsync(Func<Task<bool?>> read)
    {
        try
        {
            return await read();
        }
        catch
        {
            return null;
        }
    }
}

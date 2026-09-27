namespace FTX1RemoteWindows.Services;

/// Tracks whether the rig's L/R USB audio channels are currently swapped
/// relative to the app's Main/Sub roles. Port of the Mac's
/// HubService.audioChannelsSwapped / trackExternalSwap (see the root
/// CLAUDE.md's "Swap tracking — audio follows the swap").
///
/// Why this exists: after a Main/Sub swap (the app's ⇄, or the rig's own
/// front-panel swap) the frequencies and modes follow the swap but the L/R
/// audio stays with the physical receiver, so without this the MAIN audio
/// controls would play the other VFO's signal. The rig has no readout of
/// the true mapping, so this tracks the parity instead:
///   1. <see cref="OnAppSwap"/>: the app sent "SV". Flips, except in
///      single-receive display (hardware finding 2026-09-19: the app's SV
///      doesn't move the audio there, though a front-panel swap does).
///   2. <see cref="OnPoll"/>: both polled frequencies exchanged relative to
///      the last pair where they differed, with no app command in between
///      — a front-panel swap. Equal-frequency swaps can't be seen.
///   3. <see cref="Toggle"/>: the manual override, for when the tracked
///      state has drifted (e.g. a swap made while the app wasn't running).
/// Persisted by the caller for that last reason.
public sealed class AudioChannelSwapTracker
{
    private (long Main, long Sub)? _lastDistinct;

    public AudioChannelSwapTracker(bool swapped)
    {
        Swapped = swapped;
    }

    public bool Swapped { get; private set; }

    /// Raised with a short reason whenever <see cref="Swapped"/> changes.
    public event Action<string>? Changed;

    public void Toggle() => Set(!Swapped, "manual toggle");

    /// Call after the app's own swap command is sent. <paramref name="lastMain"/>
    /// and <paramref name="lastSub"/> are the last polled values; the
    /// baseline is moved to the swapped pair so the next poll, which reads
    /// the already-swapped frequencies, isn't taken for a second swap.
    public void OnAppSwap(bool? singleReceive, long? lastMain, long? lastSub)
    {
        // null (FR not read yet) is treated as dual, the common case —
        // same as the Mac.
        if (singleReceive != true)
        {
            Set(!Swapped, "app swap command");
        }
        _lastDistinct = lastMain is { } m && lastSub is { } s && m != s ? (s, m) : null;
    }

    /// Call when the app tunes a VFO itself, so the resulting frequency pair
    /// can't be mistaken for an exchange.
    public void ResetBaseline() => _lastDistinct = null;

    /// Call once per poll with that poll's freshly read values.
    /// <paramref name="sub"/> is null when its read failed (baseline kept).
    /// Outside plain VFO mode the baseline is dropped: in Memory mode "Main"
    /// is a channel's frequency, not a VFO's.
    ///
    /// A poll that straddles a front-panel swap reads one side before and
    /// one after, which always gives an *equal* pair (new Main = old Sub),
    /// so it's ignored and the next full poll catches the swap.
    public void OnPoll(long main, long? sub, bool inVfoMode)
    {
        if (!inVfoMode)
        {
            _lastDistinct = null;
            return;
        }
        if (sub is not { } s || s == main)
        {
            return;
        }
        if (_lastDistinct is { } last && main == last.Sub && s == last.Main)
        {
            Set(!Swapped, $"front-panel swap detected ({last.Main}/{last.Sub} -> {main}/{s} Hz)");
        }
        _lastDistinct = (main, s);
    }

    private void Set(bool swapped, string reason)
    {
        if (swapped == Swapped)
        {
            return;
        }
        Swapped = swapped;
        Changed?.Invoke(reason);
    }
}

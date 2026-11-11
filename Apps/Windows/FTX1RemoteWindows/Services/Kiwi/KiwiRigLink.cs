using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// What the rig looks like to the MyKiwiSDR window's Tune rig direction.
public readonly record struct KiwiRigSnapshot(bool Connected, bool Transmitting, bool MemoryMode, int FrequencyHz, RigMode? Mode);

/// The rules between the MyKiwiSDR window's Kiwi and the rig's MAIN VFO, both
/// ways, kept pure (time comes in as "now", seconds on any monotonic clock)
/// so they can be tested with a fake clock. Port of the Mac's
/// KiwiRigLink.swift, itself the WebSDR window's rules: Follow tunes the Kiwi
/// to the rig, Tune rig tunes the rig to what the window tuned, and after the
/// window tunes the rig the rig's not-yet-updated values are ignored for
/// RigTuneGrace seconds (PendingRigTune), so the two can't fight.
public sealed class KiwiRigLink
{
    /// How long a rig value that hasn't caught up with the window's tune is ignored.
    public const double RigTuneGrace = 3;
    /// Rig and Kiwi count as on the same frequency within this.
    public const int SameFrequencyToleranceHz = 10;

    public sealed record PendingRigTune(int FrequencyHz, RigMode? Mode, double Until);

    public abstract record FollowDecision
    {
        /// Tune the Kiwi; Mode null = keep the Kiwi's mode.
        public sealed record Tune(int FrequencyHz, KiwiSdrMode? Mode) : FollowDecision;
        public sealed record AlreadyThere : FollowDecision;
        public sealed record WaitingForRig : FollowDecision;
        public sealed record NoRigFrequency : FollowDecision;
        /// Above the Kiwi's reported bandwidth.
        public sealed record OutOfRange(int FrequencyHz) : FollowDecision;
    }

    public enum Refusal { RigDisconnected, NoRigFrequency, Transmitting, MemoryMode }

    public abstract record TuneRigDecision
    {
        /// Send these (null = leave that one alone).
        public sealed record Send(int? FrequencyHz, RigMode? Mode) : TuneRigDecision;
        public sealed record Nothing : TuneRigDecision;
        public sealed record Refused(Refusal Reason) : TuneRigDecision;
    }

    public PendingRigTune? Pending { get; private set; }

    /// The rig's (debounced) MAIN frequency and mode changed, or Follow was
    /// turned on: where the Kiwi should go.
    public FollowDecision Follow(int rigFrequencyHz, RigMode? rigMode, int kiwiFrequencyHz, KiwiSdrMode kiwiMode,
                                 int maxFrequencyHz, double now)
    {
        if (Pending is { } pending)
        {
            var caughtUp = Same(rigFrequencyHz, pending.FrequencyHz) && (pending.Mode is null || pending.Mode == rigMode);
            if (!caughtUp && now < pending.Until)
            {
                return new FollowDecision.WaitingForRig();
            }
            Pending = null;
        }
        if (rigFrequencyHz <= 0)
        {
            return new FollowDecision.NoRigFrequency();
        }
        if (rigFrequencyHz > maxFrequencyHz)
        {
            return new FollowDecision.OutOfRange(rigFrequencyHz);
        }
        var mode = KiwiSdrModeExtensions.FromRigMode(rigMode);
        var modeMatches = mode is null || mode == kiwiMode;
        if (Same(rigFrequencyHz, kiwiFrequencyHz) && modeMatches)
        {
            return new FollowDecision.AlreadyThere();
        }
        return new FollowDecision.Tune(rigFrequencyHz, modeMatches ? null : mode);
    }

    /// The window tuned the Kiwi (entry, click, scroll, drag, mode picker):
    /// what to send the rig. A refusal leaves the Kiwi where the window put it.
    public TuneRigDecision WindowTuned(int kiwiFrequencyHz, KiwiSdrMode kiwiMode, KiwiRigSnapshot rig, double now)
    {
        if (Pending is { } expired && now >= expired.Until)
        {
            Pending = null;
        }
        // What the rig is about to be (a send still on its way), so a mode
        // change right after a frequency change isn't sent twice.
        var rigFrequency = Pending?.FrequencyHz ?? rig.FrequencyHz;
        var rigMode = Pending?.Mode ?? rig.Mode;
        var frequencyChanged = !Same(kiwiFrequencyHz, rigFrequency);
        var newMode = kiwiMode.RigModeFor(rigMode);
        if (!frequencyChanged && newMode is null)
        {
            return new TuneRigDecision.Nothing();
        }
        if (RefusalFor(rig) is { } refusal)
        {
            return new TuneRigDecision.Refused(refusal);
        }
        Pending = new PendingRigTune(kiwiFrequencyHz, newMode ?? Pending?.Mode, now + RigTuneGrace);
        return new TuneRigDecision.Send(frequencyChanged ? kiwiFrequencyHz : null, newMode);
    }

    /// Why the rig can't be tuned from the window right now, if it can't.
    public static Refusal? RefusalFor(KiwiRigSnapshot rig)
    {
        if (!rig.Connected) { return Refusal.RigDisconnected; }
        if (rig.FrequencyHz <= 0) { return Refusal.NoRigFrequency; }
        if (rig.Transmitting) { return Refusal.Transmitting; }
        // The rig rejects a VFO frequency set in Memory mode.
        if (rig.MemoryMode) { return Refusal.MemoryMode; }
        return null;
    }

    /// Clears an expired pending tune; true when it did (follow the rig's
    /// actual state again — the tune was rejected or never arrived).
    public bool ExpirePending(double now)
    {
        if (Pending is not { } pending || now < pending.Until)
        {
            return false;
        }
        Pending = null;
        return true;
    }

    /// Disconnect, or Tune rig turned off.
    public void Reset() => Pending = null;

    private static bool Same(int a, int b) => Math.Abs(a - b) <= SameFrequencyToleranceHz;
}

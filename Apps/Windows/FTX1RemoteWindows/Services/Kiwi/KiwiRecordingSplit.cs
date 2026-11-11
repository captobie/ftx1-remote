namespace FTX1RemoteWindows.Services;

/// When the MyKiwiSDR window's recording starts a new file: one file per
/// frequency, like the WebSDR window, without splitting on every scroll-wheel
/// step. Port of the Mac's KiwiRecordingSplit.
///
/// A tune splits only if it moved at least <see cref="ToleranceHz"/> from the
/// tuning the current file started at (its name), or changed the mode, *and*
/// has held for <see cref="SettleSeconds"/>. So nudging a CW signal to zero
/// beat, or a spun wheel passing through, stays in one file; a retune that
/// sticks starts a new one ~1 s later (that second of new audio ends up at the
/// end of the old file). Moving back to the file's own tuning cancels a
/// pending split. Pure, on a caller-supplied clock (seconds).
public sealed class KiwiRecordingSplit
{
    public readonly record struct Tuning(int FrequencyHz, KiwiSdrMode Mode);

    public const int ToleranceHz = 500;
    public const double SettleSeconds = 1;

    /// What the current file is named after.
    public Tuning FileTuning { get; private set; }

    private Tuning? _pending;
    private double _pendingSince;

    public KiwiRecordingSplit(Tuning fileTuning) => FileTuning = fileTuning;

    /// When the caller should call <see cref="Update"/> again (the pending
    /// split's settle time), or null when no split is pending.
    public double? NextCheck => _pending is null ? null : _pendingSince + SettleSeconds;

    /// Call on every tune, and again at <see cref="NextCheck"/>. Returns the
    /// tuning to start a new file at, or null to keep writing the current one.
    public Tuning? Update(Tuning tuning, double now)
    {
        if (!DiffersFromFile(tuning))
        {
            _pending = null;
            return null;
        }
        if (_pending != tuning)
        {
            _pending = tuning;
            _pendingSince = now;
            return null;
        }
        if (now - _pendingSince < SettleSeconds)
        {
            return null;
        }
        FileTuning = tuning;
        _pending = null;
        return tuning;
    }

    private bool DiffersFromFile(Tuning tuning) =>
        tuning.Mode != FileTuning.Mode || Math.Abs(tuning.FrequencyHz - FileTuning.FrequencyHz) >= ToleranceHz;
}

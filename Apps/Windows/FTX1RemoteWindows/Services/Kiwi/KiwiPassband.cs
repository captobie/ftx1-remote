using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// A KiwiSDR passband: low_cut/high_cut in Hz relative to the carrier
/// (negative below it), as sent in "SET mod=… low_cut=… high_cut=… freq=…".
/// Port of the Mac's KiwiPassband.swift: the rules for moving the edges are pure so they can
/// be unit-tested; the waterfall calls them with where the mouse is.
///
/// USB stays above the carrier and LSB below it, AM and FM keep the carrier
/// inside the passband, the width stays at least MinimumWidthHz (the Kiwi's
/// narrowest CW preset). CW is symmetric around the dial: dragging one edge
/// moves both, and the centre stays at the Kiwi's 500 Hz audio pitch until
/// half the width no longer fits below it.
public readonly record struct KiwiPassband(int Low, int High, int CwShiftHz = 0)
{
    public const int SnapHz = 10;
    public const int MinimumWidthHz = 60;
    public const int LimitHz = 6000;
    public const int CwPitchHz = 500;

    public enum Edge { Low, High }

    public static KiwiPassband DefaultFor(KiwiSdrMode mode)
    {
        var band = mode.DefaultPassband();
        return new KiwiPassband(band.Low, band.High);
    }

    public int Width => High - Low;

    /// Where each edge may go in "mode", before the minimum width.
    private static ((int Min, int Max) Low, (int Min, int Max) High) EdgeRanges(KiwiSdrMode mode)
    {
        var halfMinimum = MinimumWidthHz / 2;
        return mode switch
        {
            KiwiSdrMode.Usb or KiwiSdrMode.Cw => ((0, LimitHz - MinimumWidthHz), (MinimumWidthHz, LimitHz)),
            KiwiSdrMode.Lsb => ((-LimitHz, -MinimumWidthHz), (MinimumWidthHz - LimitHz, 0)),
            _ => ((-LimitHz, -halfMinimum), (halfMinimum, LimitHz)),
        };
    }

    /// Whether this passband can be used in "mode" as it stands (a saved
    /// value is checked with this before being trusted).
    public bool IsValid(KiwiSdrMode mode)
    {
        var ranges = EdgeRanges(mode);
        return Low >= ranges.Low.Min && Low <= ranges.Low.Max
            && High >= ranges.High.Min && High <= ranges.High.Max
            && Width >= MinimumWidthHz;
    }

    /// The Kiwi passband matching MAIN's receive filter (see
    /// FilterPassbandModel for where width and SHIFT come from). Null when the
    /// filter fields hold SUB's values, the rig's mode has no Kiwi equivalent,
    /// or the width isn't known. Not snapped: these are the rig's own values.
    ///
    /// SSB/DATA: the audio passband the rig's display model gives, mirrored
    /// below the carrier for LSB, kept on its sideband. CW: the width around
    /// the Kiwi's own pitch, moved by SHIFT with the dial still on the signal
    /// (the rig's KP pitch doesn't apply here). AM/FM: symmetric, as wide as
    /// the Kiwi can go; SHIFT doesn't apply.
    public static KiwiPassband? FromRigFilter(RigState state)
    {
        var effective = FilterPassbandModel.WidthHz(state).Effective;
        if (state.ActiveFilterSide != FilterSide.Main
            || KiwiSdrModeExtensions.FromRigMode(state.FilterMode) is not { } mode
            || state.FilterMode is not { } rigMode
            || effective is not > 0)
        {
            return null;
        }
        var width = effective.Value;
        var shift = FilterPassbandModel.ShiftHz(state);
        switch (mode)
        {
            case KiwiSdrMode.Am or KiwiSdrMode.Fm:
                var halfWidth = Math.Min(width / 2, LimitHz);
                return new KiwiPassband(-halfWidth, halfWidth);
            case KiwiSdrMode.Cw:
                var half = Math.Min(width / 2, LimitHz / 2);
                var cwLow = Math.Max(Math.Max(CwPitchHz - half, 0) + shift, 0);
                return new KiwiPassband(cwLow, Math.Min(cwLow + 2 * half, LimitHz), shift);
            default:
                var centre = (int)FilterPassbandModel.DefaultCenterHz(rigMode, 0) + shift;
                var low = Math.Max(centre - width / 2, 0);
                var high = Math.Min(Math.Max(centre - width / 2 + width, low + 1), LimitHz);
                return mode == KiwiSdrMode.Usb ? new KiwiPassband(low, high) : new KiwiPassband(-high, -low);
        }
    }

    /// The passband after dragging "edge" to offsetHz from the dial, snapped
    /// to SnapHz.
    public KiwiPassband Dragging(Edge edge, double offsetHz, KiwiSdrMode mode)
    {
        var snapped = (int)Math.Round(offsetHz / SnapHz, MidpointRounding.AwayFromZero) * SnapHz;
        if (mode == KiwiSdrMode.Cw)
        {
            return Cw(edge == Edge.Low ? -snapped : snapped);
        }
        var ranges = EdgeRanges(mode);
        if (edge == Edge.Low)
        {
            var upper = Math.Min(ranges.Low.Max, High - MinimumWidthHz);
            return this with { Low = Math.Min(Math.Max(snapped, ranges.Low.Min), upper) };
        }
        var lower = Math.Max(ranges.High.Min, Low + MinimumWidthHz);
        return this with { High = Math.Max(Math.Min(snapped, ranges.High.Max), lower) };
    }

    /// A CW passband halfWidth either side of the signal (clamped to what fits).
    public static KiwiPassband Cw(int halfWidth)
    {
        var half = Math.Min(Math.Max(halfWidth, MinimumWidthHz / 2), LimitHz / 2);
        var low = Math.Max(CwPitchHz - half, 0);
        return new KiwiPassband(low, low + 2 * half);
    }

    /// "300–2700 Hz": LSB as positive audio offsets, AM/FM with signs.
    /// Unit-only, so not localized.
    public string RangeText(KiwiSdrMode mode) => mode switch
    {
        KiwiSdrMode.Usb or KiwiSdrMode.Cw => $"{Low}–{High} Hz",
        KiwiSdrMode.Lsb => $"{-High}–{-Low} Hz",
        _ => $"{Signed(Low)}…{Signed(High)} Hz",
    };

    private static string Signed(int value) => value > 0 ? $"+{value}" : value.ToString();
}

namespace FTX1RemoteWindows.Models;

/// Mirrors Sources/FTX1Core/RigState/RigState.swift's RigMode — the raw
/// values are hamlib's own mode vocabulary (what CommandQueue.apply's
/// .setMode case sends verbatim via the "M" rigctld command), so these
/// strings are load-bearing, not display labels. C4FM is intentionally
/// left out of v1: on the Swift side it requires a raw CAT passthrough
/// (RigctldClient.setActiveModeC4FM(), "MD0H") instead of the generic "M"
/// verb, which this v1 client skeleton doesn't implement yet — see
/// Apps/Windows/README.md's porting table.
public enum RigMode
{
    Usb,
    Lsb,
    Cw,
    Fm,
    Am,
    Rtty,
    DataUsb,
    DataFm,
}

public static class RigModeExtensions
{
    /// The hamlib mode string CommandQueue.apply sends over "M currVFO <raw> 0".
    public static string RawValue(this RigMode mode) => mode switch
    {
        RigMode.Usb => "USB",
        RigMode.Lsb => "LSB",
        RigMode.Cw => "CW",
        RigMode.Fm => "FM",
        RigMode.Am => "AM",
        RigMode.Rtty => "RTTY",
        RigMode.DataUsb => "PKTUSB",
        RigMode.DataFm => "FM-D",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    /// What the CAT manual/operators call the mode, vs. hamlib's raw
    /// vocabulary — same distinction RigState.swift's displayName draws.
    public static string DisplayName(this RigMode mode) => mode switch
    {
        RigMode.DataUsb => "DATA-U",
        RigMode.DataFm => "DATA-FM",
        _ => mode.RawValue(),
    };

    /// Parses a raw hamlib mode string back into a RigMode, as read from
    /// rigctld's "m currVFO" reply. Returns null for anything unrecognized
    /// (e.g. C4FM's "H"/"I" raw CAT codes, which never come back through
    /// this generic path — same gap RigState.swift's RigMode(rawValue:)
    /// leaves for its own .c4fm/.unknown cases).
    public static RigMode? FromRawValue(string raw) => raw switch
    {
        "USB" => RigMode.Usb,
        "LSB" => RigMode.Lsb,
        "CW" => RigMode.Cw,
        "FM" => RigMode.Fm,
        "AM" => RigMode.Am,
        "RTTY" => RigMode.Rtty,
        "PKTUSB" => RigMode.DataUsb,
        "FM-D" => RigMode.DataFm,
        _ => null,
    };
}

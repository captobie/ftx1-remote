using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// The actions that key the transmitter, in their "on" direction only —
/// same set as HubService.isTransmitCapable on the Mac (Apps/Mac/
/// FTX1RemoteMac/HubService.swift). Turning PTT or MOX *off* is never
/// gated: the unkey direction must always get through, including the
/// force-unkey when Enable Transmit is switched off.
///
/// PTT, the MENU grid's MOX and ANT TUNE (SSB page) and the CW window's
/// send pane (PlayCwTextMemory, "KY0n") use this today. PlayCwMessage is
/// listed so CW MESSAGE, if it's ever enabled (it's a disabled placeholder
/// on the Mac), goes through the same check instead of inventing its own.
public enum TransmitAction
{
    PttOn,
    MoxOn,
    PlayCwMessage,
    PlayCwTextMemory,
    TriggerAntennaTune,
}

/// Port of the Mac's transmit gate (FTX1Core's TransmitGate.blockReason,
/// which HubService.send and the PTT button use): a transmit action goes
/// through only while Enable Transmit is on AND the transmitting side
/// (SUB with TX:SUB or split, the TXRX tags' rule) is inside an amateur
/// allocation (BandPlan) AND, with Settings → License on, its signal fits
/// inside those privileges. Every transmit-capable command must call
/// <see cref="BlockReason"/> first.
public static class TransmitGate
{
    /// Null when the action may go ahead, otherwise why not (shown to the
    /// user). A frequency of 0 (not read yet) is outside every band, so
    /// nothing keys before the first poll — same as the Mac. The
    /// amateur-band check stays the outer limit, so a mistyped custom
    /// segment can't open a broadcast band.
    public static string? BlockReason(TransmitAction action, bool transmitEnabled, TransmitSignal transmitter,
        PrivilegeProfile? privileges = null)
    {
        if (!transmitEnabled)
        {
            return Loc.S("transmitGate.transmitDisabled");
        }
        if (BandPlan.BandContaining(transmitter.FrequencyHz) is null)
        {
            return Loc.S("transmitGate.transmitDisabledOutsideAn");
        }
        if (privileges is not null)
        {
            if (transmitter.ModeKey is null)
            {
                return Loc.S("transmitGate.transmitDisabledTheTransmitting");
            }
            if (!privileges.Allows(transmitter))
            {
                return Loc.F("transmitGate.transmitDisabledXOn", transmitter.ModeDisplayName, FormatMHz(transmitter.FrequencyHz), privileges.Name);
            }
        }
        return null;
    }

    /// "14.225.000"-style, the VFO boxes' grouping.
    public static string FormatMHz(long hz) => $"{hz / 1_000_000}.{hz / 1_000 % 1_000:000}.{hz % 1_000:000}";
}

using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// The actions that key the transmitter, in their "on" direction only —
/// same set as HubService.isTransmitCapable on the Mac (Apps/Mac/
/// FTX1RemoteMac/HubService.swift). Turning PTT or MOX *off* is never
/// gated: the unkey direction must always get through, including the
/// force-unkey when Enable Transmit is switched off.
///
/// PTT, and the MENU grid's MOX and ANT TUNE (SSB page), use this today.
/// PlayCwMessage is listed so CW MESSAGE, if it's ever enabled (it's a
/// disabled placeholder on the Mac), goes through the same check instead of
/// inventing its own.
public enum TransmitAction
{
    PttOn,
    MoxOn,
    PlayCwMessage,
    TriggerAntennaTune,
}

/// Port of the Mac's transmit gate (HubService.send's two checks, and
/// ContentView.canTransmit which mirrors them for the PTT button): a
/// transmit action goes through only while Enable Transmit is on AND the
/// Main VFO is inside an amateur allocation (BandPlan). Every
/// transmit-capable command must call <see cref="BlockReason"/> first.
public static class TransmitGate
{
    /// Null when the action may go ahead, otherwise why not (shown to the
    /// user). A frequency of 0 (not read yet) is outside every band, so
    /// nothing keys before the first poll — same as the Mac.
    public static string? BlockReason(TransmitAction action, bool transmitEnabled, long frequencyHz)
    {
        if (!transmitEnabled)
        {
            return "Transmit disabled";
        }
        if (BandPlan.BandContaining(frequencyHz) is null)
        {
            return "Transmit disabled: outside an amateur band";
        }
        return null;
    }
}

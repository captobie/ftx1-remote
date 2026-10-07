namespace FTX1RemoteWindows.Models;

/// The rig's own memory scan, per P7 of the raw "RI0" answer — the Mac's
/// MemoryScanState (Sources/FTX1Core/RigState/MemoryScan.swift). One state
/// for the whole radio: "RI0" covers SUB scans too ("RI1" answers "?;").
public enum MemoryScanState
{
    Stopped,
    Scanning,
    /// Stopped on a busy channel; the rig resumes on its own per its SCAN
    /// RESUME menu setting, or when told to scan again (a Skip).
    Paused,
}

/// The raw "RI0" answer: "RI" + P1..P8 + ";", one digit each — the Mac's
/// RadioInformation. Probed against the rig 2026-10-06: P7 0/1/2 =
/// stopped/scanning/paused and P8 = squelch open (e.g. "RI00000021;"
/// paused on a busy channel). Only the fields the app uses are kept.
public sealed record RadioInformation(bool IsTransmitting, MemoryScanState Scan, bool SquelchOpen)
{
    /// Null for an answer of the wrong shape.
    public static RadioInformation? Parse(string reply)
    {
        if (!reply.StartsWith("RI", StringComparison.Ordinal))
        {
            return null;
        }
        var digits = reply.Skip(2).TakeWhile(char.IsAsciiDigit).Select(c => c - '0').ToArray();
        if (digits.Length < 8)
        {
            return null;
        }
        var scan = digits[6] switch
        {
            1 => MemoryScanState.Scanning,
            2 => MemoryScanState.Paused,
            _ => MemoryScanState.Stopped,
        };
        // P4: 1 TX, 2 TX INHIBIT (both keyed), 0 RX.
        return new RadioInformation(digits[3] != 0, scan, digits[7] == 1);
    }
}

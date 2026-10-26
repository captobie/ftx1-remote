using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services.Hub;

/// What a memory scan stop before a hub command does with the TX side the
/// scan moved (MainWindow.MemoryScan.cs's ScanStopTxSide).
public enum HubScanStop
{
    /// Put it back: a tune, mode, swap or recall.
    Restore,
    /// Leave it: something is about to transmit on the side shown now.
    Keep,
}

/// The decisions RigCommandDispatcher makes before running a hub command,
/// as pure functions so they're unit-tested (FTX1RemoteWindows.Tests):
/// the transmit gate, the memory-scan stop-before rule, and values that
/// mustn't reach the rig. The Mac's HubService.send(_:), isTransmitCapable
/// and memoryScanStop(for:scanSide:).
public static class HubCommandPolicy
{
    /// The transmit gate's action for a command that keys the rig, in its
    /// keying direction only; null for everything else. Stops ("KY00",
    /// "KY10", MOX/PTT off) are never gated.
    public static TransmitAction? TransmitActionFor(RigCommand command) => command switch
    {
        SetPtt { On: true } => TransmitAction.PttOn,
        SetMox { On: true } => TransmitAction.MoxOn,
        TriggerAntennaTune => TransmitAction.TriggerAntennaTune,
        PlayCwTextMemory { Value: not 0 } => TransmitAction.PlayCwTextMemory,
        PlayCwMessage { Value: not 0 } => TransmitAction.PlayCwMessage,
        _ => null,
    };

    /// Why a command is refused before it reaches the rig, or null.
    /// <paramref name="transmitter"/> is the transmitting side's signal
    /// (SUB's with TX:SUB or split), as for every gate here and on the Mac;
    /// <paramref name="privileges"/> Settings → License's, null when off.
    public static string? RefusalReason(RigCommand command, bool transmitEnabled, TransmitSignal transmitter,
        PrivilegeProfile? privileges = null)
    {
        if (TransmitActionFor(command) is { } action
            && TransmitGate.BlockReason(action, transmitEnabled, transmitter, privileges) is { } reason)
        {
            return reason;
        }
        return ValueProblem(command);
    }

    /// The Mac's memoryScanStop(for:scanSide:): whether a command stops a
    /// running scan first, and what happens to the TX side. Null leaves the
    /// scan running (settings, the other side's controls). "F currVFO",
    /// "M currVFO" and "CH" follow the rig's active side, which a SUB scan
    /// made SUB, so they stop either side's scan; restoring the TX side
    /// first lands them on MAIN as meant. Only called for commands that
    /// passed <see cref="RefusalReason"/>.
    public static HubScanStop? MemoryScanStop(RigCommand command, bool scanSub)
    {
        if (TransmitActionFor(command) is not null)
        {
            return HubScanStop.Keep;
        }
        return command switch
        {
            SetFrequency or SetMode or SetBand or SwapActiveVfo or StepMemoryChannel => HubScanStop.Restore,
            SetVfoMemoryMode or SetMemoryChannel => scanSub ? null : HubScanStop.Restore,
            SetSecondaryFrequency or SetSecondaryMode or SetSubMemoryChannel or StepSubMemoryChannel =>
                scanSub ? HubScanStop.Restore : null,
            RecallMemoryChannel recall => recall.Sub == scanSub ? HubScanStop.Restore : null,
            _ => null,
        };
    }

    /// A value the rig shouldn't be sent: outside what the matching MENU
    /// grid control can set, or something that would break the CAT command
    /// (a ";" in a Deep Settings value ends it and starts another). The Mac
    /// trusts its clients more; the rig would reject most of these with
    /// "?;", but a negative or over-wide number renders a different command.
    public static string? ValueProblem(RigCommand command) => command switch
    {
        SetFrequency { Hz: <= 0 } or SetSecondaryFrequency { Hz: <= 0 } => "frequency must be positive",
        SetMode { Mode: HubMode.Unknown } or SetSecondaryMode { Mode: HubMode.Unknown } => "UNKNOWN isn't a mode to set",
        SetBand band when BandPlan.BandNamed(band.Band) is null =>
            $"no band \"{band.Band}\" here (this app has the amateur bands only, no general-coverage segments)",
        SetPowerLevel { Value: < 0 or > 1 } => "power level must be 0.0-1.0",
        SetCwSpeed c => Range(c.Value, 4, 60),
        SetCwPitch c => c.Value is < 300 or > 1050 || c.Value % 10 != 0 ? "pitch must be 300-1050 Hz in 10 Hz steps" : null,
        SetBreakInDelay c => RigDelayCode.Code(c.Value) is null ? $"{c.Value} ms isn't one of the rig's delays" : null,
        SetVoxDelay c => RigDelayCode.Code(c.Value) is null ? $"{c.Value} ms isn't one of the rig's delays" : null,
        SetMoniLevel c => Range(c.Value, 0, 100),
        SelectCwMessageChannel c => Range(c.Value, 1, 5),
        PlayCwMessage c => Range(c.Value, 0, 5),
        PlayCwTextMemory c => Range(c.Value, 0, 5),
        SetPreamp c => Range(c.Value, 0, 2),
        SetDisplayContrast c => Range(c.Value, 0, 20),
        SetDisplayDimmer c => Range(c.Value, 0, 20),
        SetDisplayLevel { Value: < -30 or > 30 } => "display level must be -30 to +30 dB",
        SetDisplayPeak c => Range(c.Value, 0, 4),
        SetMicGain c => Range(c.Value, 0, 100),
        SetAmcLevel c => Range(c.Value, 1, 100),
        SetVoxGain c => Range(c.Value, 0, 100),
        SetAgc c => Range(c.Value, 0, 4),
        SetProcLevel c => Range(c.Value, 0, 100),
        SetNbLevel c => Range(c.Value, 0, 10),
        SetDnrLevel c => Range(c.Value, 0, 10),
        SetFilterWidth c => Range(c.Value, 0, 99),
        SetAntSelect c => Range(c.Value, 0, 1),
        SetSquelchType c => Range(c.Value, 0, 5),
        SetToneFrequency c => Range(c.Value, 0, RigCtcssTone.AllValuesHz.Length - 1),
        SetDcsCode c => Range(c.Value, 0, RigDcsCode.AllValues.Length - 1),
        SetRepeaterShift c => Range(c.Value, 0, 3),
        SetAprsBeaconType c => Range(c.Value, 0, 2),
        SetFmChannelStep c => Range(c.Value, 0, 5),
        SetMemoryChannel c => Range(c.Value, 1, 999),
        SetSubMemoryChannel c => Range(c.Value, 1, 999),
        RecallMemoryChannel c => Range(c.Channel, 1, 999),
        SetMenuItem item => MenuItemProblem(item),
        _ => null,
    };

    private static string? Range(int value, int min, int max) =>
        value < min || value > max ? $"{value} is outside {min}-{max}" : null;

    private static string? MenuItemProblem(SetMenuItem item)
    {
        if (item.P1 is < 0 or > 99 || item.P2 is < 0 or > 99 || item.P3 is < 0 or > 99)
        {
            return "menu address must be two digits each";
        }
        if (item.RawValue.Length == 0 || item.RawValue.Any(c => c is ';' or < ' ' or > '~'))
        {
            return "menu value must be printable ASCII without \";\"";
        }
        return null;
    }
}

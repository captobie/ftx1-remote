namespace FTX1RemoteWindows.Models;

/// Port of RigState.swift's RigDelayCode: the non-linear 00-33 code the
/// "SD" (BK-DELAY) and "VD" (VOX DELAY) commands use instead of
/// milliseconds — 30, 50, 100, 150, 200, 250 ms, then 300-3000 ms in 100 ms
/// steps. Hardware-confirmed on the Mac for "VD" despite the manual's
/// inconsistent step-size note.
public static class RigDelayCode
{
    public const int MaxCode = 33;

    public static int? Milliseconds(int code) => code switch
    {
        0 => 30,
        1 => 50,
        2 => 100,
        3 => 150,
        4 => 200,
        5 => 250,
        >= 6 and <= MaxCode => 300 + (code - 6) * 100,
        _ => null,
    };

    public static int? Code(int milliseconds)
    {
        for (var code = 0; code <= MaxCode; code++)
        {
            if (Milliseconds(code) == milliseconds)
            {
                return code;
            }
        }
        return null;
    }
}

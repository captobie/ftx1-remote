namespace FTX1RemoteWindows.Models;

/// The rig's scope color scheme (MENU D-COLOR), "SS"'s COLOR sub-function
/// (P2=3). Index 0-10 = COLOR-1…COLOR-11; P3 on the wire is one character,
/// "0"-"9" then "A". Port of SpectrumScopeColor.swift (source of truth).
public static class SpectrumScopeColor
{
    public const int Count = 11;

    public static char? Code(int index) =>
        index is >= 0 and < Count ? char.ToUpperInvariant(index.ToString("X")[0]) : null;

    public static int? IndexFromCode(char code)
    {
        var c = char.ToUpperInvariant(code);
        if (c is >= '0' and <= '9') return c - '0';
        if (c == 'A') return 10;
        return null;
    }

    /// Parses a "SS03" answer such as "SS0300000;" or "SS03A0000;".
    public static int? IndexFromAnswer(string reply) =>
        reply.StartsWith("SS03", StringComparison.Ordinal) && reply.Length > 4 ? IndexFromCode(reply[4]) : null;

    /// The set command without ";", e.g. 10 -> "SS03A0000".
    public static string? SetCommand(int index) =>
        Code(index) is { } code ? $"SS03{code}0000" : null;

    /// "COLOR-1"…"COLOR-11" (the rig's label, not localized), "—" when unknown.
    public static string Label(int? index) =>
        index is >= 0 and < Count ? $"COLOR-{index + 1}" : "—";
}

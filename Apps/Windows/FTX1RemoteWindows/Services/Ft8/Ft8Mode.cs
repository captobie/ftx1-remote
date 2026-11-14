namespace FTX1RemoteWindows.Services.Ft8;

/// FT8 or FT4 — the Mac's FT8Kit.Mode (Sources/FT8Kit/FT8Mode.swift, the
/// source of truth). ft8_lib shares its LDPC(174,91) code between them; only
/// slot/symbol timing and the sync pattern differ.
public enum Ft8Mode
{
    Ft8,
    Ft4,
}

public static class Ft8ModeExtensions
{
    /// "FT8"/"FT4": the ADIF/PSK Reporter mode name.
    public static string Name(this Ft8Mode mode) => mode == Ft8Mode.Ft8 ? "FT8" : "FT4";

    public static double SlotSeconds(this Ft8Mode mode) => mode == Ft8Mode.Ft8 ? 15.0 : 7.5;

    public static double SymbolPeriodSeconds(this Ft8Mode mode) => mode == Ft8Mode.Ft8 ? 0.160 : 0.048;

    /// Samples <see cref="Ft8Decoder.Process"/> takes per call at this rate.
    public static int BlockSize(this Ft8Mode mode, int sampleRate) =>
        (int)Math.Round(sampleRate * mode.SymbolPeriodSeconds(), MidpointRounding.ToEven);
}

/// What kind of token a slice of a decoded message is (ft8_lib's ftx_field_t).
public enum Ft8FieldKind
{
    Unknown,
    None,
    /// RRR, RR73, 73, DE, QRZ, CQ, …
    Token,
    /// CQ nnn, CQ abcd
    TokenWithArg,
    Call,
    Grid,
    Rst,
}

/// One space-separated token of a decoded message.
public sealed record Ft8MessageField(Ft8FieldKind Kind, string Text);

/// One decoded FT8/FT4 candidate — a faithful mirror of ft8_lib's output
/// (the Mac's FT8Kit.RawMessage), not yet mapped to <see cref="Ft8Spot"/>.
/// Score is the sync-candidate score, not a calibrated SNR.
public sealed record Ft8RawMessage(
    string Text,
    IReadOnlyList<Ft8MessageField> Fields,
    double FrequencyOffsetHz,
    double DtSeconds,
    int Score,
    int LdpcErrors);

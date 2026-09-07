namespace FTX1RemoteWindows.Models;

/// v1 subset of Sources/FTX1Core/RigState/RigState.swift's ~40-field
/// struct — just what core rig control needs (VFO A/B, mode, PTT, power,
/// SWR, band). The rest (CW/menu/display/APRS state) is out of v1 scope;
/// add fields here only as the corresponding feature actually gets built,
/// per Apps/Windows/README.md's deferred-features list.
public sealed class RigState
{
    public long FrequencyHz { get; set; }
    public RigMode? Mode { get; set; }
    public string? Band { get; set; }
    public double? PowerWatts { get; set; }
    public double? Swr { get; set; }
    public bool Ptt { get; set; }
    public DateTimeOffset LastUpdated { get; set; } = DateTimeOffset.Now;

    /// The other VFO's frequency — see RigctldClient.GetSecondaryFrequencyAsync().
    public long? SecondaryFrequencyHz { get; set; }

    /// The RFPOWER *setting* (0.0-1.0, relative), not the metered output —
    /// that's PowerWatts. Same distinction as RigState.swift's powerLevel.
    public double? PowerLevel { get; set; }
}

namespace FTX1RemoteWindows.Models;

/// Subset of Sources/FTX1Core/RigState/RigState.swift's struct: core rig
/// control (VFO A/B, mode, PTT, power, SWR, band) plus the MENU grid pages
/// ported so far. Add fields here only as the corresponding feature
/// actually gets built, per Apps/Windows/README.md's Mac parity plan.
public sealed class RigState
{
    public long FrequencyHz { get; set; }
    public RigMode? Mode { get; set; }
    public string? Band { get; set; }
    public double? PowerWatts { get; set; }
    public double? Swr { get; set; }
    public bool Ptt { get; set; }

    /// Main's signal strength in dB relative to S9 (hamlib's STRENGTH).
    /// Unlike the text fields, a failed read clears it, so the meter falls
    /// to rest instead of freezing — same as the Mac.
    public double? SmeterDb { get; set; }
    /// Sub's, from raw "RM2" via SMeterScale.StrengthDb — hamlib's STRENGTH
    /// only reads the active side.
    public double? SubSmeterDb { get; set; }
    /// COMP/ALC/ID/VDD, read only while transmitting.
    public TxMeterReadings? TxMeters { get; set; }
    public DateTimeOffset LastUpdated { get; set; } = DateTimeOffset.Now;

    /// The other VFO's frequency — see RigctldClient.GetSecondaryFrequencyAsync().
    public long? SecondaryFrequencyHz { get; set; }

    /// The RFPOWER *setting* (0.0-1.0, relative), not the metered output —
    /// that's PowerWatts. Same distinction as RigState.swift's powerLevel.
    public double? PowerLevel { get; set; }

    // MENU grid, SSB page (Controls/MenuGrid.cs). Raw CAT settings, null
    // until first read; same names and encodings as RigState.swift.

    /// "SS04" spectrum scope level, -30.0 to +30.0 dB.
    public double? DisplayLevel { get; set; }
    /// "SS01" peak hold, 0-4 (shown LV1-LV5).
    public int? DisplayPeak { get; set; }
    /// "SS02" marker.
    public bool? DisplayMarker { get; set; }
    /// "DA" P2, 0-20.
    public int? DisplayContrast { get; set; }
    /// "DA" P3 (TFT brightness), 0-20.
    public int? DisplayDimmer { get; set; }
    /// "MX".
    public bool? MoxEnabled { get; set; }
    /// "RA0".
    public bool? AttEnabled { get; set; }
    /// "PA0": 0 IPO, 1 AMP1, 2 AMP2.
    public int? PreampMode { get; set; }
    /// "BC0" auto notch.
    public bool? DnfEnabled { get; set; }
    /// "GT0" as read: 0 OFF, 1 FAST, 2 MID, 3 SLOW, 4-6 AUTO (the read side
    /// reports AUTO's sub-states; the set side takes 0-4 only).
    public int? AgcMode { get; set; }
    /// "PR1" parametric mic EQ (plain 0/1, not the manual's 1/2).
    public bool? MicEqEnabled { get; set; }
    /// "PL", 0-100, 0 = OFF.
    public int? ProcLevel { get; set; }
    /// "AC" P3.
    public bool? TunerEnabled { get; set; }
    /// "NL0", 0-10, 0 = OFF.
    public int? NbLevel { get; set; }
    /// "RL0", 0-10, 0 = OFF.
    public int? DnrLevel { get; set; }
    /// "EX030704" HF ANT SELECT: 0 ANT1, 1 ANT2.
    public int? AntSelect { get; set; }
    /// "MG", 0-100.
    public int? MicGain { get; set; }
    /// "AO", 1-100.
    public int? AmcLevel { get; set; }
    /// "VX".
    public bool? VoxEnabled { get; set; }
    /// "VG", 0-100.
    public int? VoxGain { get; set; }
    /// "VD" in milliseconds (decoded from its 00-33 code, see RigDelayCode).
    public int? VoxDelayMs { get; set; }

    // MENU grid, CW page.

    /// "ML1" MONI level, 0-100, 0 = OFF.
    public int? MoniLevel { get; set; }
    /// "KR" electronic keyer.
    public bool? KeyerEnabled { get; set; }
    /// "BI" break-in.
    public bool? BreakIn { get; set; }
    /// "KS", 4-60 WPM.
    public int? CwSpeedWpm { get; set; }
    /// "KP" in Hz, 300-1050 (decoded from its 00-75 code: 300 + 10 × code).
    public int? CwPitchHz { get; set; }
    /// "SD" in milliseconds (same 00-33 code as "VD", see RigDelayCode).
    public int? BkDelayMs { get; set; }
    /// "CS" CW spot tone.
    public bool? CwSpot { get; set; }

    // MENU grid, FM/C4FM page.

    /// "OS0": 0 SIMPLEX, 1 +, 2 -, 3 ARS.
    public int? RepeaterShiftMode { get; set; }
    /// "EX070101" APRS BEACON TYPE: 0 OFF, 1 AUTO, 2 SMART.
    public int? AprsBeaconType { get; set; }
    /// "EX030606" FM CH STEP: 0-5 = 5, 6.25, 10, 12.5, 20, 25 kHz.
    public int? FmChannelStep { get; set; }
    /// "CT0": 0 OFF, 1 ENC, 2 TSQ, 3 DCS, 4 PR FREQ, 5 REV TONE.
    public int? SquelchType { get; set; }
    /// "CN00" index into RigCtcssTone.AllValuesHz (0-49).
    public int? CtcssToneIndex { get; set; }
    /// "CN01" index into RigDcsCode.AllValues (0-103).
    public int? DcsCodeIndex { get; set; }
}

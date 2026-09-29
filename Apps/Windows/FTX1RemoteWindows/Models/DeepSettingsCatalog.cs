using System.Globalization;
using static FTX1RemoteWindows.Models.DeepSettingValueType;

namespace FTX1RemoteWindows.Models;

/// How one Deep Settings item's CAT value (P4 of the "EX" command) is
/// shaped, per the CAT manual's "Table 3 (MENU Chart)" — port of the Swift
/// DeepSettingValueType (Sources/FTX1Core/MenuSettings/
/// DeepSettingsCatalog.swift). `Digits` is always the magnitude width; a
/// SignedRange's wire value also carries a leading sign not counted in it.
public abstract class DeepSettingValueType
{
    public readonly record struct EnumerationCase(int Index, string Label);

    public sealed class Toggle(string offLabel, string onLabel) : DeepSettingValueType
    {
        public string OffLabel { get; } = offLabel;
        public string OnLabel { get; } = onLabel;
    }

    public sealed class Enumeration(IReadOnlyList<EnumerationCase> cases, int digits) : DeepSettingValueType
    {
        public IReadOnlyList<EnumerationCase> Cases { get; } = cases;
        public int Digits { get; } = digits;
    }

    /// `Step` is the editor's increment (e.g. 20 for a "20msec/step"
    /// field); decode/encode round-trip the raw value regardless of step.
    public sealed class IntRange(int min, int max, int digits, string? unit, int step) : DeepSettingValueType
    {
        public int Min { get; } = min;
        public int Max { get; } = max;
        public int Digits { get; } = digits;
        public string? Unit { get; } = unit;
        public int Step { get; } = step;
    }

    public sealed class SignedRange(int min, int max, int digits, string? unit, int step) : DeepSettingValueType
    {
        public int Min { get; } = min;
        public int Max { get; } = max;
        public int Digits { get; } = digits;
        public string? Unit { get; } = unit;
        public int Step { get; } = step;
    }

    public sealed class Text(int maxLength) : DeepSettingValueType
    {
        public int MaxLength { get; } = maxLength;
    }

    /// P4 is documented as "—" (a list, ID, or other non-editable readout).
    public sealed class ReadOnly : DeepSettingValueType;

    /// Momentary or irreversible (CALIBRATION, ALL RESET, FIRMWARE UPDATE,
    /// MENU/MEM LOAD & SAVE, FORMAT, ...) — deliberately never fired from
    /// the Deep Settings screen, only shown disabled. The Swift `.action`.
    public sealed class Momentary : DeepSettingValueType;
}

/// One row of Table 3: a deep SET-mode setting addressed by P1/P2/P3
/// (category/tab/item) through "EX". Values are decoded as bool (Toggle),
/// int (Enumeration index, IntRange, SignedRange) or string (Text).
public sealed class DeepSettingItem(int p1, int p2, int p3, string category, string tab, string label, DeepSettingValueType valueType)
{
    public int P1 { get; } = p1;
    public int P2 { get; } = p2;
    public int P3 { get; } = p3;
    public string Category { get; } = category;
    public string Tab { get; } = tab;
    public string Label { get; } = label;
    public DeepSettingValueType ValueType { get; } = valueType;

    public string Id => $"{P1}.{P2}.{P3}";

    /// A raw P4 string (from RigctldClient.GetMenuItemAsync) as bool, int or
    /// string per ValueType; null for ReadOnly/Momentary items or malformed
    /// input. Same rules as the Swift decode(_:).
    public object? Decode(string raw) => ValueType switch
    {
        Toggle => raw switch { "1" => true, "0" => false, _ => null },
        Enumeration e => ParsePrefix(raw, e.Digits),
        IntRange r => ParsePrefix(raw, r.Digits),
        SignedRange => int.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var v) ? v : null,
        Text => raw,
        _ => null,
    };

    /// The raw P4 string RigctldClient.SetMenuItemAsync sends; the inverse
    /// of Decode. Null if the value doesn't fit the type.
    public string? Encode(object value) => (ValueType, value) switch
    {
        (Toggle, bool on) => on ? "1" : "0",
        (Enumeration e, int index) => Pad(index, e.Digits),
        (IntRange r, int v) => Pad(v, r.Digits),
        (SignedRange r, int v) => (v < 0 ? "-" : "+") + Pad(Math.Abs(v), r.Digits),
        (Text t, string s) => s.Length > t.MaxLength ? s[..t.MaxLength] : s,
        _ => null,
    };

    private static object? ParsePrefix(string raw, int digits)
    {
        var prefix = raw.Length > digits ? raw[..digits] : raw;
        return int.TryParse(prefix, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : null;
    }

    private static string Pad(int value, int digits) =>
        value.ToString(CultureInfo.InvariantCulture).PadLeft(digits, '0');
}

/// The FTX-1's deep SET-mode settings — a straight port of the Swift
/// DeepSettingsCatalog (Sources/FTX1Core/MenuSettings/
/// DeepSettingsCatalog.swift), rows in the same order with the same
/// addresses, types and hardware notes. That file is the source of truth:
/// a correction there (the manual has been wrong in several confirmed
/// ways) needs making here too. The rows were translated from it
/// mechanically rather than retyped.
public static class DeepSettingsCatalog
{
    public static readonly (int P1, string Name)[] Categories =
    [
        (1, "RADIO SETTING"),
        (2, "CW SETTING"),
        (3, "OPERATION SETTING"),
        (4, "DISPLAY SETTING"),
        (5, "EXTENSION SETTING"),
        (6, "APRS SETTING"),
        (7, "APRS BEACON"),
        (8, "APRS FILTER"),
    ];

    public static IEnumerable<DeepSettingItem> ItemsForTab(int p1, int p2) =>
        Items.Where(i => i.P1 == p1 && i.P2 == p2);

    /// The (P1, P2) tabs of the given categories in catalog order, each
    /// named after its items' tab — the Swift tabs(forP1s:).
    public static List<(int P1, int P2, string Name)> Tabs(IReadOnlyCollection<int> p1s)
    {
        var result = new List<(int P1, int P2, string Name)>();
        foreach (var item in Items.Where(i => p1s.Contains(i.P1)))
        {
            if (!result.Any(t => t.P1 == item.P1 && t.P2 == item.P2))
            {
                result.Add((item.P1, item.P2, item.Tab));
            }
        }
        return result;
    }

    /// Case lists built in a loop rather than listed (the Swift closures).
    private static List<EnumerationCase> OffThen(int count, Func<int, string> label)
    {
        var cases = new List<EnumerationCase> { new(0, "OFF") };
        for (var index = 1; index <= count; index++)
        {
            cases.Add(new(index, label(index)));
        }
        return cases;
    }

    private static string Hz(double hz) => hz.ToString("0.0", CultureInfo.InvariantCulture) + " Hz";

    /// Shared across the MODE SSB/AM/FM/DATA/RTTY (and CW) tabs; see the
    /// Swift RadioSettingShared for why they're declared once from MODE
    /// SSB's cells.
    private static class RadioShared
    {
        public static readonly DeepSettingValueType SignedGain = new SignedRange(-20, 10, digits: 2, unit: "dB", step: 1);
        public static readonly DeepSettingValueType AgcDelay = new IntRange(20, 4000, digits: 4, unit: "msec", step: 20);
        public static readonly DeepSettingValueType CutSlope = new Enumeration([new(0, "6 dB/oct"), new(1, "18 dB/oct")], digits: 1);
        public static readonly DeepSettingValueType OutLevel = new IntRange(0, 100, digits: 3, unit: null, step: 1);
        public static readonly DeepSettingValueType TxBpfSel = new Enumeration(
        [
            new(0, "50-3050 Hz"), new(1, "100-2900 Hz"), new(2, "200-2800 Hz"), new(3, "300-2700 Hz"), new(4, "400-2600 Hz"),
        ], digits: 1);
        public static readonly DeepSettingValueType ModSource = new Enumeration(
            [new(0, "MIC"), new(1, "USB"), new(2, "Bluetooth"), new(3, "AUTO")], digits: 1);
        public static readonly DeepSettingValueType RpttSelect = new Enumeration(
            [new(0, "OFF"), new(1, "RTS"), new(2, "DTR")], digits: 1);

        /// 00: OFF, 01-19: 100 Hz-1000 Hz in 50 Hz steps.
        public static readonly List<EnumerationCase> LcutFreqCases = OffThen(19, i => $"{100 + (i - 1) * 50} Hz");

        /// 00: OFF, 01-67: 700 Hz-4000 Hz in 50 Hz steps.
        public static readonly List<EnumerationCase> HcutFreqCases = OffThen(67, i => $"{700 + (i - 1) * 50} Hz");

        /// MODE SSB's NAR WIDTH list (non-linear; not MODE DATA/RTTY's).
        public static readonly EnumerationCase[] SsbNarWidthCases =
        [
            new(0, "300 Hz"), new(1, "400 Hz"), new(2, "600 Hz"), new(3, "850 Hz"), new(4, "1100 Hz"),
            new(5, "1200 Hz"), new(6, "1500 Hz"), new(7, "1650 Hz"), new(8, "1800 Hz"), new(9, "1950 Hz"),
            new(10, "2100 Hz"), new(11, "2250 Hz"), new(12, "2400 Hz"), new(13, "2450 Hz"), new(14, "2500 Hz"),
            new(15, "2600 Hz"), new(16, "2700 Hz"), new(17, "2800 Hz"), new(18, "2900 Hz"), new(19, "3000 Hz"),
            new(20, "3200 Hz"), new(21, "3500 Hz"), new(22, "4000 Hz"),
        ];

        /// MODE DATA/RTTY's (and CW's) shared NAR WIDTH list.
        public static readonly EnumerationCase[] DataNarWidthCases =
        [
            new(0, "50 Hz"), new(1, "100 Hz"), new(2, "150 Hz"), new(3, "200 Hz"), new(4, "250 Hz"),
            new(5, "300 Hz"), new(6, "350 Hz"), new(7, "400 Hz"), new(8, "450 Hz"), new(9, "500 Hz"),
            new(10, "600 Hz"), new(11, "800 Hz"), new(12, "1200 Hz"), new(13, "1400 Hz"), new(14, "1700 Hz"),
            new(15, "2000 Hz"), new(16, "2400 Hz"), new(17, "3200 Hz"), new(18, "3500 Hz"), new(19, "4000 Hz"),
        ];

        public static readonly DeepSettingValueType CwAutoMode = new Enumeration(
            [new(0, "OFF"), new(1, "50 MHz"), new(2, "ON")], digits: 1);

        // MODE FM-only shared bits below.

        public static readonly DeepSettingValueType RptShift = new Enumeration(
            [new(0, "-"), new(1, "SIMPLEX"), new(2, "+"), new(3, "ARS")], digits: 1);
        public static readonly DeepSettingValueType SqlType = new Enumeration(
            [new(0, "OFF"), new(1, "ENC"), new(2, "TSQ"), new(3, "DCS"), new(4, "PR FREQ"), new(5, "REV TONE")], digits: 1);
        public static readonly DeepSettingValueType DcsRevers = new Enumeration(
            [new(0, "NORMAL"), new(1, "REVERS")], digits: 1);
        public static readonly DeepSettingValueType DtmfDelay = new Enumeration(
            [new(0, "50 ms"), new(1, "250 ms"), new(2, "450 ms"), new(3, "750 ms"), new(4, "1000 ms")], digits: 1);
        public static readonly DeepSettingValueType DtmfSpeed = new Enumeration(
            [new(0, "50 ms"), new(1, "100 ms")], digits: 1);

        /// The standard 50-tone CTCSS table (00 = 67.0 Hz … 49 = 254.1 Hz),
        /// the same table the MENU grid's TONE FREQ uses.
        public static readonly List<EnumerationCase> ToneFreqCases =
            RigCtcssTone.AllValuesHz.Select((hz, i) => new EnumerationCase(i, Hz(hz))).ToList();

        /// The standard 104-code DCS table (00 = 023 … 103 = 754).
        public static readonly List<EnumerationCase> DcsCodeCases =
            RigDcsCode.AllValues.Select((code, i) => new EnumerationCase(i, code)).ToList();
    }

    private static class CwShared
    {
        public static readonly DeepSettingValueType MemoryType = new Enumeration(
            [new(0, "TEXT"), new(1, "MESSAGE")], digits: 1);
    }

    private static class OperationShared
    {
        public static readonly DeepSettingValueType CatRate = new Enumeration(
        [
            new(0, "4800 bps"), new(1, "9600 bps"), new(2, "19200 bps"), new(3, "38400 bps"), new(4, "115200 bps"),
        ], digits: 1);
        public static readonly DeepSettingValueType CatTimeout = new Enumeration(
            [new(0, "10 msec"), new(1, "100 msec"), new(2, "1000 msec"), new(3, "3000 msec")], digits: 1);
        public static readonly DeepSettingValueType PrmtrcBwth = new IntRange(0, 10, digits: 2, unit: null, step: 1);

        /// 00: OFF, 01-07: 100 Hz-700 Hz in 100 Hz steps.
        public static readonly List<EnumerationCase> PrmtrcFreq1Cases = OffThen(7, i => $"{i * 100} Hz");
        /// 00: OFF, 01-09: 700 Hz-1500 Hz in 100 Hz steps.
        public static readonly List<EnumerationCase> PrmtrcFreq2Cases = OffThen(9, i => $"{700 + (i - 1) * 100} Hz");
        /// 00: OFF, 01-18: 1500 Hz-3200 Hz in 100 Hz steps.
        public static readonly List<EnumerationCase> PrmtrcFreq3Cases = OffThen(18, i => $"{1500 + (i - 1) * 100} Hz");

        /// MIC P1-P4's shared 21-option programmable-button assignment list.
        public static readonly DeepSettingValueType MicAssign = new Enumeration(
        [
            new(0, "LOCK"), new(1, "QMB"), new(2, ">/<"), new(3, "V/M"), new(4, "TUNER"),
            new(5, "VOX/MOX"), new(6, "MODE"), new(7, "ZIN/SPOT"), new(8, "SPLIT"), new(9, "FINE"),
            new(10, "NAR"), new(11, "NB"), new(12, "DNR"), new(13, "FREQ UP"), new(14, "FREQ DOWN"),
            new(15, "BAND UP"), new(16, "BAND DOWN"), new(17, "ATT"), new(18, "IPO"), new(19, "DNF"),
            new(20, "AGC"),
        ], digits: 2);

        public static readonly DeepSettingValueType DialStep5To20 = new Enumeration(
            [new(0, "5 Hz"), new(1, "10 Hz"), new(2, "20 Hz")], digits: 1);
    }

    /// DIGITAL POPUP: 00 OFF, 01-59 = 2-60 sec, 60 CONTINUE.
    private static readonly List<EnumerationCase> DigitalPopupCases =
        [.. OffThen(59, i => $"{i + 1} sec"), new(60, "CONTINUE")];

    /// CW WEIGHT: hardware-confirmed as a 0-based offset (00 = 2.5 … 20 =
    /// 4.5, 0.1/step), not the manual's ×10 — see the Swift comment.
    private static readonly List<EnumerationCase> CwWeightCases =
        Enumerable.Range(0, 21).Select(i => new EnumerationCase(i, (2.5 + i / 10.0).ToString("0.0", CultureInfo.InvariantCulture))).ToList();

    /// TX TIME OUT TIMER: 00 OFF, 01-30 min.
    private static readonly List<EnumerationCase> TxTimeOutCases = OffThen(30, i => $"{i} min");

    /// AUTO POWER OFF: 00 OFF, 01-24 = 0.5-12 h in 0.5 h steps, 2 digits
    /// (hardware-confirmed; the manual's cell says 1 digit).
    private static readonly List<EnumerationCase> AutoPowerOffCases =
        OffThen(24, i => (i / 2.0).ToString(CultureInfo.InvariantCulture) + " h");

    private static readonly DeepSettingItem[] RadioSettingItems =
    [
        // 01.01 (MODE SSB)
        new(p1: 1, p2: 1, p3: 1, category: "RADIO SETTING", tab: "MODE SSB", label: "AF TREBLE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 1, p3: 2, category: "RADIO SETTING", tab: "MODE SSB", label: "AF MIDDLE TONE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 1, p3: 3, category: "RADIO SETTING", tab: "MODE SSB", label: "AF BASS GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 1, p3: 4, category: "RADIO SETTING", tab: "MODE SSB", label: "AGC FAST DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 1, p3: 5, category: "RADIO SETTING", tab: "MODE SSB", label: "AGC MID DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 1, p3: 6, category: "RADIO SETTING", tab: "MODE SSB", label: "AGC SLOW DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 1, p3: 7, category: "RADIO SETTING", tab: "MODE SSB", label: "LCUT FREQ", valueType: new Enumeration(cases: RadioShared.LcutFreqCases, digits: 2)),
        new(p1: 1, p2: 1, p3: 8, category: "RADIO SETTING", tab: "MODE SSB", label: "LCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 1, p3: 9, category: "RADIO SETTING", tab: "MODE SSB", label: "HCUT FREQ", valueType: new Enumeration(cases: RadioShared.HcutFreqCases, digits: 2)),
        new(p1: 1, p2: 1, p3: 10, category: "RADIO SETTING", tab: "MODE SSB", label: "HCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 1, p3: 11, category: "RADIO SETTING", tab: "MODE SSB", label: "USB OUT LEVEL", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 1, p3: 12, category: "RADIO SETTING", tab: "MODE SSB", label: "TX BPF SEL", valueType: RadioShared.TxBpfSel),
        new(p1: 1, p2: 1, p3: 13, category: "RADIO SETTING", tab: "MODE SSB", label: "MOD SOURCE", valueType: RadioShared.ModSource),
        new(p1: 1, p2: 1, p3: 14, category: "RADIO SETTING", tab: "MODE SSB", label: "USB MOD GAIN", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 1, p3: 15, category: "RADIO SETTING", tab: "MODE SSB", label: "RPTT SELECT", valueType: RadioShared.RpttSelect),
        new(p1: 1, p2: 1, p3: 16, category: "RADIO SETTING", tab: "MODE SSB", label: "NAR WIDTH", valueType: new Enumeration(cases: RadioShared.SsbNarWidthCases, digits: 2)),
        new(p1: 1, p2: 1, p3: 17, category: "RADIO SETTING", tab: "MODE SSB", label: "CW AUTO MODE", valueType: RadioShared.CwAutoMode),

        // 01.02 (MODE AM) — same fields as MODE SSB minus NAR WIDTH/CW AUTO MODE
        new(p1: 1, p2: 2, p3: 1, category: "RADIO SETTING", tab: "MODE AM", label: "AF TREBLE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 2, p3: 2, category: "RADIO SETTING", tab: "MODE AM", label: "AF MIDDLE TONE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 2, p3: 3, category: "RADIO SETTING", tab: "MODE AM", label: "AF BASS GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 2, p3: 4, category: "RADIO SETTING", tab: "MODE AM", label: "AGC FAST DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 2, p3: 5, category: "RADIO SETTING", tab: "MODE AM", label: "AGC MID DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 2, p3: 6, category: "RADIO SETTING", tab: "MODE AM", label: "AGC SLOW DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 2, p3: 7, category: "RADIO SETTING", tab: "MODE AM", label: "LCUT FREQ", valueType: new Enumeration(cases: RadioShared.LcutFreqCases, digits: 2)),
        new(p1: 1, p2: 2, p3: 8, category: "RADIO SETTING", tab: "MODE AM", label: "LCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 2, p3: 9, category: "RADIO SETTING", tab: "MODE AM", label: "HCUT FREQ", valueType: new Enumeration(cases: RadioShared.HcutFreqCases, digits: 2)),
        new(p1: 1, p2: 2, p3: 10, category: "RADIO SETTING", tab: "MODE AM", label: "HCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 2, p3: 11, category: "RADIO SETTING", tab: "MODE AM", label: "USB OUT LEVEL", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 2, p3: 12, category: "RADIO SETTING", tab: "MODE AM", label: "TX BPF SEL", valueType: RadioShared.TxBpfSel),
        new(p1: 1, p2: 2, p3: 13, category: "RADIO SETTING", tab: "MODE AM", label: "MOD SOURCE", valueType: RadioShared.ModSource),
        new(p1: 1, p2: 2, p3: 14, category: "RADIO SETTING", tab: "MODE AM", label: "USB MOD GAIN", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 2, p3: 15, category: "RADIO SETTING", tab: "MODE AM", label: "RPTT SELECT", valueType: RadioShared.RpttSelect),

        // 01.03 (MODE FM) — no TX BPF SEL; adds repeater/DTMF/APRS-tone fields
        new(p1: 1, p2: 3, p3: 1, category: "RADIO SETTING", tab: "MODE FM", label: "AF TREBLE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 3, p3: 2, category: "RADIO SETTING", tab: "MODE FM", label: "AF MIDDLE TONE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 3, p3: 3, category: "RADIO SETTING", tab: "MODE FM", label: "AF BASS GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 3, p3: 4, category: "RADIO SETTING", tab: "MODE FM", label: "AGC FAST DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 3, p3: 5, category: "RADIO SETTING", tab: "MODE FM", label: "AGC MID DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 3, p3: 6, category: "RADIO SETTING", tab: "MODE FM", label: "AGC SLOW DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 3, p3: 7, category: "RADIO SETTING", tab: "MODE FM", label: "LCUT FREQ", valueType: new Enumeration(cases: RadioShared.LcutFreqCases, digits: 2)),
        new(p1: 1, p2: 3, p3: 8, category: "RADIO SETTING", tab: "MODE FM", label: "LCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 3, p3: 9, category: "RADIO SETTING", tab: "MODE FM", label: "HCUT FREQ", valueType: new Enumeration(cases: RadioShared.HcutFreqCases, digits: 2)),
        new(p1: 1, p2: 3, p3: 10, category: "RADIO SETTING", tab: "MODE FM", label: "HCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 3, p3: 11, category: "RADIO SETTING", tab: "MODE FM", label: "USB OUT LEVEL", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 3, p3: 12, category: "RADIO SETTING", tab: "MODE FM", label: "MOD SOURCE", valueType: RadioShared.ModSource),
        new(p1: 1, p2: 3, p3: 13, category: "RADIO SETTING", tab: "MODE FM", label: "USB MOD GAIN", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 3, p3: 14, category: "RADIO SETTING", tab: "MODE FM", label: "RPTT SELECT", valueType: RadioShared.RpttSelect),
        new(p1: 1, p2: 3, p3: 15, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT", valueType: RadioShared.RptShift),
        new(p1: 1, p2: 3, p3: 16, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT (28MHz)", valueType: new IntRange(0, 1000, digits: 4, unit: "kHz", step: 10)),
        new(p1: 1, p2: 3, p3: 17, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT (50MHz)", valueType: new IntRange(0, 4000, digits: 4, unit: "kHz", step: 10)),
        // The manual's own cell reads "0-100MHz (P4=0000-0100, 50kHz/step)"
        // for both of these — 100MHz literally would be an absurd repeater
        // shift, so this is almost certainly a 0-100 step count (0-5MHz in
        // 50kHz steps), not a literal MHz range. Left as a raw step count
        // pending hardware confirmation of the real shift range.
        new(p1: 1, p2: 3, p3: 18, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT (144MHz)", valueType: new IntRange(0, 100, digits: 4, unit: "× 50 kHz steps", step: 1)),
        new(p1: 1, p2: 3, p3: 19, category: "RADIO SETTING", tab: "MODE FM", label: "RPT SHIFT (430MHz)", valueType: new IntRange(0, 100, digits: 4, unit: "× 50 kHz steps", step: 1)),
        new(p1: 1, p2: 3, p3: 20, category: "RADIO SETTING", tab: "MODE FM", label: "SQL TYPE", valueType: RadioShared.SqlType),
        new(p1: 1, p2: 3, p3: 21, category: "RADIO SETTING", tab: "MODE FM", label: "TONE FREQ", valueType: new Enumeration(cases: RadioShared.ToneFreqCases, digits: 2)),
        // Manual prints Digits=2 here, but 104 entries (index 000-103) need
        // 3 — same category of manual digit-count error as DISPLAY
        // SETTING's AUTO POWER OFF, caught by testDigitsAreWideEnoughForDeclaredRange.
        new(p1: 1, p2: 3, p3: 22, category: "RADIO SETTING", tab: "MODE FM", label: "DCS CODE", valueType: new Enumeration(cases: RadioShared.DcsCodeCases, digits: 3)),
        new(p1: 1, p2: 3, p3: 23, category: "RADIO SETTING", tab: "MODE FM", label: "DCS RX REVERS", valueType: RadioShared.DcsRevers),
        new(p1: 1, p2: 3, p3: 24, category: "RADIO SETTING", tab: "MODE FM", label: "DCS TX REVERS", valueType: RadioShared.DcsRevers),
        new(p1: 1, p2: 3, p3: 25, category: "RADIO SETTING", tab: "MODE FM", label: "PR FREQ", valueType: new IntRange(300, 3000, digits: 4, unit: "Hz", step: 100)),
        new(p1: 1, p2: 3, p3: 26, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF DELAY", valueType: RadioShared.DtmfDelay),
        new(p1: 1, p2: 3, p3: 27, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF SPEED", valueType: RadioShared.DtmfSpeed),
        new(p1: 1, p2: 3, p3: 28, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 1", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 29, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 2", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 30, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 3", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 31, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 4", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 32, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 5", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 33, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 6", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 34, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 7", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 35, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 8", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 36, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 9", valueType: new Text(maxLength: 16)),
        new(p1: 1, p2: 3, p3: 37, category: "RADIO SETTING", tab: "MODE FM", label: "DTMF MEMORY 10", valueType: new Text(maxLength: 16)),

        // 01.04 (MODE DATA) — has TX BPF SEL (like SSB/AM); adds PSK TONE/DATA SHIFT
        new(p1: 1, p2: 4, p3: 1, category: "RADIO SETTING", tab: "MODE DATA", label: "AF TREBLE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 4, p3: 2, category: "RADIO SETTING", tab: "MODE DATA", label: "AF MIDDLE TONE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 4, p3: 3, category: "RADIO SETTING", tab: "MODE DATA", label: "AF BASS GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 4, p3: 4, category: "RADIO SETTING", tab: "MODE DATA", label: "AGC FAST DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 4, p3: 5, category: "RADIO SETTING", tab: "MODE DATA", label: "AGC MID DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 4, p3: 6, category: "RADIO SETTING", tab: "MODE DATA", label: "AGC SLOW DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 4, p3: 7, category: "RADIO SETTING", tab: "MODE DATA", label: "LCUT FREQ", valueType: new Enumeration(cases: RadioShared.LcutFreqCases, digits: 2)),
        new(p1: 1, p2: 4, p3: 8, category: "RADIO SETTING", tab: "MODE DATA", label: "LCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 4, p3: 9, category: "RADIO SETTING", tab: "MODE DATA", label: "HCUT FREQ", valueType: new Enumeration(cases: RadioShared.HcutFreqCases, digits: 2)),
        new(p1: 1, p2: 4, p3: 10, category: "RADIO SETTING", tab: "MODE DATA", label: "HCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 4, p3: 11, category: "RADIO SETTING", tab: "MODE DATA", label: "USB OUT LEVEL", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 4, p3: 12, category: "RADIO SETTING", tab: "MODE DATA", label: "TX BPF SEL", valueType: RadioShared.TxBpfSel),
        new(p1: 1, p2: 4, p3: 13, category: "RADIO SETTING", tab: "MODE DATA", label: "MOD SOURCE", valueType: RadioShared.ModSource),
        new(p1: 1, p2: 4, p3: 14, category: "RADIO SETTING", tab: "MODE DATA", label: "USB MOD GAIN", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 4, p3: 15, category: "RADIO SETTING", tab: "MODE DATA", label: "RPTT SELECT", valueType: RadioShared.RpttSelect),
        new(p1: 1, p2: 4, p3: 16, category: "RADIO SETTING", tab: "MODE DATA", label: "NAR WIDTH", valueType: new Enumeration(cases: RadioShared.DataNarWidthCases, digits: 2)),
        new(p1: 1, p2: 4, p3: 17, category: "RADIO SETTING", tab: "MODE DATA", label: "PSK TONE", valueType: new Enumeration(cases: [
            new(0, "1000 Hz"), new(1, "1500 Hz"),
        ], digits: 1)),
        new(p1: 1, p2: 4, p3: 18, category: "RADIO SETTING", tab: "MODE DATA", label: "DATA SHIFT (SSB)", valueType: new IntRange(0, 3000, digits: 4, unit: "Hz", step: 10)),

        // 01.05 (MODE RTTY) — no TX BPF SEL/MOD SOURCE/USB MOD GAIN
        new(p1: 1, p2: 5, p3: 1, category: "RADIO SETTING", tab: "MODE RTTY", label: "AF TREBLE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 5, p3: 2, category: "RADIO SETTING", tab: "MODE RTTY", label: "AF MIDDLE TONE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 5, p3: 3, category: "RADIO SETTING", tab: "MODE RTTY", label: "AF BASS GAIN", valueType: RadioShared.SignedGain),
        new(p1: 1, p2: 5, p3: 4, category: "RADIO SETTING", tab: "MODE RTTY", label: "AGC FAST DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 5, p3: 5, category: "RADIO SETTING", tab: "MODE RTTY", label: "AGC MID DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 5, p3: 6, category: "RADIO SETTING", tab: "MODE RTTY", label: "AGC SLOW DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 1, p2: 5, p3: 7, category: "RADIO SETTING", tab: "MODE RTTY", label: "LCUT FREQ", valueType: new Enumeration(cases: RadioShared.LcutFreqCases, digits: 2)),
        new(p1: 1, p2: 5, p3: 8, category: "RADIO SETTING", tab: "MODE RTTY", label: "LCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 5, p3: 9, category: "RADIO SETTING", tab: "MODE RTTY", label: "HCUT FREQ", valueType: new Enumeration(cases: RadioShared.HcutFreqCases, digits: 2)),
        new(p1: 1, p2: 5, p3: 10, category: "RADIO SETTING", tab: "MODE RTTY", label: "HCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 1, p2: 5, p3: 11, category: "RADIO SETTING", tab: "MODE RTTY", label: "USB OUT LEVEL", valueType: RadioShared.OutLevel),
        new(p1: 1, p2: 5, p3: 12, category: "RADIO SETTING", tab: "MODE RTTY", label: "RPTT SELECT", valueType: RadioShared.RpttSelect),
        new(p1: 1, p2: 5, p3: 13, category: "RADIO SETTING", tab: "MODE RTTY", label: "NAR WIDTH", valueType: new Enumeration(cases: RadioShared.DataNarWidthCases, digits: 2)),
        new(p1: 1, p2: 5, p3: 14, category: "RADIO SETTING", tab: "MODE RTTY", label: "MARK FREQUENCY", valueType: new Enumeration(cases: [
            new(0, "1275 Hz"), new(1, "2125 Hz"),
        ], digits: 1)),
        new(p1: 1, p2: 5, p3: 15, category: "RADIO SETTING", tab: "MODE RTTY", label: "SHIFT FREQUENCY", valueType: new Enumeration(cases: [
            new(0, "170 Hz"), new(1, "200 Hz"), new(2, "425 Hz"), new(3, "850 Hz"),
        ], digits: 1)),
        new(p1: 1, p2: 5, p3: 16, category: "RADIO SETTING", tab: "MODE RTTY", label: "POLARITY-TX", valueType: new Enumeration(cases: [
            new(0, "NOR"), new(1, "REV"),
        ], digits: 1)),

        // 01.06 (DIGITAL)
        new(p1: 1, p2: 6, p3: 1, category: "RADIO SETTING", tab: "DIGITAL", label: "DIGITAL POPUP", valueType: new Enumeration(cases: DigitalPopupCases, digits: 2)),
        new(p1: 1, p2: 6, p3: 2, category: "RADIO SETTING", tab: "DIGITAL", label: "LOCATION SERVICE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 1, p2: 6, p3: 3, category: "RADIO SETTING", tab: "DIGITAL", label: "STANDBY BEEP", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 1, p2: 6, p3: 4, category: "RADIO SETTING", tab: "DIGITAL", label: "DP-ID LIST", valueType: new ReadOnly()),
        new(p1: 1, p2: 6, p3: 5, category: "RADIO SETTING", tab: "DIGITAL", label: "RADIO ID", valueType: new ReadOnly()),
    ];

    private static readonly DeepSettingItem[] CwSettingItems =
    [
        // 02.01 (MODE CW)
        new(p1: 2, p2: 1, p3: 1, category: "CW SETTING", tab: "MODE CW", label: "AF TREBLE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 2, p2: 1, p3: 2, category: "CW SETTING", tab: "MODE CW", label: "AF MIDDLE TONE GAIN", valueType: RadioShared.SignedGain),
        new(p1: 2, p2: 1, p3: 3, category: "CW SETTING", tab: "MODE CW", label: "AF BASS GAIN", valueType: RadioShared.SignedGain),
        new(p1: 2, p2: 1, p3: 4, category: "CW SETTING", tab: "MODE CW", label: "AGC FAST DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 2, p2: 1, p3: 5, category: "CW SETTING", tab: "MODE CW", label: "AGC MID DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 2, p2: 1, p3: 6, category: "CW SETTING", tab: "MODE CW", label: "AGC SLOW DELAY", valueType: RadioShared.AgcDelay),
        new(p1: 2, p2: 1, p3: 7, category: "CW SETTING", tab: "MODE CW", label: "LCUT FREQ", valueType: new Enumeration(cases: RadioShared.LcutFreqCases, digits: 2)),
        new(p1: 2, p2: 1, p3: 8, category: "CW SETTING", tab: "MODE CW", label: "LCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 2, p2: 1, p3: 9, category: "CW SETTING", tab: "MODE CW", label: "HCUT FREQ", valueType: new Enumeration(cases: RadioShared.HcutFreqCases, digits: 2)),
        new(p1: 2, p2: 1, p3: 10, category: "CW SETTING", tab: "MODE CW", label: "HCUT SLOPE", valueType: RadioShared.CutSlope),
        new(p1: 2, p2: 1, p3: 11, category: "CW SETTING", tab: "MODE CW", label: "USB OUT LEVEL", valueType: RadioShared.OutLevel),
        new(p1: 2, p2: 1, p3: 12, category: "CW SETTING", tab: "MODE CW", label: "RPTT SELECT", valueType: RadioShared.RpttSelect),
        new(p1: 2, p2: 1, p3: 13, category: "CW SETTING", tab: "MODE CW", label: "NAR WIDTH", valueType: new Enumeration(cases: RadioShared.DataNarWidthCases, digits: 2)),
        new(p1: 2, p2: 1, p3: 14, category: "CW SETTING", tab: "MODE CW", label: "PC KEYING", valueType: RadioShared.RpttSelect),
        new(p1: 2, p2: 1, p3: 15, category: "CW SETTING", tab: "MODE CW", label: "CW BK-IN TYPE", valueType: new Enumeration(cases: [
            new(0, "SEMI"), new(1, "FULL"),
        ], digits: 1)),
        new(p1: 2, p2: 1, p3: 16, category: "CW SETTING", tab: "MODE CW", label: "CW FREQ DISPLAY", valueType: new Enumeration(cases: [
            new(0, "DIRECT FREQ"), new(1, "PITCH OFFSET"),
        ], digits: 1)),
        new(p1: 2, p2: 1, p3: 17, category: "CW SETTING", tab: "MODE CW", label: "QSK DELAY TIME", valueType: new Enumeration(cases: [
            new(0, "15 msec"), new(1, "20 msec"), new(2, "25 msec"), new(3, "30 msec"),
        ], digits: 1)),
        new(p1: 2, p2: 1, p3: 18, category: "CW SETTING", tab: "MODE CW", label: "CW INDICATOR", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),

        // 02.02 (KEYER)
        new(p1: 2, p2: 2, p3: 1, category: "CW SETTING", tab: "KEYER", label: "KEYER TYPE", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "BUG"), new(2, "ELEKEY-A"), new(3, "ELEKEY-B"), new(4, "ELEKEY-Y"), new(5, "ACS"),
        ], digits: 1)),
        new(p1: 2, p2: 2, p3: 2, category: "CW SETTING", tab: "KEYER", label: "KEYER DOT/DASH", valueType: new Enumeration(cases: [
            new(0, "NOR"), new(1, "REV"),
        ], digits: 1)),
        // The manual's cell claims raw P4 is the weight ×10 (25-45 for
        // 2.5-4.5) — confirmed wrong against real hardware: a live "EX
        // 02.02.03" probe returned raw "05" while the rig's own physical
        // MENU display read 3.0, which only fits a 0-based offset (00 =
        // 2.5, 20 = 4.5, 0.1/step), not the manual's literal ×10 encoding.
        // Same class of manual/hardware mismatch as AUTO POWER OFF/DCS
        // CODE's digit-count errors, but this one's the *value mapping*
        // itself, not just the digit width.
        new(p1: 2, p2: 2, p3: 3, category: "CW SETTING", tab: "KEYER", label: "CW WEIGHT", valueType: new Enumeration(cases: CwWeightCases, digits: 2)),
        new(p1: 2, p2: 2, p3: 4, category: "CW SETTING", tab: "KEYER", label: "NUMBER STYLE", valueType: new Enumeration(cases: [
            new(0, "1290"), new(1, "AUNO"), new(2, "AUNT"), new(3, "A2NO"), new(4, "A2NT"), new(5, "12NO"), new(6, "12NT"),
        ], digits: 1)),
        new(p1: 2, p2: 2, p3: 5, category: "CW SETTING", tab: "KEYER", label: "CONTEST NUMBER", valueType: new IntRange(1, 9999, digits: 4, unit: null, step: 1)),
        new(p1: 2, p2: 2, p3: 6, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 1", valueType: CwShared.MemoryType),
        new(p1: 2, p2: 2, p3: 7, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 2", valueType: CwShared.MemoryType),
        new(p1: 2, p2: 2, p3: 8, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 3", valueType: CwShared.MemoryType),
        new(p1: 2, p2: 2, p3: 9, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 4", valueType: CwShared.MemoryType),
        new(p1: 2, p2: 2, p3: 10, category: "CW SETTING", tab: "KEYER", label: "CW MEMORY 5", valueType: CwShared.MemoryType),
        new(p1: 2, p2: 2, p3: 11, category: "CW SETTING", tab: "KEYER", label: "REPEAT INTERVAL", valueType: new IntRange(1, 60, digits: 2, unit: "sec", step: 1)),
    ];

    private static readonly DeepSettingItem[] OperationSettingItems =
    [
        // 03.01 (GENERAL)
        new(p1: 3, p2: 1, p3: 1, category: "OPERATION SETTING", tab: "GENERAL", label: "BEEP LEVEL", valueType: new IntRange(0, 100, digits: 3, unit: null, step: 1)),
        new(p1: 3, p2: 1, p3: 2, category: "OPERATION SETTING", tab: "GENERAL", label: "RF/SQL VR", valueType: new Enumeration(cases: [
            new(0, "RF"), new(1, "SQL"), new(2, "SQL (FM mode only)"),
        ], digits: 1)),
        new(p1: 3, p2: 1, p3: 3, category: "OPERATION SETTING", tab: "GENERAL", label: "TUN/LIN PORT SELECT", valueType: new Enumeration(cases: [
            new(0, "EXT-TUNER"), new(1, "LINEAR"), new(2, "CAT-3"), new(3, "GPO"),
        ], digits: 1)),
        new(p1: 3, p2: 1, p3: 4, category: "OPERATION SETTING", tab: "GENERAL", label: "TUNER SELECT", valueType: new Enumeration(cases: [
            new(0, "INT"), new(1, "INT (FAST)"), new(2, "EXT"), new(3, "ATAS"),
        ], digits: 1)),
        new(p1: 3, p2: 1, p3: 5, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-1 RATE", valueType: OperationShared.CatRate),
        new(p1: 3, p2: 1, p3: 6, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-1 TIME OUT TIMER", valueType: OperationShared.CatTimeout),
        new(p1: 3, p2: 1, p3: 7, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-1/CAT-3 STOP BIT", valueType: new Enumeration(cases: [
            new(0, "1 bit"), new(1, "2 bit"),
        ], digits: 1)),
        new(p1: 3, p2: 1, p3: 8, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-2 RATE", valueType: OperationShared.CatRate),
        new(p1: 3, p2: 1, p3: 9, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-2 TIME OUT TIMER", valueType: OperationShared.CatTimeout),
        new(p1: 3, p2: 1, p3: 10, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-3 RATE", valueType: OperationShared.CatRate),
        new(p1: 3, p2: 1, p3: 11, category: "OPERATION SETTING", tab: "GENERAL", label: "CAT-3 TIME OUT TIMER", valueType: OperationShared.CatTimeout),
        new(p1: 3, p2: 1, p3: 12, category: "OPERATION SETTING", tab: "GENERAL", label: "TX TIME OUT TIMER", valueType: new Enumeration(cases: TxTimeOutCases, digits: 2)),
        new(p1: 3, p2: 1, p3: 13, category: "OPERATION SETTING", tab: "GENERAL", label: "REF FREQ ADJ", valueType: new SignedRange(-25, 25, digits: 2, unit: null, step: 1)),
        new(p1: 3, p2: 1, p3: 14, category: "OPERATION SETTING", tab: "GENERAL", label: "CHARGE CONTROL", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 3, p2: 1, p3: 15, category: "OPERATION SETTING", tab: "GENERAL", label: "SUB BAND MUTE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 3, p2: 1, p3: 16, category: "OPERATION SETTING", tab: "GENERAL", label: "SPEAKER SELECT", valueType: new Enumeration(cases: [
            new(0, "Auto"), new(1, "INT"), new(2, "BOTH"),
        ], digits: 1)),
        new(p1: 3, p2: 1, p3: 17, category: "OPERATION SETTING", tab: "GENERAL", label: "DITHER", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),

        // 03.02 (BAND-SCAN)
        new(p1: 3, p2: 2, p3: 1, category: "OPERATION SETTING", tab: "BAND-SCAN", label: "QMB CH", valueType: new Enumeration(cases: [
            new(0, "5ch"), new(1, "10ch"),
        ], digits: 1)),
        new(p1: 3, p2: 2, p3: 2, category: "OPERATION SETTING", tab: "BAND-SCAN", label: "BAND STACK", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 3, p2: 2, p3: 3, category: "OPERATION SETTING", tab: "BAND-SCAN", label: "BAND EDGE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 3, p2: 2, p3: 4, category: "OPERATION SETTING", tab: "BAND-SCAN", label: "SCAN RESUME", valueType: new Enumeration(cases: [
            new(0, "BUSY"), new(1, "HOLD"), new(2, "1 sec"), new(3, "3 sec"), new(4, "5 sec"),
        ], digits: 1)),

        // 03.03 (RX-DSP)
        new(p1: 3, p2: 3, p3: 1, category: "OPERATION SETTING", tab: "RX-DSP", label: "IF NOTCH WIDTH", valueType: new Enumeration(cases: [
            new(0, "NARROW"), new(1, "WIDE"),
        ], digits: 1)),
        new(p1: 3, p2: 3, p3: 2, category: "OPERATION SETTING", tab: "RX-DSP", label: "NB REJECTION", valueType: new Enumeration(cases: [
            new(0, "LOW"), new(1, "MID"), new(2, "HIGH"),
        ], digits: 1)),
        new(p1: 3, p2: 3, p3: 3, category: "OPERATION SETTING", tab: "RX-DSP", label: "NB WIDTH", valueType: new Enumeration(cases: [
            new(0, "NARROW"), new(1, "MEDIUM"), new(2, "WIDE"),
        ], digits: 1)),
        new(p1: 3, p2: 3, p3: 4, category: "OPERATION SETTING", tab: "RX-DSP", label: "APF WIDTH", valueType: new Enumeration(cases: [
            new(0, "NARROW"), new(1, "MEDIUM"), new(2, "WIDE"),
        ], digits: 1)),
        new(p1: 3, p2: 3, p3: 5, category: "OPERATION SETTING", tab: "RX-DSP", label: "CONTOUR LEVEL", valueType: new SignedRange(-40, 20, digits: 2, unit: null, step: 1)),
        new(p1: 3, p2: 3, p3: 6, category: "OPERATION SETTING", tab: "RX-DSP", label: "CONTOUR WIDTH", valueType: new IntRange(1, 11, digits: 2, unit: null, step: 1)),

        // 03.04 (TX AUDIO)
        new(p1: 3, p2: 4, p3: 1, category: "OPERATION SETTING", tab: "TX AUDIO", label: "AMC RELEASE TIME", valueType: new Enumeration(cases: [
            new(0, "FAST"), new(1, "MID"), new(2, "SLOW"),
        ], digits: 1)),
        new(p1: 3, p2: 4, p3: 2, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ1 FREQ", valueType: new Enumeration(cases: OperationShared.PrmtrcFreq1Cases, digits: 2)),
        new(p1: 3, p2: 4, p3: 3, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ1 LEVEL", valueType: RadioShared.SignedGain),
        new(p1: 3, p2: 4, p3: 4, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ1 BWTH", valueType: OperationShared.PrmtrcBwth),
        new(p1: 3, p2: 4, p3: 5, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ2 FREQ", valueType: new Enumeration(cases: OperationShared.PrmtrcFreq2Cases, digits: 2)),
        new(p1: 3, p2: 4, p3: 6, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ2 LEVEL", valueType: RadioShared.SignedGain),
        new(p1: 3, p2: 4, p3: 7, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ2 BWTH", valueType: OperationShared.PrmtrcBwth),
        new(p1: 3, p2: 4, p3: 8, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ3 FREQ", valueType: new Enumeration(cases: OperationShared.PrmtrcFreq3Cases, digits: 2)),
        new(p1: 3, p2: 4, p3: 9, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ3 LEVEL", valueType: RadioShared.SignedGain),
        new(p1: 3, p2: 4, p3: 10, category: "OPERATION SETTING", tab: "TX AUDIO", label: "PRMTRC EQ3 BWTH", valueType: OperationShared.PrmtrcBwth),
        new(p1: 3, p2: 4, p3: 11, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ1 FREQ", valueType: new Enumeration(cases: OperationShared.PrmtrcFreq1Cases, digits: 2)),
        new(p1: 3, p2: 4, p3: 12, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ1 LEVEL", valueType: RadioShared.SignedGain),
        new(p1: 3, p2: 4, p3: 13, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ1 BWTH", valueType: OperationShared.PrmtrcBwth),
        new(p1: 3, p2: 4, p3: 14, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ2 FREQ", valueType: new Enumeration(cases: OperationShared.PrmtrcFreq2Cases, digits: 2)),
        new(p1: 3, p2: 4, p3: 15, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ2 LEVEL", valueType: RadioShared.SignedGain),
        new(p1: 3, p2: 4, p3: 16, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ2 BWTH", valueType: OperationShared.PrmtrcBwth),
        new(p1: 3, p2: 4, p3: 17, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ3 FREQ", valueType: new Enumeration(cases: OperationShared.PrmtrcFreq3Cases, digits: 2)),
        new(p1: 3, p2: 4, p3: 18, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ3 LEVEL", valueType: RadioShared.SignedGain),
        new(p1: 3, p2: 4, p3: 19, category: "OPERATION SETTING", tab: "TX AUDIO", label: "P PRMTRC EQ3 BWTH", valueType: OperationShared.PrmtrcBwth),

        // 03.05 (TX GENERAL)
        new(p1: 3, p2: 5, p3: 1, category: "OPERATION SETTING", tab: "TX GENERAL", label: "MAX POWER (BAT)", valueType: new IntRange(5, 60, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 5, p3: 2, category: "OPERATION SETTING", tab: "TX GENERAL", label: "QRP MODE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        // Printed as "005-010" — almost certainly a misread/misprint of
        // "005-100" (every other MAX POWER field here, and OPTION's own
        // HF MAX POWER below, go to 100/50, not 10). Using 100 pending a
        // hardware check specifically on this field's real upper bound.
        new(p1: 3, p2: 5, p3: 3, category: "OPERATION SETTING", tab: "TX GENERAL", label: "HF MAX POWER", valueType: new IntRange(5, 100, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 5, p3: 4, category: "OPERATION SETTING", tab: "TX GENERAL", label: "50M MAX POWER", valueType: new IntRange(5, 60, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 5, p3: 5, category: "OPERATION SETTING", tab: "TX GENERAL", label: "70M MAX POWER", valueType: new IntRange(5, 60, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 5, p3: 6, category: "OPERATION SETTING", tab: "TX GENERAL", label: "144M MAX POWER", valueType: new IntRange(5, 100, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 5, p3: 7, category: "OPERATION SETTING", tab: "TX GENERAL", label: "430M MAX POWER", valueType: new IntRange(5, 100, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 5, p3: 8, category: "OPERATION SETTING", tab: "TX GENERAL", label: "AM HF/50 MAX POWER", valueType: new IntRange(5, 25, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 5, p3: 9, category: "OPERATION SETTING", tab: "TX GENERAL", label: "AM V/U MAX POWER", valueType: new IntRange(5, 25, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 5, p3: 10, category: "OPERATION SETTING", tab: "TX GENERAL", label: "VOX SELECT", valueType: new Enumeration(cases: [
            new(0, "MIC"), new(1, "USB"), new(2, "Bluetooth"),
        ], digits: 1)),
        new(p1: 3, p2: 5, p3: 11, category: "OPERATION SETTING", tab: "TX GENERAL", label: "EMERGENCY FREQ TX", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 3, p2: 5, p3: 12, category: "OPERATION SETTING", tab: "TX GENERAL", label: "TX INHIBIT", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 3, p2: 5, p3: 13, category: "OPERATION SETTING", tab: "TX GENERAL", label: "METER DETECTOR", valueType: new Enumeration(cases: [
            new(0, "AVERAGE"), new(1, "PEAK"),
        ], digits: 1)),

        // 03.06 (KEY/DIAL)
        new(p1: 3, p2: 6, p3: 1, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "SSB/CW DIAL STEP", valueType: OperationShared.DialStep5To20),
        new(p1: 3, p2: 6, p3: 2, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "RTTY/PSK DIAL STEP", valueType: OperationShared.DialStep5To20),
        new(p1: 3, p2: 6, p3: 3, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "FM DIAL STEP", valueType: new Enumeration(cases: [
            new(0, "5 kHz"), new(1, "6.25 kHz"), new(2, "10 kHz"), new(3, "12.5 kHz"), new(4, "20 kHz"), new(5, "25 kHz"), new(6, "Auto"),
        ], digits: 1)),
        new(p1: 3, p2: 6, p3: 4, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "CH STEP", valueType: new Enumeration(cases: [
            new(0, "1 kHz"), new(1, "1.25 kHz"), new(2, "2.5 kHz"), new(3, "10 kHz"),
        ], digits: 1)),
        new(p1: 3, p2: 6, p3: 5, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "AM CH STEP", valueType: new Enumeration(cases: [
            new(0, "2.5 kHz"), new(1, "5 kHz"), new(2, "9 kHz"), new(3, "10 kHz"), new(4, "12.5 kHz"), new(5, "25 kHz"),
        ], digits: 1)),
        new(p1: 3, p2: 6, p3: 6, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "FM CH STEP", valueType: new Enumeration(cases: [
            new(0, "5 kHz"), new(1, "6.25 kHz"), new(2, "10 kHz"), new(3, "12.5 kHz"), new(4, "20 kHz"), new(5, "25 kHz"),
        ], digits: 1)),
        new(p1: 3, p2: 6, p3: 7, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MAIN STEPS PER REV.", valueType: new Enumeration(cases: [
            new(0, "50"), new(1, "100"), new(2, "200"),
        ], digits: 1)),
        new(p1: 3, p2: 6, p3: 8, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC P1", valueType: OperationShared.MicAssign),
        new(p1: 3, p2: 6, p3: 9, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC P2", valueType: OperationShared.MicAssign),
        new(p1: 3, p2: 6, p3: 10, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC P3", valueType: OperationShared.MicAssign),
        new(p1: 3, p2: 6, p3: 11, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC P4", valueType: OperationShared.MicAssign),
        new(p1: 3, p2: 6, p3: 12, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC UP", valueType: new ReadOnly()),
        new(p1: 3, p2: 6, p3: 13, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC DOWN", valueType: new ReadOnly()),
        new(p1: 3, p2: 6, p3: 14, category: "OPERATION SETTING", tab: "KEY/DIAL", label: "MIC SCAN", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),

        // 03.07 (OPTION)
        new(p1: 3, p2: 7, p3: 1, category: "OPERATION SETTING", tab: "OPTION", label: "TUNER TYPE SEL ANT1", valueType: new Enumeration(cases: [
            new(0, "INT"), new(1, "INT (FAST)"), new(2, "EXT"), new(3, "ATAS"),
        ], digits: 1)),
        new(p1: 3, p2: 7, p3: 2, category: "OPERATION SETTING", tab: "OPTION", label: "TUNER TYPE SEL ANT2", valueType: new Enumeration(cases: [
            new(0, "INT"), new(1, "INT (FAST)"), new(2, "EXT"), new(3, "ATAS"),
        ], digits: 1)),
        new(p1: 3, p2: 7, p3: 3, category: "OPERATION SETTING", tab: "OPTION", label: "ANT2 OPERATION", valueType: new Enumeration(cases: [
            new(0, "TRX"), new(1, "TX-ANT1, RX-ANT2"), new(2, "TRX-ANT1, RX-ANT2"),
        ], digits: 1)),
        new(p1: 3, p2: 7, p3: 4, category: "OPERATION SETTING", tab: "OPTION", label: "HF ANT SELECT", valueType: new Enumeration(cases: [
            new(0, "ANT1"), new(1, "ANT2"),
        ], digits: 1)),
        new(p1: 3, p2: 7, p3: 5, category: "OPERATION SETTING", tab: "OPTION", label: "HF MAX POWER", valueType: new IntRange(5, 100, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 7, p3: 6, category: "OPERATION SETTING", tab: "OPTION", label: "50M MAX POWER", valueType: new IntRange(5, 100, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 7, p3: 7, category: "OPERATION SETTING", tab: "OPTION", label: "70M MAX POWER", valueType: new IntRange(5, 50, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 7, p3: 8, category: "OPERATION SETTING", tab: "OPTION", label: "144M MAX POWER", valueType: new IntRange(5, 50, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 7, p3: 9, category: "OPERATION SETTING", tab: "OPTION", label: "430M MAX POWER", valueType: new IntRange(5, 50, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 7, p3: 10, category: "OPERATION SETTING", tab: "OPTION", label: "AM MAX POWER", valueType: new IntRange(5, 25, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 7, p3: 11, category: "OPERATION SETTING", tab: "OPTION", label: "AM V/U MAX POWER", valueType: new IntRange(5, 13, digits: 3, unit: "W", step: 1)),
        new(p1: 3, p2: 7, p3: 12, category: "OPERATION SETTING", tab: "OPTION", label: "GPS", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 3, p2: 7, p3: 13, category: "OPERATION SETTING", tab: "OPTION", label: "GPS PINNING", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 3, p2: 7, p3: 14, category: "OPERATION SETTING", tab: "OPTION", label: "GPS BAUDRATE", valueType: new Enumeration(cases: [
            new(0, "4800 bps"), new(1, "9600 bps"), new(2, "19200 bps"), new(3, "38400 bps"), new(4, "115200 bps"),
        ], digits: 1)),
        new(p1: 3, p2: 7, p3: 15, category: "OPERATION SETTING", tab: "OPTION", label: "BLUETOOTH", valueType: new ReadOnly()),
    ];

    private static readonly DeepSettingItem[] ExtensionSettingItems =
    [
        // 05.01 (DATE&TIME)
        new(p1: 5, p2: 1, p3: 1, category: "EXTENSION SETTING", tab: "DATE&TIME", label: "TIME ZONE", valueType: new SignedRange(-120, 140, digits: 3, unit: "× 0.1h", step: 5)),
        new(p1: 5, p2: 1, p3: 2, category: "EXTENSION SETTING", tab: "DATE&TIME", label: "DAY", valueType: new ReadOnly()),
        new(p1: 5, p2: 1, p3: 3, category: "EXTENSION SETTING", tab: "DATE&TIME", label: "MONTH", valueType: new ReadOnly()),
        new(p1: 5, p2: 1, p3: 4, category: "EXTENSION SETTING", tab: "DATE&TIME", label: "YEAR", valueType: new ReadOnly()),
        new(p1: 5, p2: 1, p3: 5, category: "EXTENSION SETTING", tab: "DATE&TIME", label: "HOUR", valueType: new ReadOnly()),
        new(p1: 5, p2: 1, p3: 6, category: "EXTENSION SETTING", tab: "DATE&TIME", label: "MINUTE", valueType: new ReadOnly()),
        new(p1: 5, p2: 1, p3: 7, category: "EXTENSION SETTING", tab: "DATE&TIME", label: "GPS TIME SET", valueType: new Enumeration(cases: [
            new(0, "AUTO"), new(1, "MANUAL"),
        ], digits: 1)),

        // 05.02 (MY POSITION) — its own tab, confirmed via live probe (see above)
        new(p1: 5, p2: 2, p3: 1, category: "EXTENSION SETTING", tab: "MY POSITION", label: "MY POSITION", valueType: new Enumeration(cases: [
            new(0, "GPS"), new(1, "MANUAL"),
        ], digits: 1)),
        // Compound lat/long strings (live-probed reply looked like
        // "N  00 00.00'..." / "E 000 00.00'...") — not a plain fixed-width
        // numeric/text field, left read-only rather than building a
        // bespoke editor for one item pair.
        new(p1: 5, p2: 2, p3: 2, category: "EXTENSION SETTING", tab: "MY POSITION", label: "MY POSITION LATITUDE", valueType: new ReadOnly()),
        new(p1: 5, p2: 2, p3: 3, category: "EXTENSION SETTING", tab: "MY POSITION", label: "MY POSITION LONGITUDE", valueType: new ReadOnly()),

        // 05.03 (SD CARD)
        new(p1: 5, p2: 3, p3: 1, category: "EXTENSION SETTING", tab: "SD CARD", label: "MEM LIST LOAD", valueType: new Momentary()),
        new(p1: 5, p2: 3, p3: 2, category: "EXTENSION SETTING", tab: "SD CARD", label: "MEM LIST SAVE", valueType: new Momentary()),
        new(p1: 5, p2: 3, p3: 3, category: "EXTENSION SETTING", tab: "SD CARD", label: "MENU LOAD", valueType: new Momentary()),
        new(p1: 5, p2: 3, p3: 4, category: "EXTENSION SETTING", tab: "SD CARD", label: "MENU SAVE", valueType: new Momentary()),
        new(p1: 5, p2: 3, p3: 5, category: "EXTENSION SETTING", tab: "SD CARD", label: "INFORMATIONS", valueType: new ReadOnly()),
        new(p1: 5, p2: 3, p3: 6, category: "EXTENSION SETTING", tab: "SD CARD", label: "FIRMWARE UPDATE", valueType: new Momentary()),
        new(p1: 5, p2: 3, p3: 7, category: "EXTENSION SETTING", tab: "SD CARD", label: "FORMAT", valueType: new Momentary()),

        // 05.04 (SOFT VERSION)
        new(p1: 5, p2: 4, p3: 1, category: "EXTENSION SETTING", tab: "SOFT VERSION", label: "SOFT VERSION", valueType: new ReadOnly()),

        // 05.05 (CALIBRATION)
        new(p1: 5, p2: 5, p3: 1, category: "EXTENSION SETTING", tab: "CALIBRATION", label: "CALIBRATION", valueType: new Momentary()),

        // 05.06 (RESET, includes CERTIFICATION as P3 04 — see above)
        new(p1: 5, p2: 6, p3: 1, category: "EXTENSION SETTING", tab: "RESET", label: "MEMORY CLEAR", valueType: new Momentary()),
        new(p1: 5, p2: 6, p3: 2, category: "EXTENSION SETTING", tab: "RESET", label: "MENU CLEAR", valueType: new Momentary()),
        new(p1: 5, p2: 6, p3: 3, category: "EXTENSION SETTING", tab: "RESET", label: "ALL RESET", valueType: new Momentary()),
        new(p1: 5, p2: 6, p3: 4, category: "EXTENSION SETTING", tab: "RESET", label: "CERTIFICATION", valueType: new ReadOnly()),
    ];

    private static readonly DeepSettingItem[] AprsSettingItems =
    [
        // 06.01 (GENERAL)
        new(p1: 6, p2: 1, p3: 1, category: "APRS SETTING", tab: "GENERAL", label: "MODEM SELECT", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "AUTO"), new(2, "MAIN"), new(3, "SUB"),
        ], digits: 1)),
        new(p1: 6, p2: 1, p3: 2, category: "APRS SETTING", tab: "GENERAL", label: "MODEM TYPE", valueType: new Enumeration(cases: [
            new(0, "1200 bps"), new(1, "9600 bps"),
        ], digits: 1)),
        new(p1: 6, p2: 1, p3: 3, category: "APRS SETTING", tab: "GENERAL", label: "APRS AF MUTE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 6, p2: 1, p3: 4, category: "APRS SETTING", tab: "GENERAL", label: "APRS TX DELAY", valueType: new Enumeration(cases: [
            new(0, "100 ms"), new(1, "200 ms"), new(2, "300 ms"), new(3, "400 ms"), new(4, "500 ms"), new(5, "750 ms"), new(6, "1000 ms"),
        ], digits: 1)),
        new(p1: 6, p2: 1, p3: 5, category: "APRS SETTING", tab: "GENERAL", label: "CALLSIGN (APRS)", valueType: new Text(maxLength: 8)),
        // Confirmed via live probe (EX060106) — the manual's printed table
        // looked like it jumped to P3=09.
        new(p1: 6, p2: 1, p3: 6, category: "APRS SETTING", tab: "GENERAL", label: "APRS DESTINATION", valueType: new ReadOnly()),

        // 06.02 (MSG TEMPLATE)
        new(p1: 6, p2: 2, p3: 1, category: "APRS SETTING", tab: "MSG TEMPLATE", label: "MESSAGE TEXT1", valueType: new Text(maxLength: 16)),
        new(p1: 6, p2: 2, p3: 2, category: "APRS SETTING", tab: "MSG TEMPLATE", label: "MESSAGE TEXT2", valueType: new Text(maxLength: 16)),
        new(p1: 6, p2: 2, p3: 3, category: "APRS SETTING", tab: "MSG TEMPLATE", label: "MESSAGE TEXT3", valueType: new Text(maxLength: 16)),
        new(p1: 6, p2: 2, p3: 4, category: "APRS SETTING", tab: "MSG TEMPLATE", label: "MESSAGE TEXT4", valueType: new Text(maxLength: 16)),
        new(p1: 6, p2: 2, p3: 5, category: "APRS SETTING", tab: "MSG TEMPLATE", label: "MESSAGE TEXT5", valueType: new Text(maxLength: 16)),
        new(p1: 6, p2: 2, p3: 6, category: "APRS SETTING", tab: "MSG TEMPLATE", label: "MESSAGE TEXT6", valueType: new Text(maxLength: 16)),
        new(p1: 6, p2: 2, p3: 7, category: "APRS SETTING", tab: "MSG TEMPLATE", label: "MESSAGE TEXT7", valueType: new Text(maxLength: 16)),
        new(p1: 6, p2: 2, p3: 8, category: "APRS SETTING", tab: "MSG TEMPLATE", label: "MESSAGE TEXT8", valueType: new Text(maxLength: 16)),

        // 06.03 (MY SYMBOL)
        new(p1: 6, p2: 3, p3: 1, category: "APRS SETTING", tab: "MY SYMBOL", label: "MY SYMBOL", valueType: new Enumeration(cases: [
            new(0, "ICON1"), new(1, "ICON2"), new(2, "ICON3"), new(3, "USER"),
        ], digits: 1)),
        new(p1: 6, p2: 3, p3: 2, category: "APRS SETTING", tab: "MY SYMBOL", label: "ICON1", valueType: new Text(maxLength: 2)),
        new(p1: 6, p2: 3, p3: 3, category: "APRS SETTING", tab: "MY SYMBOL", label: "ICON2", valueType: new Text(maxLength: 2)),
        new(p1: 6, p2: 3, p3: 4, category: "APRS SETTING", tab: "MY SYMBOL", label: "ICON3", valueType: new Text(maxLength: 2)),
        new(p1: 6, p2: 3, p3: 5, category: "APRS SETTING", tab: "MY SYMBOL", label: "USER", valueType: new Text(maxLength: 2)),

        // 06.04 (DIGI PATH)
        new(p1: 6, p2: 4, p3: 1, category: "APRS SETTING", tab: "DIGI PATH", label: "PATH SELECT", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "WIDE1-1"), new(2, "WIDE1-1,WIDE2-1"),
        ], digits: 1)),
    ];

    private static readonly DeepSettingItem[] AprsBeaconItems =
    [
        // 07.01 (BEACON SET.)
        new(p1: 7, p2: 1, p3: 1, category: "APRS BEACON", tab: "BEACON SET.", label: "BEACON TYPE", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "AUTO"), new(2, "SMART"),
        ], digits: 1)),
        new(p1: 7, p2: 1, p3: 2, category: "APRS BEACON", tab: "BEACON SET.", label: "INFO AMBIGUITY", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "1 dig"), new(2, "2 dig"), new(3, "3 dig"), new(4, "4 dig"),
        ], digits: 1)),
        new(p1: 7, p2: 1, p3: 3, category: "APRS BEACON", tab: "BEACON SET.", label: "INFO SPEED/COURSE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 7, p2: 1, p3: 4, category: "APRS BEACON", tab: "BEACON SET.", label: "INFO ALTITUDE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 7, p2: 1, p3: 5, category: "APRS BEACON", tab: "BEACON SET.", label: "POSITION COMMENT", valueType: new Enumeration(cases: [
            new(0, "Off duty"), new(1, "En Route"), new(2, "In Service"), new(3, "Returning"), new(4, "Committed"),
            new(5, "Special"), new(6, "Priority"), new(7, "Custom 0"), new(8, "Custom 1"), new(9, "Custom 2"),
            new(10, "Custom 3"), new(11, "Custom 4"), new(12, "Custom 5"), new(13, "Custom 6"), new(14, "EMERGENCY!"),
        ], digits: 2)),
        new(p1: 7, p2: 1, p3: 6, category: "APRS BEACON", tab: "BEACON SET.", label: "EMERGENCY BEACON", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),

        // 07.02 (AUTO BEACON)
        new(p1: 7, p2: 2, p3: 1, category: "APRS BEACON", tab: "AUTO BEACON", label: "INTERVAL TIME", valueType: new Enumeration(cases: [
            new(0, "30 sec"), new(1, "1 min"), new(2, "2 min"), new(3, "3 min"), new(4, "5 min"),
            new(5, "10 min"), new(6, "15 min"), new(7, "20 min"), new(8, "30 min"), new(9, "60 min"),
        ], digits: 1)),
        new(p1: 7, p2: 2, p3: 2, category: "APRS BEACON", tab: "AUTO BEACON", label: "PROPORTIONAL", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 7, p2: 2, p3: 3, category: "APRS BEACON", tab: "AUTO BEACON", label: "DECAY", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 7, p2: 2, p3: 4, category: "APRS BEACON", tab: "AUTO BEACON", label: "AUTO LOW SPEED", valueType: new IntRange(1, 99, digits: 2, unit: "km/h or mph", step: 1)),
        new(p1: 7, p2: 2, p3: 5, category: "APRS BEACON", tab: "AUTO BEACON", label: "BEACON DELAY", valueType: new IntRange(5, 180, digits: 3, unit: "sec", step: 1)),

        // 07.03 (SmartBeac.)
        new(p1: 7, p2: 3, p3: 1, category: "APRS BEACON", tab: "SmartBeac.", label: "SMART LOW SPEED", valueType: new IntRange(2, 30, digits: 2, unit: "km/h or mph", step: 1)),
        new(p1: 7, p2: 3, p3: 2, category: "APRS BEACON", tab: "SmartBeac.", label: "SMART HIGH SPEED", valueType: new IntRange(3, 90, digits: 2, unit: "km/h or mph", step: 1)),
        new(p1: 7, p2: 3, p3: 3, category: "APRS BEACON", tab: "SmartBeac.", label: "SMART SLOW RATE", valueType: new IntRange(1, 100, digits: 3, unit: "min", step: 1)),
        new(p1: 7, p2: 3, p3: 4, category: "APRS BEACON", tab: "SmartBeac.", label: "SMART FAST RATE", valueType: new IntRange(10, 180, digits: 3, unit: "sec", step: 1)),
        new(p1: 7, p2: 3, p3: 5, category: "APRS BEACON", tab: "SmartBeac.", label: "SMART TURN ANGLE", valueType: new IntRange(5, 90, digits: 2, unit: "°", step: 1)),
        new(p1: 7, p2: 3, p3: 6, category: "APRS BEACON", tab: "SmartBeac.", label: "SMART TURN SLOPE", valueType: new IntRange(1, 255, digits: 3, unit: null, step: 1)),
        new(p1: 7, p2: 3, p3: 7, category: "APRS BEACON", tab: "SmartBeac.", label: "SMART TURN TIME", valueType: new IntRange(5, 180, digits: 3, unit: "sec", step: 1)),

        // 07.04 (BEACON TEXT)
        new(p1: 7, p2: 4, p3: 1, category: "APRS BEACON", tab: "BEACON TEXT", label: "STATUS TEXT SELECT", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "TEXT1"), new(2, "TEXT2"), new(3, "TEXT3"), new(4, "TEXT4"), new(5, "TEXT5"),
        ], digits: 1)),
        new(p1: 7, p2: 4, p3: 2, category: "APRS BEACON", tab: "BEACON TEXT", label: "TX RATE", valueType: new Enumeration(cases: [
            new(0, "1/1"), new(1, "1/2"), new(2, "1/3"), new(3, "1/4"), new(4, "1/5"), new(5, "1/6"), new(6, "1/7"), new(7, "1/8"),
        ], digits: 1)),
        new(p1: 7, p2: 4, p3: 3, category: "APRS BEACON", tab: "BEACON TEXT", label: "BEACON FREQUENCY", valueType: new Enumeration(cases: [
            new(0, "None"), new(1, "FREQUENCY"), new(2, "FREQ & SQL & SHIFT"),
        ], digits: 1)),
        new(p1: 7, p2: 4, p3: 4, category: "APRS BEACON", tab: "BEACON TEXT", label: "STATUS TEXT1", valueType: new Text(maxLength: 60)),
        new(p1: 7, p2: 4, p3: 5, category: "APRS BEACON", tab: "BEACON TEXT", label: "STATUS TEXT2", valueType: new Text(maxLength: 60)),
        new(p1: 7, p2: 4, p3: 6, category: "APRS BEACON", tab: "BEACON TEXT", label: "STATUS TEXT3", valueType: new Text(maxLength: 60)),
        new(p1: 7, p2: 4, p3: 7, category: "APRS BEACON", tab: "BEACON TEXT", label: "STATUS TEXT4", valueType: new Text(maxLength: 60)),
        new(p1: 7, p2: 4, p3: 8, category: "APRS BEACON", tab: "BEACON TEXT", label: "STATUS TEXT5", valueType: new Text(maxLength: 60)),
    ];

    private static readonly DeepSettingItem[] AprsFilterItems =
    [
        // 08.01 (LIST SETTING)
        new(p1: 8, p2: 1, p3: 1, category: "APRS FILTER", tab: "LIST SETTING", label: "STATION LIST SORT", valueType: new Enumeration(cases: [
            new(0, "TIME"), new(1, "CALLSIGN"), new(2, "DISTANCE"),
        ], digits: 1)),

        // 08.02 (STATION LIST)
        new(p1: 8, p2: 2, p3: 1, category: "APRS FILTER", tab: "STATION LIST", label: "Mic-E", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 2, p3: 2, category: "APRS FILTER", tab: "STATION LIST", label: "POSITION", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 2, p3: 3, category: "APRS FILTER", tab: "STATION LIST", label: "WEATHER", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 2, p3: 4, category: "APRS FILTER", tab: "STATION LIST", label: "OBJECT", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 2, p3: 5, category: "APRS FILTER", tab: "STATION LIST", label: "ITEM", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 2, p3: 6, category: "APRS FILTER", tab: "STATION LIST", label: "STATUS", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 2, p3: 7, category: "APRS FILTER", tab: "STATION LIST", label: "OTHER", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 2, p3: 8, category: "APRS FILTER", tab: "STATION LIST", label: "ALTNET", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),

        // 08.03 (POPUP)
        new(p1: 8, p2: 3, p3: 1, category: "APRS FILTER", tab: "POPUP", label: "BEACON", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "3 sec"), new(2, "5 sec"), new(3, "10 sec"), new(4, "HOLD"),
        ], digits: 1)),
        new(p1: 8, p2: 3, p3: 2, category: "APRS FILTER", tab: "POPUP", label: "MESSAGE", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "3 sec"), new(2, "5 sec"), new(3, "10 sec"), new(4, "HOLD"),
        ], digits: 1)),

        // 08.04 (RINGER)
        new(p1: 8, p2: 4, p3: 1, category: "APRS FILTER", tab: "RINGER", label: "TX BEACON", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 4, p3: 2, category: "APRS FILTER", tab: "RINGER", label: "RX BEACON", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 4, p3: 3, category: "APRS FILTER", tab: "RINGER", label: "TX MESSAGE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 4, p3: 4, category: "APRS FILTER", tab: "RINGER", label: "RX MESSAGE", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),
        new(p1: 8, p2: 4, p3: 5, category: "APRS FILTER", tab: "RINGER", label: "MY PACKET", valueType: new Toggle(offLabel: "OFF", onLabel: "ON")),

        // 08.05 (MSG FIL.) — confirmed via live probe (EX080501); manual's
        // printed table looked like this tab was at P2=06 with a gap at 05.
        new(p1: 8, p2: 5, p3: 1, category: "APRS FILTER", tab: "MSG FIL.", label: "MESSAGE GROUP1", valueType: new Text(maxLength: 9)),
        new(p1: 8, p2: 5, p3: 2, category: "APRS FILTER", tab: "MSG FIL.", label: "MESSAGE GROUP2", valueType: new Text(maxLength: 9)),
        new(p1: 8, p2: 5, p3: 3, category: "APRS FILTER", tab: "MSG FIL.", label: "MESSAGE GROUP3", valueType: new Text(maxLength: 9)),
        new(p1: 8, p2: 5, p3: 4, category: "APRS FILTER", tab: "MSG FIL.", label: "MESSAGE GROUP4", valueType: new Text(maxLength: 9)),
        new(p1: 8, p2: 5, p3: 5, category: "APRS FILTER", tab: "MSG FIL.", label: "MESSAGE GROUP5", valueType: new Text(maxLength: 9)),
        new(p1: 8, p2: 5, p3: 6, category: "APRS FILTER", tab: "MSG FIL.", label: "MESSAGE GROUP6", valueType: new Text(maxLength: 9)),
        new(p1: 8, p2: 5, p3: 7, category: "APRS FILTER", tab: "MSG FIL.", label: "BULLETIN 1", valueType: new Text(maxLength: 9)),
        new(p1: 8, p2: 5, p3: 8, category: "APRS FILTER", tab: "MSG FIL.", label: "BULLETIN 2", valueType: new Text(maxLength: 9)),
        new(p1: 8, p2: 5, p3: 9, category: "APRS FILTER", tab: "MSG FIL.", label: "BULLETIN 3", valueType: new Text(maxLength: 9)),
    ];

    private static readonly DeepSettingItem[] DisplaySettingItems =
    [
        // 04.01 (DISPLAY)
        new(p1: 4, p2: 1, p3: 1, category: "DISPLAY SETTING", tab: "DISPLAY", label: "MY CALL", valueType: new Text(maxLength: 10)),
        new(p1: 4, p2: 1, p3: 2, category: "DISPLAY SETTING", tab: "DISPLAY", label: "MY CALL TIME", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "1 sec"), new(2, "2 sec"), new(3, "3 sec"), new(4, "4 sec"), new(5, "5 sec"),
        ], digits: 1)),
        new(p1: 4, p2: 1, p3: 3, category: "DISPLAY SETTING", tab: "DISPLAY", label: "POP-UP TIME", valueType: new Enumeration(cases: [
            new(0, "FAST"), new(1, "MID"), new(2, "SLOW"),
        ], digits: 1)),
        new(p1: 4, p2: 1, p3: 4, category: "DISPLAY SETTING", tab: "DISPLAY", label: "SCREEN SAVER", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "1 min"), new(2, "2 min"), new(3, "5 min"), new(4, "15 min"), new(5, "30 min"), new(6, "60 min"),
        ], digits: 1)),
        new(p1: 4, p2: 1, p3: 5, category: "DISPLAY SETTING", tab: "DISPLAY", label: "SCREEN SAVER (BAT)", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "1 min"), new(2, "2 min"), new(3, "5 min"), new(4, "15 min"), new(5, "30 min"), new(6, "60 min"),
        ], digits: 1)),
        new(p1: 4, p2: 1, p3: 6, category: "DISPLAY SETTING", tab: "DISPLAY", label: "SAVER TYPE", valueType: new Enumeration(cases: [
            new(0, "Logo"), new(1, "DIMMER"), new(2, "DISP OFF"),
        ], digits: 1)),
        // See AutoPowerOffCases above — confirmed OFF + 0.5h steps to 12h,
        // 2 digits, not the manual's condensed/mistranscribed 1-digit cell.
        new(p1: 4, p2: 1, p3: 7, category: "DISPLAY SETTING", tab: "DISPLAY", label: "AUTO POWER OFF", valueType: new Enumeration(cases: AutoPowerOffCases, digits: 2)),

        // 04.02 (UNIT)
        new(p1: 4, p2: 2, p3: 1, category: "DISPLAY SETTING", tab: "UNIT", label: "POSITION UNIT", valueType: new Enumeration(cases: [
            new(0, "dd°MM.mm'"), new(1, "dd°mm'ss\""),
        ], digits: 1)),
        new(p1: 4, p2: 2, p3: 2, category: "DISPLAY SETTING", tab: "UNIT", label: "DISTANCE UNIT", valueType: new Enumeration(cases: [
            new(0, "km"), new(1, "mile"),
        ], digits: 1)),
        new(p1: 4, p2: 2, p3: 3, category: "DISPLAY SETTING", tab: "UNIT", label: "SPEED UNIT", valueType: new Enumeration(cases: [
            new(0, "km/h"), new(1, "knot"), new(2, "mph"),
        ], digits: 1)),
        new(p1: 4, p2: 2, p3: 4, category: "DISPLAY SETTING", tab: "UNIT", label: "ALTITUDE UNIT", valueType: new Enumeration(cases: [
            new(0, "m"), new(1, "ft"),
        ], digits: 1)),
        new(p1: 4, p2: 2, p3: 5, category: "DISPLAY SETTING", tab: "UNIT", label: "TEMP UNIT", valueType: new Enumeration(cases: [
            new(0, "°C"), new(1, "°F"),
        ], digits: 1)),
        new(p1: 4, p2: 2, p3: 6, category: "DISPLAY SETTING", tab: "UNIT", label: "RAIN UNIT", valueType: new Enumeration(cases: [
            new(0, "mm"), new(1, "INCH"),
        ], digits: 1)),
        new(p1: 4, p2: 2, p3: 7, category: "DISPLAY SETTING", tab: "UNIT", label: "WIND UNIT", valueType: new Enumeration(cases: [
            new(0, "m/s"), new(1, "mph"),
        ], digits: 1)),

        // 04.03 (SCOPE)
        new(p1: 4, p2: 3, p3: 1, category: "DISPLAY SETTING", tab: "SCOPE", label: "RBW", valueType: new Enumeration(cases: [
            new(0, "HIGH"), new(1, "MID"), new(2, "LOW"),
        ], digits: 1)),
        new(p1: 4, p2: 3, p3: 2, category: "DISPLAY SETTING", tab: "SCOPE", label: "SCOPE CTR", valueType: new Enumeration(cases: [
            new(0, "FILTER"), new(1, "CARRIER"),
        ], digits: 1)),
        new(p1: 4, p2: 3, p3: 3, category: "DISPLAY SETTING", tab: "SCOPE", label: "2D DISP SENSITIVITY", valueType: new Enumeration(cases: [
            new(0, "NORMAL"), new(1, "HI"),
        ], digits: 1)),
        new(p1: 4, p2: 3, p3: 4, category: "DISPLAY SETTING", tab: "SCOPE", label: "3DSS DISP SENSITIVITY", valueType: new Enumeration(cases: [
            new(0, "NORMAL"), new(1, "HI"),
        ], digits: 1)),
        new(p1: 4, p2: 3, p3: 5, category: "DISPLAY SETTING", tab: "SCOPE", label: "AVERAGE", valueType: new Enumeration(cases: [
            new(0, "OFF"), new(1, "2"), new(2, "4"), new(3, "8"),
        ], digits: 1)),

        // 04.04 (VFO IND COLOR)
        new(p1: 4, p2: 4, p3: 1, category: "DISPLAY SETTING", tab: "VFO IND COLOR", label: "VMI COLOR VFO", valueType: new Enumeration(cases: [
            new(0, "BLUE"), new(1, "GREEN"), new(2, "WHITE"), new(3, "NONE"),
        ], digits: 1)),
        new(p1: 4, p2: 4, p3: 2, category: "DISPLAY SETTING", tab: "VFO IND COLOR", label: "VMI COLOR MEMORY", valueType: new Enumeration(cases: [
            new(0, "BLUE"), new(1, "GREEN"), new(2, "WHITE"), new(3, "NONE"),
        ], digits: 1)),
        new(p1: 4, p2: 4, p3: 3, category: "DISPLAY SETTING", tab: "VFO IND COLOR", label: "VMI COLOR CLAR", valueType: new Enumeration(cases: [
            new(0, "RED"), new(1, "NONE"),
        ], digits: 1)),
    ];

    /// Every item, in the Swift catalog's order. Declared last: static
    /// fields initialize in textual order.
    public static readonly DeepSettingItem[] Items =
        [.. RadioSettingItems, .. CwSettingItems, .. OperationSettingItems, .. ExtensionSettingItems,
         .. AprsSettingItems, .. AprsBeaconItems, .. AprsFilterItems, .. DisplaySettingItems];
}

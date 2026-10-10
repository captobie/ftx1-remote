using System.Globalization;
using System.Text;

namespace FTX1RemoteWindows.Models;

/// One completed contact, as handed to an external logbook — the Mac's
/// LoggedQSO (Sources/FTX1Core/Logbook/LoggedQSO.swift), same fields.
/// Empty strings mean "not given" and are left out of the ADIF record.
public sealed record LoggedQso
{
    public required string Call { get; init; }
    public string Grid { get; init; } = "";
    public required DateTimeOffset Start { get; init; }
    public required DateTimeOffset End { get; init; }
    /// The transmit frequency — what the logbook files the QSO under.
    public required long FrequencyHz { get; init; }
    /// ADIF mode name, e.g. "CW", "SSB", "FM".
    public required string Mode { get; init; }
    /// ADIF submode, e.g. "USB" for mode "SSB".
    public string Submode { get; init; } = "";
    public string RstSent { get; init; } = "";
    public string RstReceived { get; init; } = "";
    public string TxPower { get; init; } = "";
    public string Comments { get; init; } = "";
    public string Name { get; init; } = "";
    public string MyCall { get; init; } = "";
    public string MyGrid { get; init; } = "";

    /// ADIF band name ("40m", "2m", …) — BandPlan's names are already
    /// ADIF's. Empty outside the amateur bands.
    public string Band => BandPlan.BandContaining(FrequencyHz)?.Name ?? "";
}

/// ADIF mode/submode for a rig mode, for logging — the Mac's ADIFMode. Data
/// modes have none: DATA-U/DATA-FM carry FT8, RTTY, packet… and the rig
/// can't say which, so a QSO in them needs its mode from whatever decoded
/// it. C4FM is a flag here (RigState.MainIsC4fm/SubIsC4fm), not a RigMode.
public readonly record struct AdifMode(string Mode, string Submode = "")
{
    public static AdifMode? For(RigMode? mode, bool isC4fm)
    {
        if (isC4fm)
        {
            return new AdifMode("DIGITALVOICE", "C4FM");
        }
        return mode switch
        {
            RigMode.Cw => new AdifMode("CW"),
            RigMode.Usb => new AdifMode("SSB", "USB"),
            RigMode.Lsb => new AdifMode("SSB", "LSB"),
            RigMode.Am => new AdifMode("AM"),
            RigMode.Fm => new AdifMode("FM"),
            RigMode.Rtty => new AdifMode("RTTY"),
            _ => null,
        };
    }
}

/// Writes a LoggedQso as an ADIF file with one record (header, &lt;EOH&gt;,
/// fields, &lt;EOR&gt;) — the Mac's ADIFRecord, same fields and formats.
/// HRD Logbook's ADIF receiver (its "UDP9/ADIF" QSO forwarding option)
/// takes exactly this as a UDP datagram, the form WSJT-X's secondary "ADIF
/// broadcast" server sends. Field lengths count UTF-8 bytes; for the ASCII
/// every logbook expects that's the same as ADIF's character count.
public static class AdifRecord
{
    public const string ProgramId = "FTX1Remote";

    public static string File(LoggedQso qso) =>
        "<adif_ver:5>3.1.4\n" + Field("programid", ProgramId) + "\n<EOH>\n" + Record(qso);

    /// The record alone, ending in &lt;EOR&gt;. Empty values are left out.
    public static string Record(LoggedQso qso)
    {
        var fields = new (string Name, string Value)[]
        {
            ("call", qso.Call),
            ("gridsquare", qso.Grid),
            ("mode", qso.Mode),
            ("submode", qso.Submode),
            ("rst_sent", qso.RstSent),
            ("rst_rcvd", qso.RstReceived),
            ("qso_date", Date(qso.Start)),
            ("time_on", Time(qso.Start)),
            ("qso_date_off", Date(qso.End)),
            ("time_off", Time(qso.End)),
            ("band", qso.Band),
            ("freq", Frequency(qso.FrequencyHz)),
            ("station_callsign", qso.MyCall),
            ("my_gridsquare", qso.MyGrid),
            ("tx_pwr", qso.TxPower),
            ("comment", qso.Comments),
            ("name", qso.Name),
        };
        return string.Join(" ", fields.Where(f => f.Value.Length > 0).Select(f => Field(f.Name, f.Value))) + " <EOR>";
    }

    public static string Field(string name, string value) => $"<{name}:{Encoding.UTF8.GetByteCount(value)}>{value}";

    /// YYYYMMDD, UTC.
    public static string Date(DateTimeOffset date) => date.UtcDateTime.ToString("yyyyMMdd", CultureInfo.InvariantCulture);

    /// HHMMSS, UTC.
    public static string Time(DateTimeOffset date) => date.UtcDateTime.ToString("HHmmss", CultureInfo.InvariantCulture);

    /// MHz with six decimals (1 Hz resolution).
    public static string Frequency(long hz) =>
        string.Create(CultureInfo.InvariantCulture, $"{hz / 1_000_000}.{hz % 1_000_000:D6}");
}

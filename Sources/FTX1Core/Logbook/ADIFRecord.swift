import Foundation

/// Writes a `LoggedQSO` as an ADIF file with one record, the form WSJT-X's
/// "Logged ADIF" UDP message carries (header, `<EOH>`, fields, `<EOR>`).
/// Field lengths count UTF-8 bytes; for the ASCII every logbook expects
/// that's the same as ADIF's character count.
public enum ADIFRecord {
    public static let programID = "FTX1Remote"

    public static func file(for qso: LoggedQSO) -> String {
        "<adif_ver:5>3.1.4\n" + field("programid", programID) + "\n<EOH>\n" + record(for: qso)
    }

    /// The record alone, ending in `<EOR>`. Empty values are left out.
    public static func record(for qso: LoggedQSO) -> String {
        let fields: [(String, String)] = [
            ("call", qso.call),
            ("gridsquare", qso.grid),
            ("mode", qso.mode),
            ("submode", qso.submode),
            ("rst_sent", qso.rstSent),
            ("rst_rcvd", qso.rstReceived),
            ("qso_date", date(qso.start)),
            ("time_on", time(qso.start)),
            ("qso_date_off", date(qso.end)),
            ("time_off", time(qso.end)),
            ("band", qso.band),
            ("freq", frequency(qso.frequencyHz)),
            ("station_callsign", qso.myCall),
            ("my_gridsquare", qso.myGrid),
            ("tx_pwr", qso.txPower),
            ("comment", qso.comments),
            ("name", qso.name),
        ]
        return fields
            .filter { !$0.1.isEmpty }
            .map { field($0.0, $0.1) }
            .joined(separator: " ") + " <EOR>"
    }

    static func field(_ name: String, _ value: String) -> String {
        "<\(name):\(value.utf8.count)>\(value)"
    }

    /// YYYYMMDD, UTC.
    static func date(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }

    /// HHMMSS, UTC.
    static func time(_ date: Date) -> String {
        let c = utc.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d%02d%02d", c.hour!, c.minute!, c.second!)
    }

    /// MHz with six decimals (1 Hz resolution).
    static func frequency(_ hz: Int) -> String {
        String(format: "%d.%06d", hz / 1_000_000, hz % 1_000_000)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

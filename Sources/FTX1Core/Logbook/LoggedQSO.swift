import Foundation

/// One completed contact, as handed to an external logbook — the fields
/// WSJT-X's "QSO Logged" UDP message carries (see `WSJTXMessage`), which
/// is also what `ADIFRecord` writes. Empty strings mean "not given" and are
/// left out of the ADIF record.
public struct LoggedQSO: Equatable, Sendable {
    public var call: String
    public var grid: String
    public var start: Date
    public var end: Date
    /// The transmit frequency — what the logbook files the QSO under.
    public var frequencyHz: Int
    /// ADIF mode name, e.g. "CW", "SSB", "FM", "FT8".
    public var mode: String
    /// ADIF submode, e.g. "USB" for mode "SSB". Only in the ADIF record;
    /// WSJT-X's binary "QSO Logged" message has no field for it.
    public var submode: String
    public var rstSent: String
    public var rstReceived: String
    public var txPower: String
    public var comments: String
    public var name: String
    public var myCall: String
    public var myGrid: String

    public init(
        call: String,
        grid: String = "",
        start: Date,
        end: Date,
        frequencyHz: Int,
        mode: String,
        submode: String = "",
        rstSent: String = "",
        rstReceived: String = "",
        txPower: String = "",
        comments: String = "",
        name: String = "",
        myCall: String = "",
        myGrid: String = ""
    ) {
        self.call = call
        self.grid = grid
        self.start = start
        self.end = end
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.submode = submode
        self.rstSent = rstSent
        self.rstReceived = rstReceived
        self.txPower = txPower
        self.comments = comments
        self.name = name
        self.myCall = myCall
        self.myGrid = myGrid
    }

    /// ADIF band name ("40m", "2m", …) — `BandPlan`'s names are already
    /// ADIF's. Empty outside the amateur bands.
    public var band: String {
        BandPlan.band(containing: frequencyHz)?.name ?? ""
    }
}

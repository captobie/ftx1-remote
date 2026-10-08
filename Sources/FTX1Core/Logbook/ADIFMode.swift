/// ADIF mode/submode for a rig mode, for logging. Data modes have none:
/// DATA-U/DATA-FM carry FT8, RTTY, packet… and the rig can't say which,
/// so a QSO in them needs its mode from whatever decoded it.
public struct ADIFMode: Equatable, Sendable {
    public var mode: String
    public var submode: String

    public init(mode: String, submode: String = "") {
        self.mode = mode
        self.submode = submode
    }

    public init?(_ rigMode: RigMode) {
        switch rigMode {
        case .cw: self.init(mode: "CW")
        case .usb: self.init(mode: "SSB", submode: "USB")
        case .lsb: self.init(mode: "SSB", submode: "LSB")
        case .am: self.init(mode: "AM")
        case .fm: self.init(mode: "FM")
        case .rtty: self.init(mode: "RTTY")
        case .c4fm: self.init(mode: "DIGITALVOICE", submode: "C4FM")
        case .dataUSB, .dataFM, .unknown: return nil
        }
    }
}

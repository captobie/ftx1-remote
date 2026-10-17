#if os(macOS)
import Darwin
import Foundation

extension CWKeyingLine {
    var bit: Int32 {
        switch self {
        case .rts: TIOCM_RTS
        case .dtr: TIOCM_DTR
        }
    }

    var other: CWKeyingLine { self == .rts ? .dtr : .rts }
}

/// Keys the rig by toggling RTS or DTR on its second USB serial port (the
/// CP2105's "Standard COM Port", CAT-2) with `TIOCMBIS`/`TIOCMBIC`. Never
/// the CAT port, which stays rigctld's.
///
/// **Normal polarity** (`invertedPolarity` false): line asserted = key
/// down. The safe one: closing the port — and the kernel closing it when
/// the app dies (`HUPCL`) — drops both lines, i.e. key-up. With inverted
/// polarity a dropped line is key-*down*, so a crash or unplug would key
/// the rig; the settings UI warns about it.
///
/// Opening a serial port on macOS asserts DTR and RTS until told
/// otherwise, so `open` sets both lines to key-up immediately after —
/// a glitch of well under a millisecond that the rig could see as a key
/// closure if PC KEYING is already set. Arm only in CW, into a dummy
/// load, until that's been checked on the rig.
///
/// The other line is held cleared, so it can't trigger the menu's RPTT
/// SELECT if that is set to it.
public final class ModemLineCWKeyer: CWKeyer {
    public let path: String
    public let line: CWKeyingLine
    public let invertedPolarity: Bool
    private let port: POSIXSerialPort

    public init(path: String, line: CWKeyingLine, invertedPolarity: Bool) {
        self.path = path
        self.line = line
        self.invertedPolarity = invertedPolarity
        port = POSIXSerialPort(path: path)
    }

    deinit { close() }

    public func open() throws {
        try port.open(baudRate: nil)
        do {
            try port.setModemLines(line.other.bit, asserted: false)
            try setKeyed(false)
        } catch {
            port.close()
            throw error
        }
    }

    public func setKeyed(_ keyed: Bool) throws {
        try port.setModemLines(line.bit, asserted: keyed != invertedPolarity)
    }

    public func close() {
        guard port.isOpen else { return }
        try? setKeyed(false)
        port.close()
    }
}
#endif

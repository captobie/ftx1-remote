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
///
/// `release` and `open` read the line back (`TIOCMGET`): a USB control
/// transfer to the CP2105 can fail mid-transmission (seen on the Pi,
/// 2026-10-17: "failed set request 0x7 status: -71"), and then the line
/// may still be keyed. `CWKeyingDriver` retries until it reads up.
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
            try release()
        } catch {
            port.close()
            throw error
        }
    }

    public func setKeyed(_ keyed: Bool) throws {
        try port.setModemLines(line.bit, asserted: keyed != invertedPolarity)
    }

    /// Key-up, then read back. A driver that can't report the lines at all
    /// (`ENOTTY`/`EINVAL` from `TIOCMGET`) leaves it unconfirmed, as
    /// before the read-back existed — `readBackSupported` turns false so
    /// the caller can say so.
    public func release() throws {
        try setKeyed(false)
        let bits: Int32
        do {
            bits = try port.modemLines()
        } catch SerialPortError.modemLines(_, let code) where code == ENOTTY || code == EINVAL {
            readBackSupported = false
            return
        }
        let asserted = (bits & line.bit) != 0
        guard asserted == invertedPolarity else { throw ModemLineError.stillKeyed(path) }
    }

    /// False once the driver has refused `TIOCMGET`: key-ups unconfirmed.
    public private(set) var readBackSupported = true

    public func reopen() throws {
        port.close()
        try open()
    }

    public func close() {
        guard port.isOpen else { return }
        try? setKeyed(false)
        port.close()
    }
}
public enum ModemLineError: Error, CustomStringConvertible {
    case stillKeyed(String)

    public var description: String {
        switch self {
        case .stillKeyed(let path): String(localized: "modemLineCWKeyer.theLineStillReads \(path)", bundle: .module)
        }
    }
}
#endif

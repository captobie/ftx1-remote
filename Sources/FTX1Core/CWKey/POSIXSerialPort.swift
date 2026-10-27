#if os(macOS)
import Darwin
import Foundation

public enum SerialPortError: Error, Equatable, CustomStringConvertible {
    case open(path: String, errno: Int32)
    case configure(path: String, errno: Int32)
    case modemLines(path: String, errno: Int32)
    case write(path: String, errno: Int32)
    case closed

    public var description: String {
        switch self {
        case .open(let path, let code):
            code == EBUSY
                ? String(localized: "posixSerialPort.isInUseBy \(path)", bundle: .module)
                : String(localized: "posixSerialPort.cantOpen \(path) \(String(cString: strerror(code)))", bundle: .module)
        case .configure(let path, let code): String(localized: "posixSerialPort.cantConfigure \(path) \(String(cString: strerror(code)))", bundle: .module)
        case .modemLines(let path, let code): String(localized: "posixSerialPort.cantSetRtsDtr \(path) \(String(cString: strerror(code)))", bundle: .module)
        case .write(let path, let code): String(localized: "posixSerialPort.cantWriteTo \(path) \(String(cString: strerror(code)))", bundle: .module)
        case .closed: String(localized: "posixSerialPort.portClosed", bundle: .module)
        }
    }
}

/// A serial device opened with POSIX calls: raw 8N1, non-blocking, held
/// exclusively (`TIOCEXCL`, so rigctld or another app can't open it
/// behind our back while we hold it), and with `HUPCL` so the kernel drops
/// RTS/DTR when the descriptor closes — including when the process dies,
/// which is the keyer's crash-path release.
///
/// Not thread-safe: use one from a single queue.
public final class POSIXSerialPort {
    public let path: String
    public private(set) var fileDescriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit { close() }

    public var isOpen: Bool { fileDescriptor >= 0 }

    /// Opens and configures the port. `baudRate` nil leaves the speed as
    /// is (the keying port: only its control lines matter).
    public func open(baudRate: speed_t?) throws {
        close()
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialPortError.open(path: path, errno: errno) }
        guard ioctl(fd, TIOCEXCL) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SerialPortError.open(path: path, errno: code)
        }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SerialPortError.configure(path: path, errno: code)
        }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD | HUPCL)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        if let baudRate {
            cfsetspeed(&options, baudRate)
        }
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SerialPortError.configure(path: path, errno: code)
        }
        fileDescriptor = fd
    }

    public func close() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    /// Asserts (`TIOCMBIS`) or clears (`TIOCMBIC`) modem-control lines,
    /// e.g. `TIOCM_RTS | TIOCM_DTR`.
    public func setModemLines(_ lines: Int32, asserted: Bool) throws {
        guard fileDescriptor >= 0 else { throw SerialPortError.closed }
        var bits = lines
        let request = asserted ? TIOCMBIS : TIOCMBIC
        guard ioctl(fileDescriptor, request, &bits) == 0 else {
            throw SerialPortError.modemLines(path: path, errno: errno)
        }
    }

    /// The modem-control bits as the driver reports them (`TIOCMGET`).
    public func modemLines() throws -> Int32 {
        guard fileDescriptor >= 0 else { throw SerialPortError.closed }
        var bits: Int32 = 0
        guard ioctl(fileDescriptor, TIOCMGET, &bits) == 0 else {
            throw SerialPortError.modemLines(path: path, errno: errno)
        }
        return bits
    }

    /// Reads what's available. nil when nothing is (EAGAIN); throws on an
    /// error or end of file (the device went away).
    public func readAvailable(into buffer: inout [UInt8]) throws -> Int? {
        guard fileDescriptor >= 0 else { throw SerialPortError.closed }
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
        if count > 0 { return count }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return nil }
        throw SerialPortError.closed
    }

    public func write(_ bytes: [UInt8]) throws {
        guard fileDescriptor >= 0 else { throw SerialPortError.closed }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fileDescriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw SerialPortError.write(path: path, errno: errno)
            }
            offset += written
        }
    }

    /// The `/dev/cu.*` devices, for the port pickers. `cu.` rather than
    /// `tty.`: opening a `tty.` waits for carrier detect.
    public static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/" + $0 }
    }
}
#endif

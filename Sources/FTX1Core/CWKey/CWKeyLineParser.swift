import Foundation

/// The CW key interface's settings, from its "S" status line.
public struct CWKeyDeviceStatus: Sendable, Equatable {
    public var wpm: Int
    /// Iambic mode B (else A). Paddle-only; unused while the straight key
    /// is the only input.
    public var iambicModeB: Bool
    public var paddleReversed: Bool
    public var sidetoneOn: Bool
    public var deviceMs: UInt32

    public init(wpm: Int, iambicModeB: Bool, paddleReversed: Bool, sidetoneOn: Bool, deviceMs: UInt32) {
        self.wpm = wpm
        self.iambicModeB = iambicModeB
        self.paddleReversed = paddleReversed
        self.sidetoneOn = sidetoneOn
        self.deviceMs = deviceMs
    }
}

/// One line of the CW key interface's serial protocol (`cw_keyer/
/// cw_keyer.ino`, protocol version 1). `deviceMs` is the device's own
/// `millis()`, which wraps at 2^32 (`CWDeviceClockUnwrapper`).
public enum CWKeyLine: Sendable, Equatable {
    /// "I,<id>,<version>" — sent once after the device boots (and so after
    /// every port open, since opening the UNO's port resets it).
    case banner(id: String, version: Int)
    case keyDown(deviceMs: UInt32)
    case keyUp(deviceMs: UInt32)
    /// Every 250 ms.
    case heartbeat(deviceMs: UInt32)
    case status(CWKeyDeviceStatus)

    /// The device time the line carries, if any.
    public var deviceMs: UInt32? {
        switch self {
        case .banner: nil
        case .keyDown(let ms), .keyUp(let ms), .heartbeat(let ms): ms
        case .status(let status): status.deviceMs
        }
    }

    /// Parses one line without its terminator. nil for anything that isn't
    /// exactly one of the documented shapes — garbage, a line cut short by
    /// the reset, an unknown kind — so the caller just skips it.
    public static func parse(_ line: Substring) -> CWKeyLine? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard let kind = fields.first else { return nil }
        switch kind {
        case "I":
            guard fields.count == 3, !fields[1].isEmpty,
                  fields[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  let version = digits(fields[2]).flatMap({ Int(exactly: $0) })
            else { return nil }
            return .banner(id: String(fields[1]), version: version)
        case "D", "U", "H":
            guard fields.count == 2, let ms = digits(fields[1]) else { return nil }
            switch kind {
            case "D": return .keyDown(deviceMs: ms)
            case "U": return .keyUp(deviceMs: ms)
            default: return .heartbeat(deviceMs: ms)
            }
        case "S":
            guard fields.count == 6,
                  let wpm = digits(fields[1]), (1...99).contains(wpm),
                  fields[2] == "A" || fields[2] == "B",
                  let reversed = flag(fields[3]),
                  let sidetone = flag(fields[4]),
                  let ms = digits(fields[5])
            else { return nil }
            return .status(CWKeyDeviceStatus(
                wpm: Int(wpm), iambicModeB: fields[2] == "B",
                paddleReversed: reversed, sidetoneOn: sidetone, deviceMs: ms))
        default:
            return nil
        }
    }

    /// 1-10 ASCII digits fitting a UInt32 — no sign, space or hex.
    private static func digits(_ field: Substring) -> UInt32? {
        guard (1...10).contains(field.count), field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt32(field)
    }

    private static func flag(_ field: Substring) -> Bool? {
        switch field {
        case "0": false
        case "1": true
        default: nil
        }
    }
}

/// Splits the serial byte stream into `CWKeyLine`s. Bytes arrive in
/// arbitrary chunks, so a partial line is kept until its newline. "\r\n"
/// and "\n" both end a line (Arduino's `println` sends "\r\n"). A line
/// longer than `maxLineLength` is garbage (e.g. noise at the wrong baud
/// rate) and is dropped up to the next newline instead of growing forever.
public struct CWKeyLineAssembler: Sendable {
    public static let maxLineLength = 64

    private var buffer: [UInt8] = []
    private var discarding = false
    /// Lines skipped as unparseable or overlong, for the log.
    public private(set) var rejectedLineCount = 0

    public init() {}

    /// Feeds bytes; returns the complete lines they finished, in order.
    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [CWKeyLine] where Bytes.Element == UInt8 {
        var lines: [CWKeyLine] = []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                if discarding {
                    discarding = false
                    rejectedLineCount += 1
                } else if !buffer.isEmpty {
                    if let text = String(bytes: buffer, encoding: .ascii),
                       let line = CWKeyLine.parse(Substring(text)) {
                        lines.append(line)
                    } else {
                        rejectedLineCount += 1
                    }
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            guard !discarding else { continue }
            if buffer.count >= Self.maxLineLength {
                buffer.removeAll(keepingCapacity: true)
                discarding = true
                continue
            }
            buffer.append(byte)
        }
        return lines
    }

    /// Drops a partial line — on reopening the port, where the bytes before
    /// it belong to a different session.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        discarding = false
    }
}

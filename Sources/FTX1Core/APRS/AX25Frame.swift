import Foundation

/// One address field in an AX.25 frame — a 6-character callsign (space-
/// padded in the wire format, trimmed here) plus SSID, and whether this is
/// the last address in the address field (destination, source, then 0-8
/// digipeaters).
public struct AX25Address: Equatable, Sendable {
    public let callsign: String
    public let ssid: Int
    public let isLast: Bool

    public init(callsign: String, ssid: Int, isLast: Bool) {
        self.callsign = callsign
        self.ssid = ssid
        self.isLast = isLast
    }

    /// Callsign with SSID suffix when non-zero (e.g. "N0CALL-9"), matching
    /// how APRS clients conventionally display a station identity.
    public var displayString: String {
        ssid == 0 ? callsign : "\(callsign)-\(ssid)"
    }
}

/// A parsed AX.25 UI frame (the only frame type APRS uses) — address
/// field, control/PID bytes, and the info field APRS payload parsing
/// (`APRSPacket`) operates on.
public struct AX25Frame: Equatable, Sendable {
    public let destination: AX25Address
    public let source: AX25Address
    public let digipeaters: [AX25Address]
    public let control: UInt8
    public let pid: UInt8
    public let info: [UInt8]

    /// Parses everything except the leading flag and trailing FCS — the
    /// caller (`AX25FrameDecoder`) already stripped those and verified the
    /// FCS before calling this.
    static func parse(bytes: [UInt8]) -> AX25Frame? {
        guard bytes.count >= 16 else { return nil }
        guard let destination = parseAddress(bytes, at: 0), !destination.isLast else { return nil }
        guard let source = parseAddress(bytes, at: 7) else { return nil }

        var digipeaters: [AX25Address] = []
        var offset = 14
        var last = source.isLast
        while !last {
            guard digipeaters.count < 8, let digi = parseAddress(bytes, at: offset) else { return nil }
            digipeaters.append(digi)
            last = digi.isLast
            offset += 7
        }

        guard bytes.count >= offset + 2 else { return nil }
        let control = bytes[offset]
        let pid = bytes[offset + 1]
        let info = Array(bytes[(offset + 2)...])
        return AX25Frame(destination: destination, source: source, digipeaters: digipeaters, control: control, pid: pid, info: info)
    }

    /// Each address is 7 bytes: 6 callsign characters, each ASCII value
    /// shifted left 1 bit, followed by an SSID byte (`0SSSSRRE` — SSID in
    /// bits 1-4, the low bit is the end-of-address-field marker).
    private static func parseAddress(_ bytes: [UInt8], at offset: Int) -> AX25Address? {
        guard bytes.count >= offset + 7 else { return nil }
        var callsign = ""
        for i in 0..<6 {
            let scalar = bytes[offset + i] >> 1
            callsign.append(Character(Unicode.Scalar(scalar)))
        }
        callsign = callsign.trimmingCharacters(in: .whitespaces)
        let ssidByte = bytes[offset + 6]
        let ssid = Int((ssidByte >> 1) & 0x0F)
        let isLast = (ssidByte & 0x01) != 0
        return AX25Address(callsign: callsign, ssid: ssid, isLast: isLast)
    }
}

/// Standard AX.25 frame check sequence — CRC-16/X-25 (poly 0x1021
/// reflected to 0x8408, init 0xFFFF, result complemented, LSB-first bit
/// order per byte). Verified against the well-known catalog check value
/// for this algorithm in `APRSDecodingTests` (CRC of ASCII "123456789" ==
/// 0x906E), independent of this codebase's own encode/decode round trip.
enum AX25FCS {
    static func compute(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0x8408
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF
    }
}

/// Recovers AX.25 frames from a stream of NRZI-decoded line bits (i.e.
/// `AFSKDemodulator`'s output — flags and bit-stuffed data, not yet
/// destuffed). Stateful and incremental: audio arrives in arbitrary-sized
/// chunks from `AudioCaptureEngine`'s tap, not one frame at a time, so
/// this buffers bits across calls to `process(bits:)` and only emits a
/// frame once both its opening and closing flag have been seen.
///
/// Two-pass per call rather than a single-pass streaming state machine:
/// flag boundaries are found first by scanning for the fixed 8-bit
/// pattern `01111110` in the raw bit buffer, then each isolated
/// inter-flag segment is bit-destuffed and parsed independently. This is
/// simpler to get right than interleaving flag detection with destuffing
/// in one pass (the flag pattern's six 1-bits would otherwise have to be
/// "un-appended" from a data accumulator after the fact), and APRS frames
/// are short enough (well under a second of audio) that buffering the
/// whole thing costs nothing.
public struct AX25FrameDecoder {
    /// Where a flag-delimited segment fell out of the pipeline — lets a
    /// caller (or a diagnostic harness, see `APRSDecoder`'s heartbeat log)
    /// tell "no signal is reaching this at all" apart from "signal is
    /// reaching it but every frame is corrupt," which point at completely
    /// different problems (upstream tone detection/bit sync vs. timing
    /// precision within an already-synced segment).
    private enum SegmentResult {
        case frame(AX25Frame)
        case destuffFailed
        case tooShort
        case crcFailed
        case addressParseFailed
    }

    /// Cumulative counts since this decoder was created — see
    /// `SegmentResult`. Read after `process(bits:)`; `flagsFound` divided
    /// by two is roughly "segments attempted" (each segment needs an
    /// opening and closing flag, and consecutive frames share one).
    public struct Stats: Sendable {
        public internal(set) var flagsFound = 0
        public internal(set) var destuffFailures = 0
        public internal(set) var tooShortFailures = 0
        public internal(set) var crcFailures = 0
        public internal(set) var addressParseFailures = 0
        public internal(set) var framesDecoded = 0
    }

    /// Bounds how much unsynced audio (no flag found yet) accumulates —
    /// well past the longest realistic APRS frame, just a safety valve
    /// against unbounded growth on a noisy/silent channel.
    private static let maxUnsyncedBits = 4096

    private var bits: [Bool] = []
    public private(set) var stats = Stats()

    public init() {}

    /// Feeds NRZI-decoded line bits and returns any complete, CRC-valid
    /// AX.25 frames found since the last call.
    public mutating func process(bits newBits: [Bool]) -> [AX25Frame] {
        bits.append(contentsOf: newBits)

        var flagStarts: [Int] = []
        var window = 0
        for i in 0..<bits.count {
            window = ((window << 1) | (bits[i] ? 1 : 0)) & 0xFF
            if i >= 7, window == 0b0111_1110 {
                flagStarts.append(i - 7)
            }
        }
        stats.flagsFound += flagStarts.count

        guard flagStarts.count >= 2 else {
            if bits.count > Self.maxUnsyncedBits {
                bits.removeFirst(bits.count - Self.maxUnsyncedBits)
            }
            return []
        }

        var frames: [AX25Frame] = []
        for i in 0..<(flagStarts.count - 1) {
            let segmentStart = flagStarts[i] + 8
            let segmentEnd = flagStarts[i + 1]
            guard segmentEnd > segmentStart else { continue }
            switch Self.decodeSegment(Array(bits[segmentStart..<segmentEnd])) {
            case .frame(let frame):
                stats.framesDecoded += 1
                frames.append(frame)
            case .destuffFailed:
                stats.destuffFailures += 1
            case .tooShort:
                stats.tooShortFailures += 1
            case .crcFailed:
                stats.crcFailures += 1
            case .addressParseFailed:
                stats.addressParseFailures += 1
            }
        }

        // Keep bits from the last found flag onward — a frame may still
        // be arriving after it in a future chunk.
        let lastFlagStart = flagStarts[flagStarts.count - 1]
        bits.removeFirst(lastFlagStart)

        return frames
    }

    private static func decodeSegment(_ segmentBits: [Bool]) -> SegmentResult {
        guard let destuffed = destuff(segmentBits) else { return .destuffFailed }
        guard let bytes = bitsToBytes(destuffed), bytes.count >= 18 else { return .tooShort }

        let payload = Array(bytes[0..<(bytes.count - 2)])
        let receivedFCS = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        guard AX25FCS.compute(payload) == receivedFCS else { return .crcFailed }

        guard let frame = AX25Frame.parse(bytes: payload) else { return .addressParseFailed }
        return .frame(frame)
    }

    /// Removes bits inserted by the transmitter after every run of five
    /// consecutive 1-bits (the standard HDLC bit-stuffing rule, applied
    /// to prevent the flag pattern's six 1-bits from occurring in data).
    /// A run of six or more 1-bits within an already flag-delimited
    /// segment means either a bit error or a mis-synced segment — treated
    /// as corrupt rather than force-fit into a frame.
    private static func destuff(_ segmentBits: [Bool]) -> [Bool]? {
        var result: [Bool] = []
        result.reserveCapacity(segmentBits.count)
        var onesCount = 0
        for bit in segmentBits {
            if bit {
                onesCount += 1
                if onesCount > 5 { return nil }
                result.append(true)
            } else {
                if onesCount == 5 {
                    // Stuffed bit — discard.
                } else {
                    result.append(false)
                }
                onesCount = 0
            }
        }
        return result
    }

    /// AX.25 transmits each byte least-significant-bit first.
    private static func bitsToBytes(_ bits: [Bool]) -> [UInt8]? {
        guard !bits.isEmpty, bits.count % 8 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(bits.count / 8)
        var i = 0
        while i < bits.count {
            var byte: UInt8 = 0
            for b in 0..<8 where bits[i + b] {
                byte |= (1 << b)
            }
            bytes.append(byte)
            i += 8
        }
        return bytes
    }
}

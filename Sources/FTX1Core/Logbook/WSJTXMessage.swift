import Foundation

/// Encodes the WSJT-X UDP messages a logbook listens for — the protocol
/// MacLoggerDX (and most Mac/Windows loggers) accept QSOs over. Layout from
/// WSJT-X's own `Network/NetworkMessage.hpp`: big-endian, header = magic
/// 0xadbccbda + schema, then the message type and the sender's Id, then
/// fields in QDataStream (Qt 5.4) form — `utf8` is a quint32 byte count +
/// bytes, `QDateTime` is a qint64 Julian day + quint32 ms since midnight +
/// a quint8 timespec (1 = UTC).
///
/// A QSO goes out the way WSJT-X sends one: "QSO Logged" and "Logged
/// ADIF" together, and the listener acts on whichever it's set up for
/// (MacLoggerDX: one or the other, by its "log ADIF" checkbox).
///
/// No Heartbeat is sent with it: MacLoggerDX 6.62 crashed (an uncaught
/// `substringWithRange:` exception in `-[WsjtDecoder messageHeartBeat:]`)
/// on a Heartbeat with an empty version string, 2026-10-07. `heartbeat`
/// is kept for a listener that needs one; give it a real version.
public enum WSJTXMessage {
    public static let magic: UInt32 = 0xadbc_cbda
    public static let schema: UInt32 = 3
    /// The Id every message carries: which client sent it. MacLoggerDX
    /// checks it against "WSJT-X"/"JTDX" (strings in its binary); this is
    /// the form a second, named WSJT-X instance uses, so it doesn't pose
    /// as the operator's own WSJT-X.
    public static let defaultID = "WSJT-X - FTX1Remote"

    enum MessageType: UInt32 {
        case heartbeat = 0
        case status = 1
        case qsoLogged = 5
        case loggedADIF = 12
    }

    public static func heartbeat(id: String = defaultID, version: String = "", revision: String = "") -> Data {
        var writer = Writer(type: .heartbeat, id: id)
        writer.uint32(schema)
        writer.utf8(version)
        writer.utf8(revision)
        return writer.data
    }

    /// What WSJT-X sends whenever its DX Call (or dial frequency, mode…)
    /// changes — MacLoggerDX looks up the DX call from it. The decode/TX
    /// fields are what an idle WSJT-X reports; 0xffffffff is "not
    /// applicable" for the tolerance and T/R period.
    public static func status(
        dialFrequencyHz: Int,
        mode: String,
        dxCall: String,
        deCall: String = "",
        deGrid: String = "",
        id: String = defaultID
    ) -> Data {
        var writer = Writer(type: .status, id: id)
        writer.uint64(UInt64(max(dialFrequencyHz, 0)))
        writer.utf8(mode)
        writer.utf8(dxCall)
        writer.utf8("")           // report
        writer.utf8(mode)         // TX mode
        writer.bool(false)        // TX enabled
        writer.bool(false)        // transmitting
        writer.bool(false)        // decoding
        writer.uint32(0)          // RX DF
        writer.uint32(0)          // TX DF
        writer.utf8(deCall)
        writer.utf8(deGrid)
        writer.utf8("")           // DX grid
        writer.bool(false)        // TX watchdog
        writer.utf8("")           // sub-mode
        writer.bool(false)        // fast mode
        writer.uint8(0)           // special operation mode: none
        writer.uint32(.max)       // frequency tolerance
        writer.uint32(.max)       // T/R period
        writer.utf8("")           // configuration name
        writer.utf8("")           // TX message
        return writer.data
    }

    public static func qsoLogged(_ qso: LoggedQSO, id: String = defaultID) -> Data {
        var writer = Writer(type: .qsoLogged, id: id)
        writer.dateTime(qso.end)
        writer.utf8(qso.call)
        writer.utf8(qso.grid)
        writer.uint64(UInt64(max(qso.frequencyHz, 0)))
        writer.utf8(qso.mode)
        writer.utf8(qso.rstSent)
        writer.utf8(qso.rstReceived)
        writer.utf8(qso.txPower)
        writer.utf8(qso.comments)
        writer.utf8(qso.name)
        writer.dateTime(qso.start)
        writer.utf8(qso.myCall)   // operator call
        writer.utf8(qso.myCall)
        writer.utf8(qso.myGrid)
        writer.utf8("")           // exchange sent
        writer.utf8("")           // exchange received
        writer.utf8("")           // ADIF propagation mode
        return writer.data
    }

    public static func loggedADIF(_ qso: LoggedQSO, id: String = defaultID) -> Data {
        var writer = Writer(type: .loggedADIF, id: id)
        writer.utf8(ADIFRecord.file(for: qso))
        return writer.data
    }

    /// Julian day number of 1970-01-01, QDate's epoch offset.
    static let unixEpochJulianDay: Int64 = 2_440_588

    struct Writer {
        private(set) var data = Data()

        init(type: MessageType, id: String) {
            uint32(WSJTXMessage.magic)
            uint32(WSJTXMessage.schema)
            uint32(type.rawValue)
            utf8(id)
        }

        mutating func uint8(_ value: UInt8) { data.append(value) }
        mutating func bool(_ value: Bool) { uint8(value ? 1 : 0) }
        mutating func uint32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        mutating func int64(_ value: Int64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        mutating func uint64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }

        mutating func utf8(_ string: String) {
            let bytes = Array(string.utf8)
            uint32(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }

        /// QDateTime in UTC (timespec 1), to the millisecond.
        mutating func dateTime(_ date: Date) {
            let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
            let msPerDay: Int64 = 86_400_000
            let day = ms >= 0 ? ms / msPerDay : (ms - msPerDay + 1) / msPerDay
            int64(day + WSJTXMessage.unixEpochJulianDay)
            uint32(UInt32(ms - day * msPerDay))
            uint8(1)
        }
    }
}

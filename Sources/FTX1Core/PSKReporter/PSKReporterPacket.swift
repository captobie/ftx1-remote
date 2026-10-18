import Foundation

/// Encodes PSK Reporter's reception-report datagrams: a simplified IPFIX
/// (RFC 5101) over UDP to `report.pskreporter.info:4739`, laid out as in
/// the "Cookie Cutter" section of https://pskreporter.info/pskdev.html
/// (read 2026-10-18). Big-endian throughout.
///
/// A datagram is the header, optionally the two record format descriptors
/// (templates — the server caches them per source address/port, so they're
/// only needed in the first few datagrams and then hourly), then the one
/// receiver record (us) and a block of sender records (the stations heard).
/// Strings are a 1-byte length + ASCII, at most 254 bytes; each set is
/// null-padded to a multiple of 4.
///
/// No SNR is sent (user decision, 2026-10-18): this app's FT8 "SNR" is
/// ft8_lib's sync score × 0.5, not a calibrated noise-floor SNR.
public enum PSKReporterPacket {
    public static let host = "report.pskreporter.info"
    public static let port: UInt16 = 4739
    /// The doc warns that a datagram much over the path MTU gets lost.
    public static let defaultMaxBytes = 1400

    static let receiverTemplateID: UInt16 = 0x9992
    static let senderTemplateID: UInt16 = 0x9993

    public struct Receiver: Equatable, Sendable {
        public var callsign: String
        public var locator: String
        public var software: String

        public init(callsign: String, locator: String, software: String) {
            self.callsign = callsign
            self.locator = locator
            self.software = software
        }
    }

    public struct Report: Equatable, Sendable {
        public var callsign: String
        public var frequencyHz: UInt32
        /// An ADIF MODE/SUBMODE value, e.g. "FT8".
        public var mode: String
        /// The sender's grid when the message carried one; `nil` is sent as
        /// an empty string (only used by `.withLocator`).
        public var locator: String?
        public var time: Date

        public init(callsign: String, frequencyHz: UInt32, mode: String, locator: String?, time: Date) {
            self.callsign = callsign
            self.frequencyHz = frequencyHz
            self.mode = mode
            self.locator = locator
            self.time = time
        }
    }

    /// The doc's two SNR-less sender descriptors. The app uses
    /// `.withLocator`; `.basic` exists so the doc's own example datagram
    /// can be checked byte for byte.
    public enum SenderTemplate: Sendable {
        /// senderCallsign, frequency, mode, informationSource, flowStartSeconds.
        case basic
        /// The same plus senderLocator (before flowStartSeconds).
        case withLocator

        var descriptor: [UInt8] {
            switch self {
            case .basic:
                return [
                    0x00, 0x02, 0x00, 0x2C, 0x99, 0x93, 0x00, 0x05,
                    0x80, 0x01, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
                    0x80, 0x05, 0x00, 0x04, 0x00, 0x00, 0x76, 0x8F,
                    0x80, 0x0A, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
                    0x80, 0x0B, 0x00, 0x01, 0x00, 0x00, 0x76, 0x8F,
                    0x00, 0x96, 0x00, 0x04,
                ]
            case .withLocator:
                return [
                    0x00, 0x02, 0x00, 0x34, 0x99, 0x93, 0x00, 0x06,
                    0x80, 0x01, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
                    0x80, 0x05, 0x00, 0x04, 0x00, 0x00, 0x76, 0x8F,
                    0x80, 0x0A, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
                    0x80, 0x0B, 0x00, 0x01, 0x00, 0x00, 0x76, 0x8F,
                    0x80, 0x03, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
                    0x00, 0x96, 0x00, 0x04,
                ]
            }
        }
    }

    /// receiverCallsign, receiverLocator, decodingSoftware.
    static let receiverDescriptor: [UInt8] = [
        0x00, 0x03, 0x00, 0x24, 0x99, 0x92, 0x00, 0x03, 0x00, 0x01,
        0x80, 0x02, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
        0x80, 0x04, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
        0x80, 0x08, 0xFF, 0xFF, 0x00, 0x00, 0x76, 0x8F,
        0x00, 0x00,
    ]

    /// 1 = automatically extracted; the server ignores records without it.
    static let informationSourceAutomatic: UInt8 = 1

    public struct Datagram: Equatable, Sendable {
        public let data: Data
        /// How many of the reports went into this datagram, in order.
        public let reportCount: Int
    }

    /// Packs `reports` into as many datagrams as needed, each at most
    /// `maxBytes`. The header's sequence number is the count of reports
    /// sent before that datagram (the doc: "the count of reports and not
    /// the count of packets"), starting at `sequence`. Templates go into
    /// every datagram of this call when `includeTemplates` is set.
    public static func encode(
        receiver: Receiver,
        reports: [Report],
        template: SenderTemplate = .withLocator,
        includeTemplates: Bool,
        sequence: UInt32,
        domainID: UInt32,
        exportTime: Date,
        maxBytes: Int = defaultMaxBytes
    ) -> [Datagram] {
        let receiverSet = receiverRecord(receiver)
        let fixed = 16
            + (includeTemplates ? receiverDescriptor.count + template.descriptor.count : 0)
            + receiverSet.count
            + 4 + 3  // sender set header + worst-case padding

        var datagrams: [Datagram] = []
        var nextSequence = sequence
        var index = 0
        while index < reports.count {
            var records: [UInt8] = []
            var count = 0
            while index + count < reports.count {
                let record = senderRecord(reports[index + count], template: template)
                if count > 0 && fixed + records.count + record.count > maxBytes { break }
                records += record
                count += 1
            }

            var body: [UInt8] = []
            if includeTemplates {
                body += receiverDescriptor
                body += template.descriptor
            }
            body += receiverSet
            body += set(id: senderTemplateID, content: records)

            var data: [UInt8] = []
            append16(0x000A, to: &data)
            append16(UInt16(clamping: 16 + body.count), to: &data)
            append32(UInt32(clamping: Int64(exportTime.timeIntervalSince1970)), to: &data)
            append32(nextSequence, to: &data)
            append32(domainID, to: &data)
            data += body

            datagrams.append(Datagram(data: Data(data), reportCount: count))
            nextSequence &+= UInt32(count)
            index += count
        }
        return datagrams
    }

    static func receiverRecord(_ receiver: Receiver) -> [UInt8] {
        var content: [UInt8] = []
        appendString(receiver.callsign, to: &content)
        appendString(receiver.locator, to: &content)
        appendString(receiver.software, to: &content)
        return set(id: receiverTemplateID, content: content)
    }

    static func senderRecord(_ report: Report, template: SenderTemplate) -> [UInt8] {
        var bytes: [UInt8] = []
        appendString(report.callsign, to: &bytes)
        append32(report.frequencyHz, to: &bytes)
        appendString(report.mode, to: &bytes)
        bytes.append(informationSourceAutomatic)
        if template == .withLocator {
            appendString(report.locator ?? "", to: &bytes)
        }
        append32(UInt32(clamping: Int64(report.time.timeIntervalSince1970)), to: &bytes)
        return bytes
    }

    /// A set: its ID (the template it follows), its length including this
    /// header and the padding, then the content null-padded to 4 bytes.
    private static func set(id: UInt16, content: [UInt8]) -> [UInt8] {
        let padding = (4 - (4 + content.count) % 4) % 4
        var bytes: [UInt8] = []
        append16(id, to: &bytes)
        append16(UInt16(clamping: 4 + content.count + padding), to: &bytes)
        bytes += content
        bytes += [UInt8](repeating: 0, count: padding)
        return bytes
    }

    /// Non-ASCII is replaced with "?" (callsigns and grids are ASCII; the
    /// doc allows UTF-8 but truncating that at 254 bytes could split a
    /// character).
    private static func appendString(_ string: String, to bytes: inout [UInt8]) {
        let ascii = string.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }
        let clipped = ascii.prefix(254)
        bytes.append(UInt8(clipped.count))
        bytes += clipped
    }

    private static func append16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes += [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

import Foundation

/// A parsed APRS info-field payload — dispatched on the data type
/// identifier byte per the APRS spec. Covers position reports, status
/// reports, and messages, which is what's needed to populate the app's
/// S.LIST/M.LIST windows; anything else (objects, weather, telemetry,
/// Mic-E compressed position, third-party packets) falls into `.other`
/// rather than being fully parsed — deliberately out of scope for now,
/// not a gap to silently paper over.
public enum APRSPacket: Equatable, Sendable {
    case position(latitude: Double, longitude: Double, symbolTable: String, symbolCode: String, comment: String)
    case status(text: String)
    case message(to: String, text: String, messageID: String?)
    case other(raw: [UInt8])

    public static func parse(infoField: [UInt8]) -> APRSPacket {
        guard let first = infoField.first else { return .other(raw: infoField) }
        let rest = Array(infoField.dropFirst())
        switch UnicodeScalar(first) {
        case "!", "=":
            return parsePosition(rest, hasTimestamp: false) ?? .other(raw: infoField)
        case "/", "@":
            return parsePosition(rest, hasTimestamp: true) ?? .other(raw: infoField)
        case ">":
            return .status(text: String(decoding: rest, as: UTF8.self))
        case ":":
            return parseMessage(rest) ?? .other(raw: infoField)
        default:
            return .other(raw: infoField)
        }
    }

    /// Uncompressed position format only: `ddmm.mmN/dddmm.mmW<symbol><comment>`,
    /// optionally preceded by a 7-byte timestamp for `/`/`@`. Compressed
    /// and Mic-E position formats aren't handled — see the type's doc
    /// comment.
    private static func parsePosition(_ bytes: [UInt8], hasTimestamp: Bool) -> APRSPacket? {
        var bytes = bytes
        if hasTimestamp {
            guard bytes.count > 7 else { return nil }
            bytes.removeFirst(7)
        }
        guard bytes.count >= 19 else { return nil }

        let latString = String(decoding: bytes[0..<8], as: UTF8.self)
        let symbolTable = String(decoding: [bytes[8]], as: UTF8.self)
        let lonString = String(decoding: bytes[9..<18], as: UTF8.self)
        let symbolCode = String(decoding: [bytes[18]], as: UTF8.self)
        let comment = bytes.count > 19 ? String(decoding: bytes[19...], as: UTF8.self) : ""

        guard let latitude = parseLatitude(latString), let longitude = parseLongitude(lonString) else { return nil }
        return .position(latitude: latitude, longitude: longitude, symbolTable: symbolTable, symbolCode: symbolCode, comment: comment)
    }

    /// `ddmm.mmH` — 2-digit degrees, 2-digit minutes, '.', 2-digit
    /// hundredths of a minute, hemisphere (N/S).
    private static func parseLatitude(_ string: String) -> Double? {
        guard string.count == 8 else { return nil }
        let chars = Array(string)
        guard let degrees = Double(String(chars[0...1])), let minutes = Double(String(chars[2...6])) else { return nil }
        let hemisphere = chars[7]
        guard hemisphere == "N" || hemisphere == "S" else { return nil }
        let value = degrees + minutes / 60.0
        return hemisphere == "S" ? -value : value
    }

    /// `dddmm.mmH` — 3-digit degrees, otherwise identical to latitude.
    private static func parseLongitude(_ string: String) -> Double? {
        guard string.count == 9 else { return nil }
        let chars = Array(string)
        guard let degrees = Double(String(chars[0...2])), let minutes = Double(String(chars[3...7])) else { return nil }
        let hemisphere = chars[8]
        guard hemisphere == "E" || hemisphere == "W" else { return nil }
        let value = degrees + minutes / 60.0
        return hemisphere == "W" ? -value : value
    }

    /// `ADDRESSEE:message text{messageID}` — addressee is a fixed 9-byte,
    /// space-padded field.
    private static func parseMessage(_ bytes: [UInt8]) -> APRSPacket? {
        let string = String(decoding: bytes, as: UTF8.self)
        guard string.count >= 10 else { return nil }
        let addresseeEnd = string.index(string.startIndex, offsetBy: 9)
        guard string[addresseeEnd] == ":" else { return nil }
        let addressee = String(string[string.startIndex..<addresseeEnd]).trimmingCharacters(in: .whitespaces)
        var remainder = String(string[string.index(after: addresseeEnd)...])

        var messageID: String?
        if let braceIndex = remainder.firstIndex(of: "{") {
            messageID = String(remainder[remainder.index(after: braceIndex)...])
            remainder = String(remainder[..<braceIndex])
        }
        return .message(to: addressee, text: remainder, messageID: messageID)
    }
}

import Foundation

/// Info fields this app sends (APRS 1.0.1 / 1.2): an uncompressed position
/// with messaging (`=`), a message, an ack. Plus the parsing of acks and
/// reply-acks in what arrives.
public enum APRSOutgoing {
    /// Longest message text (APRS 1.0.1, chapter 14).
    public static let maxMessageLength = 67
    /// Longest position comment with no data extension.
    public static let maxCommentLength = 43

    /// `=ddmm.hhN/dddmm.hhW-comment` — "=" says this station can take
    /// messages. `ambiguity` 0–4 blanks that many trailing digits of each
    /// coordinate (4 = to the degree), the spec's position ambiguity.
    public static func position(latitude: Double, longitude: Double, symbolTable: Character,
                                symbolCode: Character, comment: String, ambiguity: Int = 0) -> String {
        let lat = coordinate(abs(latitude), degreeDigits: 2, hemisphere: latitude < 0 ? "S" : "N", ambiguity: ambiguity)
        let lon = coordinate(abs(longitude), degreeDigits: 3, hemisphere: longitude < 0 ? "W" : "E", ambiguity: ambiguity)
        return "=" + lat + String(symbolTable) + lon + String(symbolCode) + String(sanitized(comment).prefix(maxCommentLength))
    }

    /// `ddmm.hh` (or `dddmm.hh`) + hemisphere, hundredths of a minute,
    /// rounded; minutes that round to 60 carry into the degrees.
    static func coordinate(_ value: Double, degreeDigits: Int, hemisphere: Character, ambiguity: Int) -> String {
        var hundredths = Int((value * 60 * 100).rounded())
        let maxHundredths = (degreeDigits == 2 ? 90 : 180) * 60 * 100
        hundredths = min(hundredths, maxHundredths)
        let degrees = hundredths / 6000
        let minutes = hundredths % 6000
        var digits = Array(String(format: "%0\(degreeDigits)d%02d.%02d", degrees, minutes / 100, minutes % 100))
        // The last four digits, right to left: hh, then mm (the '.' stays).
        let positions = [digits.count - 1, digits.count - 2, digits.count - 4, digits.count - 5]
        for index in positions.prefix(max(0, min(4, ambiguity))) { digits[index] = " " }
        return String(digits) + String(hemisphere)
    }

    /// `:ADDRESSEE:text{id` — the addressee padded to 9 characters.
    public static func message(to addressee: String, text: String, id: String?) -> String {
        let body = String(sanitized(text, forMessage: true).prefix(maxMessageLength))
        return ":" + paddedAddressee(addressee) + ":" + body + (id.map { "{" + $0 } ?? "")
    }

    /// `:ADDRESSEE:ackid`.
    public static func ack(to addressee: String, id: String) -> String {
        ":" + paddedAddressee(addressee) + ":ack" + id
    }

    static func paddedAddressee(_ addressee: String) -> String {
        let trimmed = String(addressee.uppercased().prefix(9))
        return trimmed.padding(toLength: 9, withPad: " ", startingAt: 0)
    }

    /// Printable ASCII only; in messages also no `|`, `~` or `{` (the
    /// spec reserves them).
    public static func sanitized(_ text: String, forMessage: Bool = false) -> String {
        String(text.unicodeScalars.filter { scalar in
            guard scalar.value >= 0x20, scalar.value < 0x7F else { return false }
            return !forMessage || !"|~{".unicodeScalars.contains(scalar)
        }.map(Character.init))
    }

    /// What an incoming message means for this station's own messages.
    public enum Reply: Equatable, Sendable {
        case ack(id: String)
        case reject(id: String)
    }

    /// "ack12" / "rej12" texts, and the reply-ack in a message id
    /// (`{MM}AA`: their id MM, acking our AA).
    public static func reply(text: String, messageID: String?) -> Reply? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if messageID == nil || messageID?.isEmpty == true {
            let lower = trimmed.lowercased()
            if lower.hasPrefix("ack"), trimmed.count > 3, trimmed.count <= 8 {
                return .ack(id: ackID(String(trimmed.dropFirst(3))))
            }
            if lower.hasPrefix("rej"), trimmed.count > 3, trimmed.count <= 8 {
                return .reject(id: ackID(String(trimmed.dropFirst(3))))
            }
        }
        if let messageID, let brace = messageID.firstIndex(of: "}") {
            let acked = String(messageID[messageID.index(after: brace)...]).trimmingCharacters(in: .whitespaces)
            if !acked.isEmpty { return .ack(id: acked) }
        }
        return nil
    }

    /// An ack's id, without a reply-ack's "}…" tail ("ack01}" → "01").
    private static func ackID(_ text: String) -> String {
        String(text.split(separator: "}", omittingEmptySubsequences: false).first ?? "")
    }

    /// The id to ack for a received message: its own, without the
    /// reply-ack part.
    public static func idToAck(_ messageID: String?) -> String? {
        guard let messageID else { return nil }
        let own = String(messageID.split(separator: "}", omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? nil : String(own.prefix(5))
    }
}

/// Settings → APRS → Transmit. `SettingsStore`-backed like `APRSSettings`.
public enum APRSTransmitSettings {
    public static let enabledKey = "aprs.tx.enabled"
    public static let ssidKey = "aprs.tx.ssid"
    public static let latitudeKey = "aprs.tx.latitude"
    public static let longitudeKey = "aprs.tx.longitude"
    public static let ambiguityKey = "aprs.tx.ambiguity"
    public static let symbolKey = "aprs.tx.symbol"
    public static let commentKey = "aprs.tx.comment"
    public static let pathKey = "aprs.tx.path"
    public static let beaconMinutesKey = "aprs.tx.beaconMinutes"
    public static let autoAckKey = "aprs.tx.autoAck"
    public static let levelDbKey = "aprs.tx.levelDb"
    public static let txDelayMsKey = "aprs.tx.txDelayMs"

    /// The AX.25 destination ("tocall"): APZ = experimental software.
    public static let destination = (callsign: "APZFTX", ssid: 0)
    public static let defaultSymbol = "/-" // house
    public static let defaultPath = "WIDE2-1"
    public static let defaultTxDelayMs = 400
    public static let defaultLevelDb = -6.0
    /// Beacon intervals offered, in minutes (0 = off).
    public static let beaconChoices = [0, 10, 15, 20, 30, 60]
    public static let txDelayRange = 100...1000
    public static let levelRange: ClosedRange<Double> = -30 ... 0

    private static var defaults: UserDefaults { SettingsStore.defaults }

    public static func registerDefaults() {
        defaults.register(defaults: [
            symbolKey: defaultSymbol,
            pathKey: defaultPath,
            autoAckKey: true,
            levelDbKey: defaultLevelDb,
            txDelayMsKey: defaultTxDelayMs,
        ])
    }

    public static var enabled: Bool { defaults.bool(forKey: enabledKey) }
    public static var ssid: Int { min(15, max(0, defaults.integer(forKey: ssidKey))) }
    /// nil until entered.
    public static var latitude: Double? { defaults.object(forKey: latitudeKey) as? Double }
    public static var longitude: Double? { defaults.object(forKey: longitudeKey) as? Double }
    public static var ambiguity: Int { min(4, max(0, defaults.integer(forKey: ambiguityKey))) }
    public static var symbol: String { defaults.string(forKey: symbolKey) ?? defaultSymbol }
    public static var comment: String { defaults.string(forKey: commentKey) ?? "" }
    public static var path: String { defaults.string(forKey: pathKey) ?? defaultPath }
    public static var beaconMinutes: Int { max(0, defaults.integer(forKey: beaconMinutesKey)) }
    public static var autoAck: Bool { defaults.object(forKey: autoAckKey) as? Bool ?? true }
    public static var levelDb: Double {
        let value = defaults.object(forKey: levelDbKey) as? Double ?? defaultLevelDb
        return min(levelRange.upperBound, max(levelRange.lowerBound, value))
    }
    public static var txDelayMs: Int {
        let value = defaults.object(forKey: txDelayMsKey) as? Int ?? defaultTxDelayMs
        return min(txDelayRange.upperBound, max(txDelayRange.lowerBound, value))
    }

    /// The station's own call with SSID ("N0CALL-5"), nil while
    /// Settings → Station has no valid callsign.
    public static var sourceCall: String? {
        let call = StationSettings.callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard let parsed = AX25Encoder.address(call), parsed.ssid == 0, !call.contains("-") else { return nil }
        return ssid == 0 ? parsed.callsign : "\(parsed.callsign)-\(ssid)"
    }
}

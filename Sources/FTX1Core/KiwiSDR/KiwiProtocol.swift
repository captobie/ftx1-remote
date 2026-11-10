import Foundation

/// The KiwiSDR's sound-stream protocol (`ws://<host>/<timestamp>/SND`), as
/// spoken by its own page (`web/openwebrx/openwebrx.js`, `audio.js`) and
/// `jks-prv/kiwiclient` (`kiwi/client.py`), checked live against a KiwiSDR 2
/// on v1.902 (2026-11-10, fixtures in `Tests/KiwiSDRFixtures/`).
///
/// Everything the server sends is a binary frame opening with a 3-byte tag:
/// "MSG" (one byte, then space-separated `key=value` pairs, values
/// URL-encoded) or "SND" (audio). The client sends text "SET …" commands.
/// Pure parsing and command building — no networking (`KiwiSDRClient`).
public enum KiwiProtocol {
    // MARK: - Server frames

    public enum Frame: Equatable, Sendable {
        case message([KiwiMessageItem])
        case sound(KiwiSoundFrame)
        /// Another tag (e.g. "W/F" if a waterfall stream were open).
        case other(tag: String)
    }

    /// Parses one binary WebSocket frame. nil if it's too short to carry a tag.
    public static func parseFrame(_ data: Data) -> Frame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return nil }
        let tag = String(decoding: bytes[0..<3], as: UTF8.self)
        switch tag {
        case "MSG":
            // Byte 3 is a separator/flag byte the page skips too.
            let text = bytes.count > 4 ? String(decoding: bytes[4...], as: UTF8.self) : ""
            return .message(parseMessage(text))
        case "SND":
            guard let sound = KiwiSoundFrame(bytes: bytes) else { return .other(tag: tag) }
            return .sound(sound)
        default:
            return .other(tag: tag)
        }
    }

    /// "a=1 b c=%20x" → [(a, "1"), (b, nil), (c, " x")]. Values are
    /// percent-decoded; a key without "=" has a nil value.
    public static func parseMessage(_ text: String) -> [KiwiMessageItem] {
        text.split(separator: " ", omittingEmptySubsequences: true).map { pair in
            guard let eq = pair.firstIndex(of: "=") else {
                return KiwiMessageItem(name: String(pair), value: nil)
            }
            let name = String(pair[..<eq])
            let raw = String(pair[pair.index(after: eq)...])
            return KiwiMessageItem(name: name, value: raw.removingPercentEncoding ?? raw)
        }
    }

    // MARK: - Client commands

    /// "SET auth t=kiwi p=<password>", the password percent-encoded so a
    /// space or "&" can't split the command.
    public static func auth(password: String) -> String {
        "SET auth t=kiwi p=\(percentEncode(password))"
    }

    public static func audioRateOK(inRate: Int, outRate: Int = 44100) -> String {
        "SET AR OK in=\(inRate) out=\(outRate)"
    }

    /// Sent once `sample_rate` arrives, in this order (kiwiclient's
    /// sequence; `tune` follows).
    public static func setupCommands(identUser: String, compression: Bool) -> [String] {
        [
            "SET squelch=0 max=0",
            "SET genattn=0",
            "SET gen=0 mix=-1",
            "SET agc=1 hang=0 thresh=-100 slope=6 decay=1000 manGain=50",
            "SET compression=\(compression ? 1 : 0)",
            "SET ident_user=\(percentEncode(identUser))",
        ]
    }

    /// "SET mod=usb low_cut=300 high_cut=2700 freq=14074.000". `carrierHz` is
    /// what the Kiwi calls freq_car — see `KiwiSDRMode.carrierHz`.
    public static func tune(carrierHz: Int, mode: KiwiSDRMode, lowCut: Int, highCut: Int) -> String {
        let kHz = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(carrierHz) / 1000)
        return "SET mod=\(mode.kiwiToken) low_cut=\(lowCut) high_cut=\(highCut) freq=\(kHz)"
    }

    public static let keepalive = "SET keepalive"

    private static func percentEncode(_ text: String) -> String {
        // Unreserved characters only, like JavaScript's encodeURIComponent.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The `/<timestamp>/SND` URL for `hostPort` ("host" or "host:port";
    /// port 8073 when absent). nil if it can't form a URL.
    public static func soundURL(hostPort: String, timestamp: Date = Date()) -> URL? {
        var text = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://", "ws://", "wss://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, !text.contains("/"), !text.contains(" ") else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        // "host:port" only; a bracketed or bare IPv6 address isn't supported.
        guard !text.hasPrefix("["), text.filter({ $0 == ":" }).count <= 1 else { return nil }
        if let colon = text.firstIndex(of: ":") {
            components.host = String(text[..<colon])
            guard let port = Int(text[text.index(after: colon)...]), (1...65535).contains(port) else { return nil }
            components.port = port
        } else {
            components.host = text
            components.port = 8073
        }
        guard let host = components.host, !host.isEmpty else { return nil }
        components.path = "/\(Int(timestamp.timeIntervalSince1970))/SND"
        return components.url
    }
}

public struct KiwiMessageItem: Equatable, Sendable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// One "SND" frame: flags, sequence, S-meter, then the samples' bytes.
public struct KiwiSoundFrame: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let lowPassFilter = Flags(rawValue: 0x01)
        public static let adcOverflow = Flags(rawValue: 0x02)
        /// The first frame after a retune ("SET mod=…") took effect.
        public static let newFrequency = Flags(rawValue: 0x04)
        public static let stereo = Flags(rawValue: 0x08)
        public static let compressed = Flags(rawValue: 0x10)
        public static let restart = Flags(rawValue: 0x20)
        public static let littleEndian = Flags(rawValue: 0x80)
    }

    public let flags: Flags
    public let sequence: UInt32
    /// The raw S-meter word; `smeterDBm` converts it.
    public let smeterRaw: UInt16
    /// The sample bytes after the 10-byte header ("SND" + 7).
    public let payload: Data

    public var smeterDBm: Double { 0.1 * Double(smeterRaw) - 127 }

    init?(bytes: [UInt8]) {
        guard bytes.count >= 10 else { return nil }
        flags = Flags(rawValue: bytes[3])
        sequence = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        smeterRaw = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        payload = Data(bytes[10...])
    }

    /// Uncompressed mono samples: Int16, big-endian unless the frame says
    /// little-endian. Empty for compressed or stereo frames.
    public func pcmSamples() -> [Int16] {
        guard !flags.contains(.compressed), !flags.contains(.stereo) else { return [] }
        let little = flags.contains(.littleEndian)
        return payload.withUnsafeBytes { raw -> [Int16] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count / 2
            var samples = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let a = UInt16(bytes[2 * i]), b = UInt16(bytes[2 * i + 1])
                samples[i] = Int16(bitPattern: little ? (a | b << 8) : (a << 8 | b))
            }
            return samples
        }
    }
}

/// IMA ADPCM as the Kiwi encodes it ("SET compression=1"): two samples per
/// byte, low nibble first, the step index and previous sample carried
/// across frames — reset only when a connection starts or the compression
/// flag changes (`audio.js`). A port of kiwiclient's `ImaAdpcmDecoder`.
public struct KiwiADPCMDecoder: Sendable {
    private static let stepSizes: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34,
        37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494,
        544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552,
        1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexAdjust: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    private(set) var index = 0
    private(set) var previous: Int32 = 0

    public init() {}

    public mutating func reset() {
        index = 0
        previous = 0
    }

    public mutating func decode(_ data: Data) -> [Int16] {
        var samples = [Int16]()
        samples.reserveCapacity(data.count * 2)
        for byte in data {
            samples.append(decodeNibble(byte & 0x0F))
            samples.append(decodeNibble(byte >> 4))
        }
        return samples
    }

    private mutating func decodeNibble(_ code: UInt8) -> Int16 {
        let step = Self.stepSizes[index]
        index = min(max(index + Self.indexAdjust[Int(code)], 0), Self.stepSizes.count - 1)
        var difference = step >> 3
        if code & 1 != 0 { difference += step >> 2 }
        if code & 2 != 0 { difference += step >> 1 }
        if code & 4 != 0 { difference += step }
        if code & 8 != 0 { difference = -difference }
        previous = min(max(previous + difference, -32768), 32767)
        return Int16(previous)
    }
}

/// Turns SND frames into samples, uncompressed or ADPCM, keeping the
/// decoder state the way the Kiwi's page does.
public struct KiwiSoundDecoder: Sendable {
    private var adpcm = KiwiADPCMDecoder()
    private var lastCompressed: Bool?

    public init() {}

    public mutating func samples(from frame: KiwiSoundFrame) -> [Int16] {
        guard !frame.flags.contains(.stereo) else { return [] }
        let compressed = frame.flags.contains(.compressed)
        if lastCompressed != compressed {
            adpcm.reset()
            lastCompressed = compressed
        }
        return compressed ? adpcm.decode(frame.payload) : frame.pcmSamples()
    }
}

/// The demodulators the Local SDR window offers, with the Kiwi page's own
/// default passbands (`passbands_fallback` in `openwebrx.js`).
public enum KiwiSDRMode: String, CaseIterable, Codable, Sendable {
    case usb, lsb, cw, am, fm

    public var kiwiToken: String {
        switch self {
        case .usb: "usb"
        case .lsb: "lsb"
        case .cw: "cw"
        case .am: "am"
        case .fm: "nbfm"
        }
    }

    public var label: String {
        switch self {
        case .usb: "USB"
        case .lsb: "LSB"
        case .cw: "CW"
        case .am: "AM"
        case .fm: "FM"
        }
    }

    public var defaultPassband: (low: Int, high: Int) {
        switch self {
        case .usb: (300, 2700)
        case .lsb: (-2700, -300)
        case .cw: (300, 700)
        case .am: (-4900, 4900)
        case .fm: (-6000, 6000)
        }
    }

    /// The frequency to send for a dial frequency. In CW the Kiwi's dial
    /// shows the signal, which sits at the passband's centre above the
    /// carrier (`freq_dsp_to_car`); every other mode sends the dial as is.
    public func carrierHz(forDialHz dial: Int, lowCut: Int, highCut: Int) -> Int {
        self == .cw ? dial - (lowCut + (highCut - lowCut) / 2) : dial
    }
}

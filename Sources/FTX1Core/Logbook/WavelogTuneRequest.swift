import Foundation

/// A tune request from Wavelog's web pages (DX cluster, bandmap, DX
/// waterfall): the browser `fetch`es `GET <cat_url>/<frequency Hz>/<mode>`
/// from the radio's `cat_url`, `http://127.0.0.1:54321` unless set in
/// Wavelog's radio settings — the port WaveLogGate listens on. Read from
/// 3.2.3's `assets/js/cat.js` (`performRadioTuning`): the mode is one of
/// lsb, usb, cw, fm, am, rtty, pkt, dig, pktlsb, pktusb, pktfm (anything
/// else is sent as usb), lowercase; the request is a plain cross-origin
/// `fetch`, so the reply needs CORS headers or the page reports a failure
/// even though the rig tuned. Wavelog's `determineRadioMode` sends "rtty"
/// for most digital spots (FT8 included) and "fm" for digital voice.
public struct WavelogTuneRequest: Equatable, Sendable {
    public var frequencyHz: Int
    /// nil when the mode isn't one Wavelog sends, or has no FTX-1 mode.
    public var mode: RigMode?

    public init(frequencyHz: Int, mode: RigMode?) {
        self.frequencyHz = frequencyHz
        self.mode = mode
    }

    /// An HTTP request's head, as far as the listener cares.
    public struct HTTPHead: Equatable, Sendable {
        public var method: String
        public var path: String
        /// Header names lowercased.
        public var headers: [String: String]
    }

    /// Parses everything up to the blank line; nil if it isn't HTTP.
    public static func parseHead(_ text: String) -> HTTPHead? {
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count >= 3, requestLine[2].hasPrefix("HTTP/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPHead(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
    }

    /// `/<Hz>/<mode>` (or `/<Hz>`); nil for any other path. Frequencies
    /// outside 30 kHz–470 MHz (the FTX-1's coverage, generously) are
    /// refused here rather than sent to the rig.
    public init?(path: String) {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = pathOnly.split(separator: "/").map(String.init)
        guard (1...2).contains(parts.count),
              let hz = Double(parts[0]), hz.isFinite,
              (30_000...470_000_000).contains(hz)
        else { return nil }
        frequencyHz = Int(hz.rounded())
        mode = parts.count == 2 ? Self.rigMode(forCATMode: parts[1]) : nil
    }

    /// Wavelog's CAT mode names → the FTX-1's. DATA-L doesn't exist in
    /// `RigMode`, so pktlsb is DATA-U too.
    public static func rigMode(forCATMode mode: String) -> RigMode? {
        switch mode.lowercased() {
        case "lsb": .lsb
        case "usb": .usb
        case "cw": .cw
        case "fm": .fm
        case "am": .am
        case "rtty": .rtty
        case "pkt", "dig", "pktusb", "pktlsb": .dataUSB
        case "pktfm": .dataFM
        default: nil
        }
    }

    /// `scheme://host[:port]` of a Wavelog URL as Settings holds it (no
    /// scheme means https, as in `Wavelog.apiURL`), lowercased — compared
    /// against a request's `Origin` header. nil if it isn't a URL.
    public static func origin(ofWavelogURL base: String) -> String? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort = scheme == "http" ? 80 : 443
        if let port = components.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

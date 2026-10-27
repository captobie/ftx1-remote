import Foundation

/// A Wavelog server's REST API v2 (wavelog.org, self-hosted PHP; in every
/// release since 3.1.0), for the requests the app makes: log one QSO,
/// check a token + station location without writing (the API's own dry
/// run), and list the station locations a token can see. Request and reply
/// shapes are from Wavelog's `Api_v2.php`, `Api_v2_response.php` and
/// `api_v2/Qso_resource.php`/`Station_resource.php` (master, read
/// 2026-10-24), not docs. v2 over v1 (user decision, server on 3.2.3): the
/// token goes in a header rather than the URL or body, it can be scoped to
/// just what the app needs (`qso:write`, `station:read`), and duplicates
/// come back as a count instead of an HTML message.
///
/// - Auth: `Authorization: Bearer wl2_…`. v1 keys ("wl…" without the 2_)
///   are refused with 401 `invalid_token`.
/// - Replies: `{"data": …, "meta": …}` on success; `{"error": {"code",
///   "message", "details"?}}` otherwise, the HTTP status carrying the
///   meaning. Rate limiting is the exception: 429 with v1's `{"status":
///   "failed", "reason"}`.
/// - `POST <base>/index.php/api/v2/qso` with `{station_profile_id,
///   import_type: "adif", adif, dryrun}` → 201 `{parsed, imported, skipped,
///   messages}` (`skipped` = duplicates: the import runs with "skip
///   duplicates" on, so a resend is safe); 400 `validation_error` when
///   nothing imported; 403 `forbidden` for a location that isn't the
///   token owner's, `insufficient_scope` without `qso:write`. A dry run
///   checks token, scope and location, parses the ADIF, writes nothing
///   and answers 200 `{dryrun: true, parsed}`.
/// - `GET <base>/index.php/api/v2/station` → `[{id, name, callsign,
///   gridsquare, active, …}]` (needs `station:read`).
/// - `POST <base>/index.php/api/v2/radio` with `{radio, frequency,
///   mode, frequency_rx?, mode_rx?, power?}` (needs `radio:write`; read
///   from 3.2.3's `api_v2/Radio_resource.php` and `models/Cat.php`) →
///   200 updated / 201 created: an upsert by radio name, the same row
///   WaveLogGate and other CAT clients write. Frequencies in Hz, power in
///   watts, modes ≤10 characters; a field left out is stored as NULL
///   (`frequency_rx`/`mode_rx`) or left as it was (`power`). 400
///   `validation_error` names the bad fields.
///
/// Unlike v1, v2 doesn't refuse a record whose `station_callsign` differs
/// from the location's: it stores it under the location's callsign
/// (seen against a 3.2.4 server: sent as W9XYZ, stored as the location's
/// N0CALL).
/// `index.php/` is in every URL so servers without URL rewriting work too.
public enum Wavelog {
    public struct Station: Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var callsign: String
        public var gridsquare: String
        /// The user's active location in Wavelog's web UI.
        public var isActive: Bool

        public init(id: String, name: String, callsign: String, gridsquare: String, isActive: Bool) {
            self.id = id
            self.name = name
            self.callsign = callsign
            self.gridsquare = gridsquare
            self.isActive = isActive
        }
    }

    public enum LogResult: Equatable, Sendable {
        /// Written (or, for a dry run, would be).
        case created
        /// Already in the log — Wavelog's own duplicate check.
        case duplicate
        /// Refused; the server's reason, as plain text.
        case rejected(String)
    }

    public enum APIError: Error, Equatable, CustomStringConvertible {
        case badURL
        /// The server answered with an error of its own (bad token, missing
        /// scope, rate limit, …), as plain text.
        case refused(String)
        /// No usable reply: the HTTP status and the start of the body.
        case unexpectedReply(status: Int, body: String)
        case network(String)

        public var description: String {
            switch self {
            case .badURL:
                String(localized: "wavelog.theWavelogUrlIsnt", bundle: .module)
            case .refused(let message):
                String(localized: "wavelog.wavelog \(message)", bundle: .module)
            case .unexpectedReply(let status, let body):
                body.isEmpty
                    ? String(localized: "wavelog.unexpectedReplyFromWavelog \(status)", bundle: .module)
                    : String(localized: "wavelog.unexpectedReplyFromWavelogHttp \(status) \(body)", bundle: .module)
            case .network(let message):
                message
            }
        }
    }

    /// What a CAT client reports about the rig: the transmit frequency and
    /// mode, and the receive side's only when it differs (split).
    public struct RadioStatus: Equatable, Sendable {
        public var frequencyHz: Int
        public var mode: String?
        public var frequencyRxHz: Int?
        public var modeRx: String?
        public var powerWatts: Double?

        public init(frequencyHz: Int, mode: String?, frequencyRxHz: Int? = nil, modeRx: String? = nil, powerWatts: Double? = nil) {
            self.frequencyHz = frequencyHz
            self.mode = mode
            self.frequencyRxHz = frequencyRxHz
            self.modeRx = modeRx
            self.powerWatts = powerWatts
        }
    }

    /// The CAT mode string Wavelog's QSO form understands for a rig mode
    /// (its `radiohelpers.js`: USB/LSB/CW/AM/FM/RTTY, PKTUSB for data; a
    /// digital-voice mode is FM there, "the closest analog"). DATA-FM has
    /// no entry of its own, so it's FM too.
    public static func catMode(for mode: RigMode) -> String? {
        switch mode {
        case .usb: "USB"
        case .lsb: "LSB"
        case .cw: "CW"
        case .am: "AM"
        case .fm, .dataFM, .c4fm: "FM"
        case .rtty: "RTTY"
        case .dataUSB: "PKTUSB"
        case .unknown: nil
        }
    }

    /// v2 tokens start with this; v1 keys don't.
    public static let tokenPrefix = "wl2_"

    /// Requests time out after this long; a QSO send is one small POST.
    public static let timeout: TimeInterval = 10

    // MARK: Requests

    /// `<base>/index.php/api/v2/<path>`. `base` is what the user typed: the
    /// Wavelog root, with or without a trailing slash or `index.php`; no
    /// scheme means https.
    public static func apiURL(base: String, path: String) -> URL? {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        if !root.contains("://") { root = "https://" + root }
        while root.hasSuffix("/") { root.removeLast() }
        if root.lowercased().hasSuffix("/index.php") { root.removeLast("/index.php".count) }
        while root.hasSuffix("/") { root.removeLast() }
        guard let url = URL(string: root + "/index.php/api/v2/" + path),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    public static func qsoRequest(base: String, token: String, stationID: String, adif: String, dryRun: Bool = false) -> URLRequest? {
        guard let url = apiURL(base: base, path: "qso"), let station = Int(stationID) else { return nil }
        let body: [String: Any] = [
            "station_profile_id": station,
            "import_type": "adif",
            "adif": adif,
            "dryrun": dryRun,
        ]
        var request = request(url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    public static func stationsRequest(base: String, token: String) -> URLRequest? {
        apiURL(base: base, path: "station").map { request($0, token: token) }
    }

    public static func radioRequest(base: String, token: String, radio: String, status: RadioStatus) -> URLRequest? {
        guard let url = apiURL(base: base, path: "radio") else { return nil }
        var body: [String: Any] = ["radio": radio, "frequency": status.frequencyHz]
        if let mode = status.mode { body["mode"] = mode }
        if let rx = status.frequencyRxHz { body["frequency_rx"] = rx }
        if let modeRx = status.modeRx { body["mode_rx"] = modeRx }
        if let power = status.powerWatts { body["power"] = power }
        var request = request(url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Replies

    public static func parseLogReply(status: Int, body: Data) throws(APIError) -> LogResult {
        let object = try envelope(status: status, body: body)
        if let message = errorMessage(in: object) {
            // Refusals of this QSO (bad ADIF, a location that isn't the
            // token's) are rejections; anything about the token or the
            // server's state is an error the user has to fix in Settings.
            if status == 400 || (status == 403 && errorCode(in: object) == "forbidden") {
                return .rejected(message)
            }
            throw .refused(message)
        }
        guard let data = object["data"] as? [String: Any] else {
            throw .unexpectedReply(status: status, body: snippet(body))
        }
        if data["dryrun"] as? Bool == true { return .created }
        if int(data["imported"]) ?? 0 > 0 { return .created }
        if int(data["skipped"]) ?? 0 > 0 { return .duplicate }
        let messages = (data["messages"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map(plainText)
            .filter { !$0.isEmpty }
        return .rejected(messages.isEmpty ? String(localized: "wavelog.wavelogDidntImportThe", bundle: .module) : messages.joined(separator: "; "))
    }

    public static func parseStations(status: Int, body: Data) throws(APIError) -> [Station] {
        let object = try envelope(status: status, body: body)
        if let message = errorMessage(in: object) { throw .refused(message) }
        guard (200..<300).contains(status), let rows = object["data"] as? [[String: Any]] else {
            throw .unexpectedReply(status: status, body: snippet(body))
        }
        return rows.compactMap { row in
            guard let id = string(row["id"]), !id.isEmpty else { return nil }
            return Station(
                id: id,
                name: string(row["name"]) ?? "",
                callsign: string(row["callsign"]) ?? "",
                gridsquare: string(row["gridsquare"]) ?? "",
                isActive: row["active"] as? Bool ?? false
            )
        }
    }

    /// A radio update's reply: nothing to return on success.
    public static func parseRadioReply(status: Int, body: Data) throws(APIError) {
        let object = try envelope(status: status, body: body)
        if let message = errorMessage(in: object) { throw .refused(message) }
        guard (200..<300).contains(status), object["data"] != nil else {
            throw .unexpectedReply(status: status, body: snippet(body))
        }
    }

    private static func envelope(status: Int, body: Data) throws(APIError) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw .unexpectedReply(status: status, body: snippet(body))
        }
        return object
    }

    /// v2's `{"error": {"message"}}`, or v1's `{"status": "failed",
    /// "reason"}` (the rate limiter's 429).
    private static func errorMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String).map(plainText) ?? ""
            return message.isEmpty ? (error["code"] as? String ?? "error") : message
        }
        if object["data"] == nil, let reason = object["reason"] as? String, !reason.isEmpty {
            return plainText(reason)
        }
        return nil
    }

    private static func errorCode(in object: [String: Any]) -> String? {
        (object["error"] as? [String: Any])?["code"] as? String
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    /// Server text as one line of plain text: `<br>` ends a message, other
    /// tags go, the entities `htmlentities` makes are decoded. (v2 strips
    /// tags itself; an error page or proxy reply may not.)
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    private static func snippet(_ body: Data) -> String {
        let text = String(decoding: body.prefix(200), as: UTF8.self)
        return plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Sending

    /// Logs one QSO (or, with `dryRun`, checks that it could be).
    public static func log(_ qso: LoggedQSO, base: String, token: String, stationID: String, dryRun: Bool = false, session: URLSession = .shared) async throws(APIError) -> LogResult {
        guard let request = qsoRequest(base: base, token: token, stationID: stationID, adif: ADIFRecord.record(for: qso), dryRun: dryRun) else {
            throw .badURL
        }
        let (status, body) = try await perform(request, session: session)
        return try parseLogReply(status: status, body: body)
    }

    public static func stations(base: String, token: String, session: URLSession = .shared) async throws(APIError) -> [Station] {
        guard let request = stationsRequest(base: base, token: token) else { throw .badURL }
        let (status, body) = try await perform(request, session: session)
        return try parseStations(status: status, body: body)
    }

    /// Reports the rig's state as the CAT radio `radio`.
    public static func reportRadio(_ status: RadioStatus, radio: String, base: String, token: String, session: URLSession = .shared) async throws(APIError) {
        guard let request = radioRequest(base: base, token: token, radio: radio, status: status) else { throw .badURL }
        let (code, body) = try await perform(request, session: session)
        try parseRadioReply(status: code, body: body)
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws(APIError) -> (Int, Data) {
        do {
            let (body, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                throw .network(String(localized: "common.couldntFindTheHost \(request.url?.host ?? "")", bundle: .module))
            case .timedOut:
                throw .network(String(localized: "wavelog.wavelogDidntAnswerWithin \(Int(timeout))", bundle: .module))
            default:
                throw .network(String(localized: "wavelog.couldntReachWavelog \(error.localizedDescription)", bundle: .module))
            }
        } catch {
            throw .network(String(localized: "wavelog.couldntReachWavelog \(error.localizedDescription)", bundle: .module))
        }
    }
}

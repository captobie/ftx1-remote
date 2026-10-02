import Foundation

/// Finds amateur callsigns in decoded CW text, so the CW window can make
/// them clickable (a click fills the send pane's Their call field).
///
/// A call is: 1–2 letters, a digit+letter or a letter+digit, then a digit,
/// then 1–4 letters (`W1AW`, `KA3ROC`, `2E0ABC`, `E73XYZ`), optionally
/// with `/`-separated parts (`DL5ABC/P`, `VE3/W1AW`), judged on its longest
/// part. That rules out the usual non-calls in a QSO: reports (`5NN`,
/// `599`), numbers (`73`, `40M`), Q-codes and abbreviations (no digit).
enum CWCallsigns {
    /// Callsign-shaped tokens are runs of letters, digits and "/"; anything
    /// else (spaces, `?`, `,`, `<BT>`) ends them.
    private static let token = #/[A-Z0-9/]+/#
    private static let base = #/([A-Z]{1,2}|[0-9][A-Z]|[A-Z][0-9])[0-9][A-Z]{1,4}/#

    static func isCallsign(_ candidate: Substring) -> Bool {
        guard (3...12).contains(candidate.count) else { return false }
        let parts = candidate.split(separator: "/")
        guard let longest = parts.max(by: { $0.count < $1.count }) else { return false }
        return longest.wholeMatch(of: base) != nil
    }

    /// The ranges of callsigns in `text`, minus `excluding` (the operator's
    /// own call, in any of its `/` forms).
    static func ranges(in text: String, excluding ownCall: String) -> [Range<String.Index>] {
        let own = ownCall.uppercased().trimmingCharacters(in: .whitespaces)
        return text.matches(of: token).compactMap { match in
            let candidate = match.output
            guard isCallsign(candidate) else { return nil }
            if !own.isEmpty, candidate.split(separator: "/").contains(where: { $0 == own }) {
                return nil
            }
            return match.range
        }
    }

    /// The `URL` a callsign link carries, and back. A custom scheme the CW
    /// window handles itself (`OpenURLAction`), never opened by the system.
    static let scheme = "ftx1-cw-call"

    static func url(for call: Substring) -> URL? {
        URL(string: "\(scheme):\(call.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(call))")
    }

    static func call(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return url.absoluteString.dropFirst(scheme.count + 1).removingPercentEncoding
    }
}

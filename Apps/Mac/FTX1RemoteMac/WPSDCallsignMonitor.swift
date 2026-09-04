import Foundation

/// Polls a WPSD (Pi-Star-family hotspot dashboard) instance for the
/// callsign of whoever is currently transmitting C4FM/YSF traffic through
/// it, on the assumption the hotspot is relaying that same traffic to the
/// rig over local RF (see `RigState.c4fmCallsign`).
///
/// There's no CAT command for received C4FM digital data — this reaches the
/// callsign a completely different way, by scraping the same HTML fragment
/// WPSD's own dashboard page polls (`/mmdvmhost/caller_details_table.php`),
/// undocumented and unauthenticated. Mirrors `AudioCaptureEngine`'s shape
/// (owned + lifecycle-driven by `HubService`, reports out via a closure)
/// but for this network side-channel rather than the audio-hardware one.
final class WPSDCallsignMonitor {
    /// Always invoked on the main actor — same contract as
    /// `AudioCaptureEngine.onNewFrame`.
    var onCallsignUpdate: ((String?) -> Void)?

    /// Slightly slower than the dashboard page's own ~1s polling cadence —
    /// this hotspot's PHP backend visibly strains (roughly half of 1s-cadence
    /// requests time out) when polled that fast by two clients (the WPSD
    /// dashboard page itself, if left open, plus this app) at once.
    private let pollInterval: Duration = .seconds(2)
    private let session: URLSession
    private var pollTask: Task<Void, Never>?
    private var currentHost: String?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        session = URLSession(configuration: configuration)
    }

    /// No-op if already running against this exact host.
    func start(host: String) {
        guard host != currentHost else { return }
        stop()
        currentHost = host
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(host: host)
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        currentHost = nil
    }

    /// Only calls `report(_:)` on a successful, well-formed fetch — including
    /// when that successful fetch determines there's genuinely no live
    /// caller right now (a real `nil`). A failed/timed-out request reports
    /// nothing at all, leaving whatever callsign is currently displayed in
    /// place rather than blanking it: this hotspot's PHP backend times out
    /// on a meaningful fraction of requests under sustained polling (see
    /// `pollInterval`), and clearing the display on every such hiccup made
    /// an actively-live callsign flicker on and off every couple of polls.
    private func poll(host: String) async {
        guard let url = URL(string: "http://\(host)/mmdvmhost/caller_details_table.php") else { return }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return
        }
        report(Self.liveCallsign(inCallerDetailsHTML: html))
    }

    private func report(_ callsign: String?) {
        Task { @MainActor [weak self] in
            self?.onCallsignUpdate?(callsign)
        }
    }

    /// Parses WPSD's "Current / Last Caller Details" fragment. This table
    /// always shows the *last* caller, live or not, so a callsign alone
    /// isn't enough — two more conditions from the same row confirm it's a
    /// station worth surfacing right now rather than a stale leftover:
    ///
    ///  - **Src == "Net"**: the traffic originated from the network side and
    ///    is being relayed out to the local radio. "RF" would mean the
    ///    *local* radio (the FTX-1 itself) is the one transmitting up to the
    ///    network — i.e. the user's own callsign keying up, not someone to
    ///    display.
    ///  - **Live TX indicator**: the last cell reads e.g. "TX 18+ sec" only
    ///    while a transmission is actively in progress; once it ends, that
    ///    cell shows a plain elapsed-seconds number instead (e.g. "30.3").
    ///
    /// Rather than parse the table structure precisely (WPSD's own markup
    /// is inconsistent about closing `</td>` between these two cells,
    /// confirmed against two live samples), this strips all tags from the
    /// row first — collapsing each cell boundary to whitespace — and checks
    /// the *flattened* text for the substring "Net TX", which the Src and
    /// live-TX cells reduce to exactly when both conditions hold (confirmed:
    /// a just-ended caller flattens to "Net  7.2s ...", not "Net TX", so
    /// this correctly excludes stale last-heard entries too).
    static func liveCallsign(inCallerDetailsHTML html: String) -> String? {
        let flattened = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        guard flattened.contains("Net TX") else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"qrz\.com/db/([A-Za-z0-9]+)""#) else {
            return nil
        }
        let fullRange = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: fullRange),
              let callsignRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[callsignRange])
    }
}

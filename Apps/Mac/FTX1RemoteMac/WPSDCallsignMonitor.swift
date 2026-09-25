import Foundation

/// Polls a WPSD (Pi-Star-family hotspot dashboard) instance for two things
/// related to C4FM/YSF traffic passing through it, on the assumption the
/// hotspot is relaying that same traffic to the rig over local RF: the
/// callsign of whoever is currently transmitting (see `RigState.c4fmCallsign`)
/// and the name of the YSF reflector the hotspot is currently linked to (see
/// `RigState.c4fmReflector`).
///
/// There's no CAT command for either of these — this reaches them a
/// completely different way, by scraping the same HTML fragments WPSD's own
/// dashboard page polls, undocumented and unauthenticated. Mirrors
/// `AudioCaptureEngine`'s shape (owned + lifecycle-driven by `HubService`,
/// reports out via a closure) but for this network side-channel rather than
/// the audio-hardware one.
final class WPSDCallsignMonitor {
    /// Always invoked on the main actor — same contract as
    /// `AudioCaptureEngine.onNewFrame`.
    var onCallsignUpdate: ((String?) -> Void)?
    /// Same contract as `onCallsignUpdate`.
    var onReflectorUpdate: ((String?) -> Void)?

    /// Slower than the dashboard page's own ~1s polling cadence — this
    /// hotspot (a Pi Zero 2 W) costs ~0.7s of PHP work per request when idle
    /// and ~3.3s once polled at ~0.7 req/s by this app plus the dashboard
    /// page (measured 2026-09-20), so poll conservatively. User-adjustable
    /// (Settings → Polling, default 3s), read live each iteration.
    private var pollInterval: Duration { PollingSettings.wpsdCallerInterval }
    /// The linked reflector changes far less often than the live caller, so
    /// this polls on its own, slower loop rather than riding along with
    /// `pollInterval`. The WPSD dashboard polls this endpoint every 5s
    /// (`reloadRepeaterInfo`), which is faster than needed here, and a slower
    /// cadence keeps this app from adding to the backend strain noted above.
    /// User-adjustable (Settings → Polling, default 30s).
    private var reflectorPollInterval: Duration { PollingSettings.wpsdReflectorInterval }
    private let session: URLSession
    private var pollTask: Task<Void, Never>?
    private var reflectorPollTask: Task<Void, Never>?
    private var currentHost: String?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // The hotspot's PHP backend routinely takes 4-5s to answer (measured
        // 2026-09-20 with a ~8ms network RTT), so 3s timed out nearly every
        // request. Polls are sequential per loop, so a long timeout can't
        // pile up overlapping requests.
        configuration.timeoutIntervalForRequest = 10
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
        reflectorPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollReflector(host: host)
                try? await Task.sleep(for: self?.reflectorPollInterval ?? .seconds(30))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        reflectorPollTask?.cancel()
        reflectorPollTask = nil
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

    /// No `report(_:)`-style "leave the display alone on a failed fetch"
    /// caveat needed here — this endpoint isn't shared with the dashboard's
    /// own faster-polled panel, so it isn't subject to the same backend
    /// strain (see `reflectorPollInterval`); a failed fetch still just skips
    /// the update rather than reporting `nil`, for consistency.
    private func pollReflector(host: String) async {
        guard let url = URL(string: "http://\(host)/mmdvmhost/repeaterinfo.php") else { return }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return
        }
        reportReflector(Self.linkedReflector(inRepeaterInfoHTML: html))
    }

    private func reportReflector(_ reflector: String?) {
        Task { @MainActor [weak self] in
            self?.onReflectorUpdate?(reflector)
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

    /// Parses WPSD's `repeaterinfo.php` sidebar fragment for the "YSF Status
    /// [In Room]" section's "Link" pill — the reflector the hotspot is
    /// currently linked to, independent of whether anyone is transmitting
    /// right now (unlike `liveCallsign`, which needs a live transmission).
    ///
    /// Confirmed against a live sample: when linked, the section reads
    /// `<span>Link</span><div class='pill-data'><span class='pill-value'>US-KCWide</span>…`.
    /// There's no confirmed live sample of the unlinked case, but every
    /// other mode's "Network"/"Link" pill on the same page (e.g. D-Star
    /// Network) renders unlinked as a bare
    /// `<span class='pill-value'>Not Linked</span>` with no surrounding
    /// `pill-data`/link-icon markup, using the same templated component —
    /// so this treats that value (case-insensitively) as "no reflector"
    /// too, on top of an outright missing/empty match.
    static func linkedReflector(inRepeaterInfoHTML html: String) -> String? {
        guard let sectionStart = html.range(of: "YSF Status") else { return nil }
        var section = html[sectionStart.upperBound...]
        if let nextSection = section.range(of: "sidebar-section-title") {
            section = section[..<nextSection.lowerBound]
        }
        guard let regex = try? NSRegularExpression(pattern: #"class=['"]pill-value['"]>([^<]*)<"#) else {
            return nil
        }
        let sectionString = String(section)
        let fullRange = NSRange(sectionString.startIndex..., in: sectionString)
        guard let match = regex.firstMatch(in: sectionString, range: fullRange),
              let valueRange = Range(match.range(at: 1), in: sectionString) else {
            return nil
        }
        let value = sectionString[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.caseInsensitiveCompare("Not Linked") != .orderedSame else {
            return nil
        }
        return value
    }
}

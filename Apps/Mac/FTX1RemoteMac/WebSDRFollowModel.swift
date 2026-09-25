import Combine
import FTX1Core
import Foundation

/// Persisted settings for the WebSDR window, `UserDefaults`-backed like
/// `APRSSettings`/`WPSDSettings`. A single current host (picked from the
/// directory or typed) — a favorites list would replace `hostPort` here.
enum WebSDRSettings {
    static let hostPortKey = "webSDR.hostPort"
    static let followRigKey = "webSDR.followRig"
    /// The receive ranges of the station last picked from the directory,
    /// as "lo-hi,lo-hi" (the listing's own format), plus the host they
    /// belong to — only applied while `hostPort` still equals that host.
    static let stationBandsKey = "webSDR.stationBands"
    static let stationBandsHostKey = "webSDR.stationBandsHost"
}

/// Drives the WebSDR window: follows the rig's Main VFO frequency/mode and
/// publishes the KiwiSDR URL `KiwiWebView` should show.
///
/// Subscribes to `hub.$rigState` — the same value every
/// `server.broadcast(rigState)` call sends to WebSocket clients — rather
/// than adding a second poll. `$rigState` fires on every individual field
/// write (the fast tier sets `frequencyHz` and `mode` separately, so a
/// transient new-frequency/old-mode pair is possible); `removeDuplicates` +
/// the 400 ms debounce absorb that as well as VFO-knob spinning. Kept as
/// its own `ObservableObject` so nothing here re-renders `ContentView`.
///
/// One direction only (rig → Kiwi). v1.1 seams, deliberately not built:
/// click-to-tune back to the rig (would need JS injection into the Kiwi
/// page to observe its tuning), mute-on-TX (observe `rigState.ptt` here),
/// following Sub (`secondaryFrequencyHz`/`secondaryMode`), and other
/// WebSDR/OpenWebRX platforms (a per-platform URL builder alongside
/// `KiwiSDRURLBuilder`).
final class WebSDRFollowModel: ObservableObject {
    private struct FollowTarget: Equatable {
        let frequencyHz: Int
        let mode: RigMode
    }

    /// Committed host (the text field commits on Return, not per keystroke,
    /// so a half-typed host never triggers a load). Setting it doesn't load
    /// anything by itself — `connect()` does.
    @Published var hostPort: String {
        didSet {
            UserDefaults.standard.set(hostPort, forKey: WebSDRSettings.hostPortKey)
        }
    }

    /// Where the retune range check comes from: the picked station's own
    /// ranges while its host is the current one, else KiwiSDR's 0–30 MHz.
    private var stationBands: (host: String, bands: [ClosedRange<Int>])?

    var activeBands: [ClosedRange<Int>] {
        if let stationBands, stationBands.host == hostPort { return stationBands.bands }
        return KiwiSDRURLBuilder.defaultBands
    }

    /// The rig frequency the window is following (after the debounce), for
    /// the directory's "covers rig frequency" filter. nil before the first
    /// rig value, or 0 while the rig isn't connected.
    @Published private(set) var rigFrequencyHz: Int?

    /// Whether the window should hold a live Kiwi session. Starts false on
    /// every open (public Kiwis have few listener slots, so a session is
    /// only opened on an explicit Connect / Return), and `disconnect()` is
    /// also called when the window closes (`WebSDRFollowView.onDisappear`).
    @Published private(set) var isConnected = false

    @Published var followRig: Bool {
        didSet {
            UserDefaults.standard.set(followRig, forKey: WebSDRSettings.followRigKey)
            evaluate()
        }
    }

    /// One page load for `KiwiWebView`. `id` distinguishes a deliberate
    /// reload of the same URL (Return in the host field, e.g. to retry after
    /// an error) from a repeat that should be ignored.
    struct PageRequest: Equatable {
        let url: URL
        let id: Int
    }

    /// What `KiwiWebView` should be showing. Only changes when a genuinely
    /// different page is wanted — every change is a full page reload (Kiwi
    /// reconnect), so rig-driven repeats are filtered out here.
    @Published private(set) var pageRequest: PageRequest?
    @Published private(set) var status = ""

    // MARK: Recording (the Kiwi's own recorder — see KiwiRecordingBridge)

    let recordingBridge = KiwiRecordingBridge()

    /// The user's Record/Stop intent. Stays true across retunes: each
    /// retune saves the current file and starts a new one for the new
    /// frequency once the reloaded page's audio is running (user decision:
    /// one file per frequency, not paused following).
    @Published private(set) var isRecording = false
    /// When the current file's recording actually began; nil while between
    /// files (saving, reloading, waiting for the Kiwi's audio).
    @Published private(set) var segmentStartedAt: Date?
    /// Last save/failure note, shown at the right of the status line.
    @Published private(set) var recordingNote: String?

    /// What the page on screen is tuned to — the saved file's label.
    /// nil for the bare host page (no `?f=`).
    private var tunedTarget: FollowTarget?
    private var startTask: Task<Void, Never>?
    /// A reload waiting for the current recording to finish saving; only
    /// the newest survives if the rig moves again meanwhile.
    private var pendingReload: (request: PageRequest, tuned: FollowTarget?)?
    private var reloadTask: Task<Void, Never>?

    private var latest: FollowTarget?
    private var lastIssuedURL: URL?
    private var lastTunedDescription: String?
    private var lastTunedAt = Date()
    private var cancellable: AnyCancellable?

    init(hub: HubService) {
        let defaults = UserDefaults.standard
        hostPort = defaults.string(forKey: WebSDRSettings.hostPortKey) ?? ""
        followRig = defaults.object(forKey: WebSDRSettings.followRigKey) as? Bool ?? true
        if let host = defaults.string(forKey: WebSDRSettings.stationBandsHostKey),
           let raw = defaults.string(forKey: WebSDRSettings.stationBandsKey) {
            stationBands = (host, KiwiSDRStation.parseBands(raw))
        }

        cancellable = hub.$rigState
            .map { FollowTarget(frequencyHz: $0.frequencyHz, mode: $0.mode) }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] target in
                guard let self else { return }
                latest = target
                rigFrequencyHz = target.frequencyHz
                // First value (~400 ms after open, since `$rigState` emits
                // its current value on subscribe): load *something* even if
                // there's nothing to tune to. Not done in `init` itself —
                // loading the bare host there and then the tuned URL 400 ms
                // later would open two Kiwi sessions back to back, and some
                // Kiwis reject a second connection from the same IP.
                evaluate(forceHostPage: isConnected && pageRequest == nil)
            }
        recordingBridge.onUnexpectedSave = { [weak self] url in
            self?.kiwiEndedRecording(savedTo: url)
        }
        evaluate()
    }

    /// Opens (or, if already connected, reloads) the Kiwi session. Before
    /// the first rig value has arrived (<400 ms after open), the load is
    /// left to the subscription above so it goes straight to the tuned URL.
    func connect() {
        isConnected = true
        lastIssuedURL = nil
        evaluate(forceHostPage: latest != nil)
    }

    /// Picks a station from the directory: fills the host and remembers the
    /// station's receive ranges, but does NOT connect — connecting is always
    /// a separate, explicit Connect. If a different Kiwi is currently
    /// connected, that session is ended (never switched to the new one
    /// automatically).
    func select(_ station: KiwiSDRStation) {
        let host = station.hostPort
        if isConnected, host != hostPort { disconnect() }
        stationBands = (host, station.bands)
        let raw = station.bands.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: WebSDRSettings.stationBandsKey)
        UserDefaults.standard.set(host, forKey: WebSDRSettings.stationBandsHostKey)
        hostPort = host
        evaluate()
    }

    /// Ends the Kiwi session: `KiwiWebView` navigates to about:blank when
    /// `pageRequest` goes nil, which unloads the Kiwi page and closes its
    /// WebSocket (freeing the listener slot).
    ///
    /// A recording in progress is saved first — unloading the page would
    /// throw it away — so the unload waits for that (≤5 s). The UI shows
    /// disconnected immediately.
    func disconnect() {
        isConnected = false
        pendingReload = nil
        lastIssuedURL = nil
        if isRecording {
            endRecording()
            Task { [weak self] in
                let url = await self?.recordingBridge.stop()
                self?.noteSaved(url)
                self?.unloadIfStillDisconnected()
            }
        } else {
            unloadIfStillDisconnected()
        }
        evaluate()
    }

    private func unloadIfStillDisconnected() {
        guard !isConnected else { return }
        pageRequest = nil
        tunedTarget = nil
    }

    func toggleRecording() {
        if isRecording {
            endRecording()
            Task { [weak self] in
                let url = await self?.recordingBridge.stop()
                self?.noteSaved(url)
            }
        } else {
            guard isConnected, pageRequest != nil else { return }
            isRecording = true
            recordingNote = nil
            startSegment()
        }
    }

    /// `KiwiWebView` finished loading a Kiwi page: if a recording spans the
    /// reload (a retune), start the next file.
    func pageDidLoad() {
        if isRecording, reloadTask == nil { startSegment() }
    }

    private func startSegment() {
        startTask?.cancel()
        segmentStartedAt = nil
        let label = tunedTarget.map { AudioRecorder.label(frequencyHz: $0.frequencyHz, mode: $0.mode) } ?? ""
        startTask = Task { [weak self] in
            guard let self else { return }
            let started = await recordingBridge.start(fallbackLabel: label)
            guard !Task.isCancelled, isRecording else { return }
            if started {
                segmentStartedAt = Date()
            } else {
                endRecording()
                recordingNote = "Recording didn't start — the KiwiSDR's audio isn't running."
            }
        }
    }

    private func endRecording() {
        isRecording = false
        segmentStartedAt = nil
        startTask?.cancel()
        startTask = nil
    }

    private func noteSaved(_ url: URL?) {
        recordingNote = url.map { "Saved “\($0.deletingPathExtension().lastPathComponent)”" }
            ?? recordingNote
    }

    /// The Kiwi stopped (and saved) on its own — its audio connection
    /// closed, e.g. a listening time limit. Not restarted automatically.
    private func kiwiEndedRecording(savedTo url: URL?) {
        guard isRecording, reloadTask == nil else { noteSaved(url); return }
        endRecording()
        recordingNote = "Recording stopped by the KiwiSDR (its connection closed)"
            + (url.map { " — saved “\($0.deletingPathExtension().lastPathComponent)”" } ?? "")
    }

    /// Called by `KiwiWebView` when a load fails outright (bad host, Kiwi
    /// down) so the status line says so instead of a stale "Tuned to".
    func reportLoadFailure(_ message: String) {
        status = "Couldn't load \(hostPort): \(message)"
    }

    /// `forceHostPage`: on window open / host change, show the Kiwi even
    /// when there's nothing to tune to yet (rig out of range, not
    /// connected, or Follow off), so the user isn't staring at a blank view.
    private func evaluate(forceHostPage: Bool = false) {
        guard let base = KiwiSDRURLBuilder.baseURL(from: hostPort) else {
            status = hostPort.isEmpty
                ? "Enter a KiwiSDR host:port and press Return."
                : "“\(hostPort)” isn't a valid host:port."
            return
        }

        guard isConnected else {
            status = "Disconnected" + (lastTunedDescription.map { " — last tuned to \($0)" } ?? "")
            return
        }

        guard followRig else {
            if forceHostPage { issue(base) }
            status = "Follow off" + (lastTunedDescription.map { " — last tuned to \($0)" } ?? "")
            return
        }

        guard let latest else {
            if forceHostPage { issue(base) }
            status = "Waiting for rig state…"
            return
        }

        switch KiwiSDRURLBuilder.retune(hostPort: hostPort, frequencyHz: latest.frequencyHz, mode: latest.mode,
                                         bands: activeBands) {
        case let .tune(tuneURL, hz, token):
            let description = KiwiSDRURLBuilder.kHzString(hz) + " kHz " + (token?.uppercased() ?? "")
            lastTunedDescription = description.trimmingCharacters(in: .whitespaces)
            // Status is refreshed even when the URL is unchanged (e.g. back
            // in range at the same frequency), so it never goes stale.
            if forceHostPage || tuneURL != lastIssuedURL {
                issue(tuneURL, tuned: latest)
                lastTunedAt = Date()
            }
            let time = lastTunedAt.formatted(date: .omitted, time: .standard)
            status = token == nil
                ? "Tuned to \(lastTunedDescription!) at \(time) (mode unchanged — \(latest.mode.displayName) has no KiwiSDR equivalent)"
                : "Tuned to \(lastTunedDescription!) at \(time)"
        case let .outOfRange(hz, bands):
            if forceHostPage { issue(base) }
            let range = bands.map(KiwiSDRStation.describe).joined(separator: ", ")
            status = String(format: "Not retuned: %.3f MHz is outside this KiwiSDR's range (", Double(hz) / 1_000_000) + range + ")"
        case .noFrequency:
            if forceHostPage { issue(base) }
            status = "Not retuned: no rig frequency yet (rig not connected?)"
        case .noHost, .invalidHost:
            break  // handled by the baseURL guard above
        }
    }

    /// Loads `newURL` — unless a recording is running on the current page,
    /// in which case that file is saved first (a reload would lose it) and
    /// the load follows; `pageDidLoad` then starts the next file.
    private func issue(_ newURL: URL, tuned: FollowTarget? = nil) {
        lastIssuedURL = newURL
        let request = PageRequest(url: newURL, id: (pendingReload?.request.id ?? pageRequest?.id ?? 0) + 1)
        guard isRecording, pageRequest != nil else {
            tunedTarget = tuned
            pageRequest = request
            return
        }
        pendingReload = (request, tuned)
        guard reloadTask == nil else { return }
        startTask?.cancel()
        segmentStartedAt = nil
        reloadTask = Task { [weak self] in
            let url = await self?.recordingBridge.stop()
            guard let self else { return }
            noteSaved(url)
            reloadTask = nil
            guard isConnected, let next = pendingReload else { return }
            pendingReload = nil
            tunedTarget = next.tuned
            pageRequest = next.request
        }
    }
}

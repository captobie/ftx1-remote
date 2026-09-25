import Combine
import FTX1Core
import Foundation

/// Persisted settings for the WebSDR window, `UserDefaults`-backed like
/// `APRSSettings`/`WPSDSettings`. A single current host (picked from the
/// directory or typed) — a favorites list would replace `hostPort` here.
enum WebSDRSettings {
    static let hostPortKey = "webSDR.hostPort"
    static let followRigKey = "webSDR.followRig"
    static let tuneRigKey = "webSDR.tuneRig"
    static let mutedKey = "webSDR.muted"
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
/// The other direction, click-to-tune (Kiwi → rig, "Tune rig"): while
/// connected, the Kiwi page's own tuning globals are read ~4×/s
/// (`KiwiPageBridge.readTuning`); a change the user makes in the page —
/// clicking the waterfall, typing a frequency, a mode button — is sent to
/// the rig once it has held still for one poll. The rig's echo of that
/// change must not reload the Kiwi: `evaluate` skips the reload while the
/// Kiwi is already where the rig is, and holds off while the rig hasn't
/// caught up yet (`pendingRigTune`), since a poll cycle can still report
/// the old frequency after the set went out.
///
/// v1.1 seams, deliberately not built: mute-on-TX (observe `rigState.ptt` here),
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

    /// Click-to-tune: tuning in the Kiwi page tunes the rig's Main VFO (and
    /// its mode, where the two map — see `KiwiSDRURLBuilder.rigMode`).
    /// Independent of `followRig`.
    @Published var tuneRig: Bool {
        didSet { UserDefaults.standard.set(tuneRig, forKey: WebSDRSettings.tuneRigKey) }
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

    // MARK: Mute

    /// The WebSDR window's Mute. While the Kiwi is audible — connected and
    /// not muted here — the rig's Main playback is muted so the two don't
    /// play over each other; muting here (or disconnecting) unmutes Main
    /// again (`HubService.setWebSDRAudioActive`, which only ever undoes a
    /// mute it made itself). Applied to the page live via `KiwiPageBridge.
    /// setPageMuted`, and as the Kiwi's own `mute=1` URL parameter on every
    /// load so it survives the reload each retune causes.
    @Published private(set) var isMuted: Bool {
        didSet { UserDefaults.standard.set(isMuted, forKey: WebSDRSettings.mutedKey) }
    }
    private weak var hub: HubService?
    private var muteTask: Task<Void, Never>?

    func toggleMuted() {
        isMuted.toggle()
        updateMainAudio()
        guard pageRequest != nil else { return }
        muteTask?.cancel()
        let muted = isMuted
        muteTask = Task { [weak self] in await self?.pageBridge.setPageMuted(muted) }
    }

    private func updateMainAudio() {
        hub?.setWebSDRAudioActive(isConnected && !isMuted)
    }

    // MARK: Recording (the Kiwi's own recorder — see KiwiPageBridge)

    let pageBridge = KiwiPageBridge()

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
        tuneRig = defaults.object(forKey: WebSDRSettings.tuneRigKey) as? Bool ?? true
        isMuted = defaults.bool(forKey: WebSDRSettings.mutedKey)
        self.hub = hub
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
        pageBridge.onUnexpectedSave = { [weak self] url in
            self?.kiwiEndedRecording(savedTo: url)
        }
        evaluate()
    }

    /// Opens (or, if already connected, reloads) the Kiwi session. Before
    /// the first rig value has arrived (<400 ms after open), the load is
    /// left to the subscription above so it goes straight to the tuned URL.
    func connect() {
        isConnected = true
        updateMainAudio()
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
        updateMainAudio()
        muteTask?.cancel()
        pendingReload = nil
        lastIssuedURL = nil
        if isRecording {
            endRecording()
            Task { [weak self] in
                let url = await self?.pageBridge.stop()
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
        stopTuningPoll()
        pageRequest = nil
        tunedTarget = nil
    }

    func toggleRecording() {
        if isRecording {
            endRecording()
            Task { [weak self] in
                let url = await self?.pageBridge.stop()
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
        startTuningPoll()
        if isRecording, reloadTask == nil { startSegment() }
    }

    // MARK: Click-to-tune (Kiwi → rig)

    private struct KiwiTuning: Equatable {
        let frequencyHz: Int
        let mode: String
    }

    /// Frequencies closer than this count as the same: `?f=` carries 10 Hz
    /// resolution, so a round trip through the rig can land that far off.
    private static let sameFrequencyToleranceHz = 10
    private static let tuningPollInterval = Duration.milliseconds(250)
    /// How long a rig tune sent from the Kiwi may take to show up in
    /// `rigState` before the rig's (still old) value is followed again.
    private static let rigTuneGrace: TimeInterval = 3

    /// What the current page is tuned to, per the last poll; nil before
    /// the page has settled on its first frequency, and cleared whenever a
    /// new page is requested.
    private var kiwiTuning: KiwiTuning?
    /// The tuning already acted on (or the page's initial tuning), so each
    /// change is sent to the rig once.
    private var handledKiwiTuning: KiwiTuning?
    private var tuningPollTask: Task<Void, Never>?
    /// A rig tune sent from the Kiwi that `rigState` hasn't shown yet.
    private var pendingRigTune: (frequencyHz: Int, mode: RigMode?, until: Date)?

    /// Starts on each finished page load (not on request) so a read can't
    /// come from the page being navigated away from.
    private func startTuningPoll() {
        stopTuningPoll()
        tuningPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let reading = await pageBridge.readTuning()
                guard !Task.isCancelled else { return }
                if let reading { kiwiTuningRead(KiwiTuning(frequencyHz: reading.frequencyHz, mode: reading.mode)) }
                try? await Task.sleep(for: Self.tuningPollInterval)
            }
        }
    }

    private func stopTuningPoll() {
        tuningPollTask?.cancel()
        tuningPollTask = nil
        kiwiTuning = nil
        handledKiwiTuning = nil
    }

    private func kiwiTuningRead(_ reading: KiwiTuning) {
        // The page's first settled tuning is where it was loaded to (the
        // rig's frequency, or the Kiwi's own last one for a bare host
        // page) — never something the user did, so never sent to the rig.
        guard kiwiTuning != nil else {
            kiwiTuning = reading
            handledKiwiTuning = reading
            return
        }
        // Wait for the tuning to hold still for a poll, so a drag or a
        // spun mouse wheel sends where it stopped, not every step on the way.
        guard reading == kiwiTuning else {
            kiwiTuning = reading
            return
        }
        guard reading != handledKiwiTuning else { return }
        handledKiwiTuning = reading
        tuneRigFromKiwi(reading)
    }

    private func tuneRigFromKiwi(_ reading: KiwiTuning) {
        guard tuneRig, let hub else { return }
        let rig = hub.rigState
        let frequencyChanged = abs(reading.frequencyHz - rig.frequencyHz) > Self.sameFrequencyToleranceHz
        let newMode = KiwiSDRURLBuilder.rigMode(forKiwiMode: reading.mode, current: rig.mode)
        guard frequencyChanged || newMode != nil else { return }

        let description = KiwiSDRURLBuilder.kHzString(reading.frequencyHz) + " kHz " + reading.mode.uppercased()
        guard rig.frequencyHz > 0 else {
            status = "Rig not tuned to \(description): no rig frequency yet (rig not connected?)"
            return
        }
        guard !rig.ptt else {
            status = "Rig not tuned to \(description): it's transmitting"
            return
        }
        // The rig rejects a VFO frequency set while in Memory mode.
        guard rig.vfoMemoryMode != .memory else {
            status = "Rig not tuned to \(description): it's in Memory mode"
            return
        }

        pendingRigTune = (reading.frequencyHz, newMode, Date().addingTimeInterval(Self.rigTuneGrace))
        if frequencyChanged { hub.send(.setFrequency(hz: reading.frequencyHz)) }
        if let newMode { hub.send(.setMode(newMode)) }
        lastTunedDescription = description
        status = "Tuned the rig to \(description) from the KiwiSDR at "
            + Date().formatted(date: .omitted, time: .standard)
        // If the rig never shows the new tuning (rejected, disconnected),
        // follow its actual state again once the grace period is over.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.rigTuneGrace + 0.1))
            guard let self, let pending = pendingRigTune, Date() >= pending.until else { return }
            pendingRigTune = nil
            evaluate()
        }
    }

    /// Whether the page on screen is already at `hz`/`token` (after
    /// click-to-tune, or the rig tuned to where the Kiwi was), so following
    /// the rig there needs no reload.
    private func kiwiAlreadyAt(_ hz: Int, modeToken token: String?) -> Bool {
        guard let kiwiTuning,
              abs(kiwiTuning.frequencyHz - hz) <= Self.sameFrequencyToleranceHz
        else { return false }
        // A Kiwi mode with no rig equivalent (IQ, DRM) was picked in the
        // page on purpose; reloading to the rig's mode after every click
        // would keep undoing it.
        guard token != nil, let family = KiwiSDRURLBuilder.modeFamily(ofKiwiMode: kiwiTuning.mode) else { return true }
        return family == token
    }

    private func startSegment() {
        startTask?.cancel()
        segmentStartedAt = nil
        let label = tunedTarget.map { AudioRecorder.label(frequencyHz: $0.frequencyHz, mode: $0.mode) } ?? ""
        startTask = Task { [weak self] in
            guard let self else { return }
            let started = await pageBridge.start(fallbackLabel: label)
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
            // The rig hasn't caught up with a tune sent from the Kiwi yet:
            // following its old value would undo the user's click.
            if let pending = pendingRigTune {
                let caughtUp = abs(hz - pending.frequencyHz) <= Self.sameFrequencyToleranceHz
                    && (pending.mode == nil || latest.mode == pending.mode)
                guard caughtUp || Date() >= pending.until else { return }
                pendingRigTune = nil
            }
            let description = KiwiSDRURLBuilder.kHzString(hz) + " kHz " + (token?.uppercased() ?? "")
            lastTunedDescription = description.trimmingCharacters(in: .whitespaces)
            // Status is refreshed even when the URL is unchanged (e.g. back
            // in range at the same frequency), so it never goes stale.
            if !forceHostPage, tuneURL != lastIssuedURL, kiwiAlreadyAt(hz, modeToken: token) {
                lastIssuedURL = tuneURL
                tunedTarget = latest
                lastTunedAt = Date()
            } else if forceHostPage || tuneURL != lastIssuedURL {
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

    /// Adds the Kiwi's own `mute=1` when muted here, so a reload comes up
    /// muted. Kept out of `lastIssuedURL`, which dedups on the tuning alone
    /// — toggling Mute must not trigger a reload.
    private func withMuteParameter(_ url: URL) -> URL {
        guard isMuted, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "mute", value: "1")]
        return components.url ?? url
    }

    /// Loads `newURL` — unless a recording is running on the current page,
    /// in which case that file is saved first (a reload would lose it) and
    /// the load follows; `pageDidLoad` then starts the next file.
    private func issue(_ newURL: URL, tuned: FollowTarget? = nil) {
        stopTuningPoll()
        lastIssuedURL = newURL
        let request = PageRequest(url: withMuteParameter(newURL),
                                  id: (pendingReload?.request.id ?? pageRequest?.id ?? 0) + 1)
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
            let url = await self?.pageBridge.stop()
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

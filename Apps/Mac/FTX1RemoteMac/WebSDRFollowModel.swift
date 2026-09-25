import Combine
import FTX1Core
import Foundation
import SwiftUI  // IndexSet-based move for the Manage Favorites list

/// Persisted settings for the WebSDR window, `UserDefaults`-backed like
/// `APRSSettings`/`WPSDSettings`. One current host (picked from the
/// directory or Favorites, or typed), plus the Favorites list itself.
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
    /// The station last picked from the directory or Favorites, as a JSON
    /// `WebSDRFavorite` (host, name, location, ranges). Replaces the two
    /// keys above, which are only read once to migrate.
    static let pickedStationKey = "webSDR.pickedStation"
    /// JSON `[WebSDRFavorite]`, in the user's order.
    static let favoritesKey = "webSDR.favorites"
}

/// Drives the WebSDR window: follows the rig's Main VFO frequency/mode and
/// publishes the page `KiwiWebView` should show — a KiwiSDR, or a classic
/// WebSDR (`SDRPlatform`). A Kiwi is retuned by loading a new `?f=` URL; a
/// WebSDR is loaded once per connection and then retuned in place through
/// its own `setfreqtune()` (`retuneInPlace`), with no reload or reconnect.
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
/// (`SDRPageBridge.readTuning`); a change the user makes in the page —
/// clicking the waterfall, typing a frequency, a mode button — is sent to
/// the rig once it has held still for one poll. The rig's echo of that
/// change must not reload the Kiwi: `evaluate` skips the reload while the
/// Kiwi is already where the rig is, and holds off while the rig hasn't
/// caught up yet (`pendingRigTune`), since a poll cycle can still report
/// the old frequency after the set went out.
///
/// v1.1 seams, deliberately not built: mute-on-TX (observe `rigState.ptt` here),
/// following Sub (`secondaryFrequencyHz`/`secondaryMode`), and further
/// platforms such as OpenWebRX (another `SDRPlatform` case with its own URL
/// builder and page-bridge JS).
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

    /// The station last picked from the directory or Favorites. Its ranges
    /// drive the retune range check while its host is the current one (else
    /// KiwiSDR's 0–30 MHz), and its name/location/ranges are what a star
    /// press saves for that host.
    private var pickedStation: WebSDRFavorite? {
        didSet {
            let data = pickedStation.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: WebSDRSettings.pickedStationKey)
        }
    }

    /// `pickedStation`, while its host is still the current one.
    private var currentStation: WebSDRFavorite? {
        guard let pickedStation, pickedStation.id == WebSDRFavorite.key(hostPort) else { return nil }
        return pickedStation
    }

    /// The current host's platform. A host with no known platform (typed by
    /// hand, not yet loaded) is treated as a Kiwi; `pageDidLoad` records
    /// what the page turns out to be.
    var currentPlatform: SDRPlatform {
        currentStation?.platform ?? .kiwiSDR
    }

    /// The range check for retunes: the station's own ranges when known,
    /// else KiwiSDR's 0–30 MHz for a Kiwi and no check for a WebSDR (its
    /// ranges are read from its page on the first connect).
    var activeBands: [ClosedRange<Int>]? {
        if let bands = currentStation?.bandRanges { return bands }
        return currentPlatform == .kiwiSDR ? KiwiSDRURLBuilder.defaultBands : nil
    }

    /// Saved stations, in the user's order. Small (a handful of hosts), so
    /// `UserDefaults` rather than a file like the directory cache.
    @Published private(set) var favorites: [WebSDRFavorite] {
        didSet {
            if let data = try? JSONEncoder().encode(favorites) {
                UserDefaults.standard.set(data, forKey: WebSDRSettings.favoritesKey)
            }
        }
    }

    /// The rig frequency the window is following (after the debounce), for
    /// the directory's "covers rig frequency" filter. nil before the first
    /// rig value, or 0 while the rig isn't connected.
    @Published private(set) var rigFrequencyHz: Int?

    /// Whether the window should hold a live receiver session. Starts false on
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

    /// Click-to-tune: tuning in the page tunes the rig's Main VFO (and its
    /// mode, where the two map — see `SDRPlatform.rigMode`).
    /// Independent of `followRig`.
    @Published var tuneRig: Bool {
        didSet { UserDefaults.standard.set(tuneRig, forKey: WebSDRSettings.tuneRigKey) }
    }

    /// One page load for `KiwiWebView`. `id` distinguishes a deliberate
    /// reload of the same URL (Return in the host field, e.g. to retry after
    /// an error) from a repeat that should be ignored.
    struct PageRequest: Equatable {
        let url: URL
        /// What the page is expected to be (corrected on load if wrong).
        let platform: SDRPlatform
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
    /// mute it made itself). Applied to the page live via `SDRPageBridge.
    /// setPageMuted` — and on every Kiwi load as the Kiwi's own `mute=1` URL
    /// parameter, so it survives the reload each retune causes; a WebSDR
    /// has no such parameter, so `pageDidLoad` asserts it instead.
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

    // MARK: Recording (the page's own recorder — see SDRPageBridge)

    let pageBridge = SDRPageBridge()

    /// The user's Record/Stop intent. Stays true across retunes: each
    /// retune saves the current file and starts a new one for the new
    /// frequency once the reloaded (Kiwi) or retuned (WebSDR) page's audio
    /// is running (user decision: one file per frequency, not paused
    /// following).
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
        favorites = defaults.data(forKey: WebSDRSettings.favoritesKey)
            .flatMap { try? JSONDecoder().decode([WebSDRFavorite].self, from: $0) } ?? []
        if let data = defaults.data(forKey: WebSDRSettings.pickedStationKey) {
            pickedStation = try? JSONDecoder().decode(WebSDRFavorite.self, from: data)
        } else if let host = defaults.string(forKey: WebSDRSettings.stationBandsHostKey),
                  let raw = defaults.string(forKey: WebSDRSettings.stationBandsKey) {
            // Pre-favorites settings: only the host and its ranges were kept.
            // (`didSet` doesn't fire in init, so this isn't re-saved until
            // the next pick — harmless, it migrates again next launch.)
            pickedStation = WebSDRFavorite(hostPort: host, name: host,
                                           bands: KiwiSDRStation.parseBands(raw))
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

    /// Opens (or, if already connected, reloads) the receiver session. Before
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
        select(WebSDRFavorite(station: station))
    }

    /// Picks a favorite — same rules as a directory pick. A favorite with no
    /// saved ranges (added from a typed host) uses 0–30 MHz.
    func select(_ favorite: WebSDRFavorite) {
        if isConnected, favorite.id != WebSDRFavorite.key(hostPort) { disconnect() }
        pickedStation = favorite
        hostPort = favorite.hostPort
        evaluate()
    }

    /// A station clicked in the Stations sheet's websdr.org tab. Reuses
    /// what's already known about that host (a favorite, or the current
    /// pick — its ranges and title are learned on the first connect) rather
    /// than starting over from the bare host.
    func selectWebSDR(hostPort: String) {
        let key = WebSDRFavorite.key(hostPort)
        var station = favorites.first { $0.id == key }
            ?? (pickedStation?.id == key ? pickedStation : nil)
            ?? WebSDRFavorite(hostPort: hostPort, name: hostPort)
        station.platform = .webSDR
        select(station)
    }

    /// Records what the loaded page turned out to be (and, for a WebSDR, its
    /// ranges and title) on the current pick and on a matching favorite, so
    /// the next load uses the right URL form and range check. A name the
    /// user or the directory gave is kept; only a bare-host name is
    /// replaced by the page title.
    private func learnStation(platform: SDRPlatform, bands: [ClosedRange<Int>]?, title: String?) {
        let host = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        func learned(_ station: WebSDRFavorite) -> WebSDRFavorite {
            var station = station
            station.platform = platform
            if let bands { station.bands = WebSDRFavorite.encode(bands) }
            if let title, !title.isEmpty, station.name == station.hostPort { station.name = title }
            return station
        }
        let updated = learned(currentStation ?? WebSDRFavorite(hostPort: host, name: host))
        if updated != pickedStation { pickedStation = updated }
        if let index = favorites.firstIndex(where: { $0.id == updated.id }) {
            let favorite = learned(favorites[index])
            if favorite != favorites[index] { favorites[index] = favorite }
        }
    }

    // MARK: Favorites

    func isFavorite(hostPort: String) -> Bool {
        let key = WebSDRFavorite.key(hostPort)
        return favorites.contains { $0.id == key }
    }

    /// The star next to the host field: saves the current host — with the
    /// picked station's name/location/ranges if that's where it came from,
    /// else the directory's entry for a typed host that happens to be listed
    /// (`directoryStations` is empty until the Stations sheet has loaded
    /// once; `fillInFavorites` catches up then) — or removes it if it's
    /// already a favorite.
    func toggleFavoriteForCurrentHost(directoryStations: [KiwiSDRStation]) {
        let host = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        if isFavorite(hostPort: host) {
            removeFavorite(hostPort: host)
        } else {
            let key = WebSDRFavorite.key(host)
            let listed = directoryStations.first { WebSDRFavorite.key($0.hostPort) == key }
            favorites.append(listed.map(WebSDRFavorite.init(station:))
                             ?? currentStation
                             ?? WebSDRFavorite(hostPort: host, name: host))
        }
    }

    /// Gives favorites saved from a typed host (named after the host, no
    /// location/ranges) the directory's details once it's loaded. A name the
    /// user has changed is kept.
    func fillInFavorites(from stations: [KiwiSDRStation]) {
        let byKey = Dictionary(stations.map { (WebSDRFavorite.key($0.hostPort), $0) },
                               uniquingKeysWith: { first, _ in first })
        var updated = favorites
        for i in updated.indices {
            guard let station = byKey[updated[i].id] else { continue }
            if updated[i].name == updated[i].hostPort { updated[i].name = station.name }
            if updated[i].location.isEmpty { updated[i].location = station.location }
            if updated[i].bands == nil || updated[i].bands == WebSDRFavorite.encode(KiwiSDRURLBuilder.defaultBands) {
                updated[i].bands = WebSDRFavorite.encode(station.bands)
            }
            if updated[i].platform == nil { updated[i].platform = .kiwiSDR }
        }
        if updated != favorites { favorites = updated }
    }

    /// The Stations sheet's star column.
    func toggleFavorite(_ station: KiwiSDRStation) {
        if isFavorite(hostPort: station.hostPort) {
            removeFavorite(hostPort: station.hostPort)
        } else {
            favorites.append(WebSDRFavorite(station: station))
        }
    }

    func removeFavorite(hostPort: String) {
        let key = WebSDRFavorite.key(hostPort)
        favorites.removeAll { $0.id == key }
    }

    func moveFavorites(fromOffsets source: IndexSet, toOffset destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
    }

    /// Blank names fall back to the host rather than leaving an empty menu item.
    func renameFavorite(id: WebSDRFavorite.ID, to name: String) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index].name = trimmed.isEmpty ? favorites[index].hostPort : trimmed
        if pickedStation?.id == id { pickedStation?.name = favorites[index].name }
    }

    /// Ends the receiver session: `KiwiWebView` navigates to about:blank
    /// when `pageRequest` goes nil, which unloads the page and closes its
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
        pendingInPlace = nil
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
        loadTask?.cancel()
        loadTask = nil
        loadedPlatform = nil
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

    /// The platform of the page on screen, once it has loaded and been
    /// checked (`SDRPageBridge.detectPlatform`); nil while none is, or one
    /// is still loading. Only a loaded WebSDR page is retuned in place.
    private var loadedPlatform: SDRPlatform?
    private var loadTask: Task<Void, Never>?

    /// `KiwiWebView` finished loading a receiver page: check what it is
    /// (a typed host was loaded as a Kiwi, which may be wrong) and record
    /// that, apply Mute to a WebSDR (it has no URL parameter for it), and if
    /// a recording spans the reload (a retune), start the next file. A host
    /// that turned out to be a WebSDR is then retuned in place to the rig,
    /// since the `?f=` it was loaded with means nothing to it.
    func pageDidLoad() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let expected = pageBridge.platform
            let detected = await pageBridge.detectPlatform()
            guard !Task.isCancelled, isConnected else { return }
            let platform = detected ?? expected
            loadedPlatform = platform
            if detected != nil {
                let bands = await pageBridge.readBands()
                let title = platform == .webSDR ? await pageBridge.pageTitle() : nil
                guard !Task.isCancelled else { return }
                learnStation(platform: platform, bands: bands, title: title)
            }
            startTuningPoll()
            if platform == .webSDR, isMuted {
                muteTask?.cancel()
                muteTask = Task { [weak self] in await self?.pageBridge.setPageMuted(true) }
            }
            if isRecording, reloadTask == nil { startSegment() }
            if platform != expected {
                lastIssuedURL = nil
                evaluate()
            }
        }
    }

    // MARK: Click-to-tune (Kiwi → rig)

    private struct PageTuning: Equatable {
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
    private var pageTuning: PageTuning?
    /// The tuning already acted on (or the page's initial tuning), so each
    /// change is sent to the rig once.
    private var handledPageTuning: PageTuning?
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
                if let reading { pageTuningRead(PageTuning(frequencyHz: reading.frequencyHz, mode: reading.mode)) }
                try? await Task.sleep(for: Self.tuningPollInterval)
            }
        }
    }

    private func stopTuningPoll() {
        tuningPollTask?.cancel()
        tuningPollTask = nil
        pageTuning = nil
        handledPageTuning = nil
    }

    private func pageTuningRead(_ reading: PageTuning) {
        // The page's first settled tuning is where it was loaded to (the
        // rig's frequency, or the Kiwi's own last one for a bare host
        // page) — never something the user did, so never sent to the rig.
        guard pageTuning != nil else {
            pageTuning = reading
            handledPageTuning = reading
            return
        }
        // Wait for the tuning to hold still for a poll, so a drag or a
        // spun mouse wheel sends where it stopped, not every step on the way.
        guard reading == pageTuning else {
            pageTuning = reading
            return
        }
        guard reading != handledPageTuning else { return }
        handledPageTuning = reading
        tuneRigFromPage(reading)
    }

    private func tuneRigFromPage(_ reading: PageTuning) {
        guard tuneRig, let hub else { return }
        let rig = hub.rigState
        let frequencyChanged = abs(reading.frequencyHz - rig.frequencyHz) > Self.sameFrequencyToleranceHz
        let newMode = pageBridge.platform.rigMode(forPageMode: reading.mode, current: rig.mode)
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
        status = "Tuned the rig to \(description) from the \(pageBridge.platform.displayName) at "
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
    private func pageAlreadyAt(_ hz: Int, modeToken token: String?) -> Bool {
        guard let pageTuning,
              abs(pageTuning.frequencyHz - hz) <= Self.sameFrequencyToleranceHz
        else { return false }
        // A page mode with no rig equivalent (Kiwi IQ/DRM) was picked in the
        // page on purpose; reloading to the rig's mode after every click
        // would keep undoing it.
        guard token != nil, let family = pageBridge.platform.modeFamily(ofPageMode: pageTuning.mode) else { return true }
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
                recordingNote = "Recording didn't start — the \(pageBridge.platform.displayName)'s audio isn't running."
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
                ? "Enter a KiwiSDR or WebSDR host:port and press Return."
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

        switch currentPlatform.retune(hostPort: hostPort, frequencyHz: latest.frequencyHz, mode: latest.mode,
                                      bands: activeBands) {
        case let .tune(tuneURL, hz, token):
            // The rig hasn't caught up with a tune sent from the page yet:
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
            if !forceHostPage, tuneURL != lastIssuedURL, pageAlreadyAt(hz, modeToken: token) {
                lastIssuedURL = tuneURL
                tunedTarget = latest
                lastTunedAt = Date()
            } else if forceHostPage || tuneURL != lastIssuedURL {
                issue(tuneURL, tuned: latest,
                      inPlace: forceHostPage ? nil : WebSDRURLBuilder.tuneValue(frequencyHz: hz, modeToken: token))
                lastTunedAt = Date()
            }
            let time = lastTunedAt.formatted(date: .omitted, time: .standard)
            status = token == nil
                ? "Tuned to \(lastTunedDescription!) at \(time) (mode unchanged — \(latest.mode.displayName) has no \(currentPlatform.displayName) equivalent)"
                : "Tuned to \(lastTunedDescription!) at \(time)"
        case let .outOfRange(hz, bands):
            if forceHostPage { issue(base) }
            let range = bands.map(KiwiSDRStation.describe).joined(separator: ", ")
            status = String(format: "Not retuned: %.3f MHz is outside this ", Double(hz) / 1_000_000)
                + currentPlatform.displayName + "'s range (" + range + ")"
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
        guard isMuted, currentPlatform == .kiwiSDR,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "mute", value: "1")]
        return components.url ?? url
    }

    /// Loads `newURL` — unless a recording is running on the current page,
    /// in which case that file is saved first (a reload would lose it) and
    /// the load follows; `pageDidLoad` then starts the next file.
    ///
    /// `inPlace`: the `setfreqtune()` value for the same tuning. Used
    /// instead of a load when the page on screen is a loaded WebSDR.
    private func issue(_ newURL: URL, tuned: FollowTarget? = nil, inPlace: String? = nil) {
        if let inPlace, let tuned, loadedPlatform == .webSDR, pageRequest != nil, reloadTask == nil {
            retuneInPlace(newURL, value: inPlace, tuned: tuned)
            return
        }
        stopTuningPoll()
        loadTask?.cancel()
        loadTask = nil
        loadedPlatform = nil
        pendingInPlace = nil
        lastIssuedURL = newURL
        let request = PageRequest(url: withMuteParameter(newURL), platform: currentPlatform,
                                  id: (pendingReload?.request.id ?? pageRequest?.id ?? 0) + 1)
        guard isRecording, pageRequest != nil else {
            tunedTarget = tuned
            pageBridge.platform = request.platform
            pageRequest = request
            return
        }
        // The bridge keeps the old page's platform until the new page is
        // requested: the stop below is still the old page's recorder.
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
            pageBridge.platform = next.request.platform
            pageRequest = next.request
        }
    }

    // MARK: In-place retune (WebSDR)

    /// The newest WebSDR retune waiting its turn; only the newest survives
    /// if the rig moves again while a recording is being saved.
    private var pendingInPlace: (value: String, tuned: FollowTarget)?
    private var inPlaceTask: Task<Void, Never>?

    /// Retunes the loaded WebSDR page through its own `setfreqtune()` — no
    /// reload. While recording, the current file is saved first and a new
    /// one started afterwards (one file per frequency, same as a Kiwi
    /// retune). The click-to-tune baseline is reset so the page reporting
    /// its new frequency isn't taken for the user tuning it.
    private func retuneInPlace(_ url: URL, value: String, tuned: FollowTarget) {
        lastIssuedURL = url
        pendingInPlace = (value, tuned)
        guard inPlaceTask == nil else { return }
        inPlaceTask = Task { [weak self] in
            guard let self else { return }
            while let next = pendingInPlace {
                pendingInPlace = nil
                if isRecording {
                    startTask?.cancel()
                    segmentStartedAt = nil
                    noteSaved(await pageBridge.stop())
                }
                guard isConnected, loadedPlatform == .webSDR else { break }
                pageTuning = nil
                handledPageTuning = nil
                await pageBridge.retuneInPlace(next.value)
                tunedTarget = next.tuned
                pageTuning = nil
                handledPageTuning = nil
                if isRecording, pendingInPlace == nil { startSegment() }
            }
            inPlaceTask = nil
        }
    }
}

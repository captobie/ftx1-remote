import Combine
import Foundation
import FTX1Core
import os

/// Tools → Local SDR: native audio from the operator's own KiwiSDR over its
/// sound WebSocket (`KiwiSDRClient`), bypassing the Kiwi's web page (which
/// the WebSDR window embeds). Its own `ObservableObject`, never state on
/// `HubService`, so nothing here re-renders the main window; the S-meter
/// goes to `meter`, observed only by the meter view.
///
/// Explicit connect only: the window opens disconnected, and Disconnect or
/// closing the window closes the socket (the Kiwi frees the channel).
/// Playback goes through an `AudioPlaybackEngine` on Settings → Audio's
/// output device, resampled from the rate the Kiwi reports (~11998.9 Hz,
/// not 12000), squelch off.
///
/// The waterfall (phase 2) is a second stream, `KiwiWaterfallClient`,
/// opened with the sound stream's timestamp once that one is ready (so it
/// takes no channel of its own). Its rows go to `waterfall`, observed only
/// by the waterfall view. A waterfall failure leaves the audio playing; the
/// sound stream ending, Disconnect or closing the window closes both.
/// Tuning inside the visible span never touches the waterfall; tuning near
/// or past an edge pans it (`KiwiWaterfallGeometry.startKeeping`). Not yet:
/// rig following, WebSDR-style automatic muting, decoder sources or
/// recording.
final class LocalSDRModel: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected(sampleRate: Double)
        case failed(KiwiSDRError)
    }

    private enum Keys {
        static let host = "localSDR.host"
        static let frequencyHz = "localSDR.frequencyHz"
        static let mode = "localSDR.mode"
        static let volume = "localSDR.volume"
        static let muted = "localSDR.muted"
        static let waterfallZoom = "localSDR.waterfallZoom"
    }

    enum WaterfallState: Equatable {
        case off
        case connecting
        case running
        case failed(KiwiSDRError)
    }

    /// The waterfall position asked for (start in x_bin units, zoom).
    /// Rows arrive at it ~150 ms later; until then the view draws the
    /// picture offset to it, so a drag follows the mouse at once.
    struct WaterfallView: Equatable {
        var start: Int
        var zoom: Int
    }

    @Published private(set) var state: State = .disconnected
    /// "host" or "host:port" (8073 when absent).
    @Published var hostPort: String {
        didSet { UserDefaults.standard.set(hostPort, forKey: Keys.host) }
    }
    /// The password field. Saved to the keychain only once the Kiwi accepts
    /// it, so trying a wrong one doesn't overwrite the stored password.
    @Published var password: String
    @Published private(set) var frequencyHz: Int
    @Published var mode: KiwiSDRMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            retune()
            keepPassbandVisible()
        }
    }
    @Published var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: Keys.volume)
            applyVolume()
        }
    }
    @Published private(set) var isMuted: Bool

    let meter = LocalSDRMeterStore()
    let waterfall = LocalSDRWaterfallStore()

    @Published private(set) var waterfallState: WaterfallState = .off
    /// nil until the waterfall stream is set up.
    @Published private(set) var waterfallView: WaterfallView?
    /// Remembered across sessions (default 8 = ~117 kHz).
    private var preferredZoom: Int

    private var client: KiwiSDRClient?
    private var eventsTask: Task<Void, Never>?
    private var playback: AudioPlaybackEngine?
    private var connectedHost = ""
    private var passwordInUse = ""
    private var lastMeterPublish = ContinuousClock.now
    private var waterfallClient: KiwiWaterfallClient?
    private var waterfallTask: Task<Void, Never>?
    /// The sound stream's URL timestamp, shared with the waterfall's.
    private var sessionTimestamp = Date()
    private var lastViewSend = ContinuousClock.now - .seconds(1)
    private var trailingViewSend: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.ftx1remote.mac", category: "kiwisdr")

    static let frequencyRange = 10_000...30_000_000

    init() {
        let defaults = UserDefaults.standard
        hostPort = defaults.string(forKey: Keys.host) ?? ""
        let savedFrequency = defaults.integer(forKey: Keys.frequencyHz)
        frequencyHz = Self.frequencyRange.contains(savedFrequency) ? savedFrequency : 14_074_000
        mode = defaults.string(forKey: Keys.mode).flatMap(KiwiSDRMode.init(rawValue:)) ?? .usb
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        isMuted = defaults.bool(forKey: Keys.muted)
        password = LocalSDRPassword.read()
        preferredZoom = defaults.object(forKey: Keys.waterfallZoom) as? Int ?? 8
    }

    var isConnected: Bool {
        switch state {
        case .connecting, .connected: true
        case .disconnected, .failed: false
        }
    }

    var canConnect: Bool { KiwiProtocol.soundURL(hostPort: hostPort) != nil }

    // MARK: - Connection

    func connect() {
        hostPort = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        closeSession()
        guard canConnect else {
            state = .failed(.invalidHost)
            return
        }
        sessionTimestamp = Date()
        let client = KiwiSDRClient(hostPort: hostPort, password: password, identUser: "FTX1Remote",
                                   compression: false, tuning: currentTuning, timestamp: sessionTimestamp,
                                   logSubsystem: "com.ftx1remote.mac")
        self.client = client
        connectedHost = hostPort
        passwordInUse = password
        state = .connecting
        eventsTask = Task { [weak self] in
            await client.start()
            for await event in client.events {
                guard let self, self.client === client else { return }
                self.handle(event)
            }
        }
    }

    func disconnect() {
        closeSession()
        state = .disconnected
    }

    private func closeSession() {
        if let client {
            Task { await client.stop() }
        }
        client = nil
        eventsTask?.cancel()
        eventsTask = nil
        stopWaterfall()
        playback?.stop()
        playback = nil
        meter.reset()
    }

    private func handle(_ event: KiwiSDRClient.Event) {
        switch event {
        case .ready(let sampleRate):
            logger.notice("connected, audio at \(sampleRate, privacy: .public) Hz")
            state = .connected(sampleRate: sampleRate)
            if passwordInUse != LocalSDRPassword.read() {
                LocalSDRPassword.write(passwordInUse)
            }
            startPlayback(sampleRate: sampleRate)
            startWaterfall()
        case .audio(let chunk):
            playback?.push(pcm: Self.littleEndianPCM(chunk.samples))
            let now = ContinuousClock.now
            if now - lastMeterPublish >= .milliseconds(100) {
                lastMeterPublish = now
                meter.update(dBm: chunk.smeterDBm, overload: chunk.flags.contains(.adcOverflow))
            }
        case .closed(let error):
            client = nil
            stopWaterfall()
            playback?.stop()
            playback = nil
            meter.reset()
            state = error.map(State.failed) ?? .disconnected
        }
    }

    private func startPlayback(sampleRate: Double) {
        playback?.stop()
        // A larger warm-up than the relay's 0.12 s: a Kiwi frame is ~43 ms,
        // and the link may cross Tailscale.
        let engine = AudioPlaybackEngine(squelchEnabled: false, inputSampleRate: sampleRate, prebufferSeconds: 0.25)
        engine.setOutputDevice(AudioOutputDeviceLister.deviceID(forUID: AudioOutputSettings.deviceUID))
        engine.start()
        playback = engine
        applyVolume()
    }

    private static func littleEndianPCM(_ samples: [Int16]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in samples.enumerated() { out[i] = sample.littleEndian }
        }
        return data
    }

    // MARK: - Tuning and audio

    private var currentTuning: KiwiTuning { KiwiTuning(dialHz: frequencyHz, mode: mode) }

    /// Clamped to the Kiwi's 0–30 MHz (from 10 kHz).
    func setFrequency(_ hz: Int) {
        let clamped = min(max(hz, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound)
        guard clamped != frequencyHz else { return }
        frequencyHz = clamped
        UserDefaults.standard.set(clamped, forKey: Keys.frequencyHz)
        retune()
        keepPassbandVisible()
    }

    func step(byHz delta: Int) { setFrequency(frequencyHz + delta) }

    /// A click on the waterfall: the dial goes there, snapped to the
    /// mode's step (the dial is the carrier, or the signal in CW).
    func tune(toWaterfallHz hz: Double) {
        let step = Double(mode.waterfallStepHz)
        setFrequency(Int((hz / step).rounded() * step))
    }

    /// One scroll-wheel step up (+1) or down (−1), landing on the step
    /// grid: from an off-grid frequency the first step snaps to it.
    func scrollStep(_ direction: Int) {
        guard direction != 0 else { return }
        let step = mode.waterfallStepHz
        let base = Int((Double(frequencyHz) / Double(step)).rounded(direction > 0 ? .down : .up)) * step
        setFrequency(base + direction * step)
    }

    /// Retunes the open socket ("SET mod=… freq=…"), no reconnect.
    private func retune() {
        guard let client else { return }
        let tuning = currentTuning
        Task { await client.tune(tuning) }
    }

    func toggleMuted() {
        isMuted.toggle()
        UserDefaults.standard.set(isMuted, forKey: Keys.muted)
        applyVolume()
    }

    /// Mute is volume 0, so the player keeps its buffer and unmuting is
    /// immediate.
    private func applyVolume() {
        playback?.volume = isMuted ? 0 : Float(volume)
    }

    var connectedHostPort: String { connectedHost }

    // MARK: - Waterfall

    /// The demodulated passband in absolute Hz.
    var passbandHz: (low: Double, high: Double) {
        let tuning = currentTuning
        let carrier = Double(mode.carrierHz(forDialHz: frequencyHz, lowCut: tuning.lowCut, highCut: tuning.highCut))
        return (carrier + Double(tuning.lowCut), carrier + Double(tuning.highCut))
    }

    private var passbandCentreHz: Double {
        let band = passbandHz
        return (band.low + band.high) / 2
    }

    var canZoomIn: Bool { (waterfallView?.zoom ?? Int.max) < waterfall.geometry.zoomMax }
    var canZoomOut: Bool { (waterfallView?.zoom ?? 0) > 0 }

    private func startWaterfall() {
        stopWaterfall()
        let client = KiwiWaterfallClient(hostPort: connectedHost, password: passwordInUse, identUser: "FTX1Remote",
                                         timestamp: sessionTimestamp, logSubsystem: "com.ftx1remote.mac")
        waterfallClient = client
        waterfallState = .connecting
        waterfall.reset()
        waterfallTask = Task { [weak self] in
            await client.start()
            for await event in client.events {
                guard let self, self.waterfallClient === client else { return }
                self.handle(event)
            }
        }
    }

    private func stopWaterfall() {
        if let waterfallClient {
            Task { await waterfallClient.stop() }
        }
        waterfallClient = nil
        waterfallTask?.cancel()
        waterfallTask = nil
        trailingViewSend?.cancel()
        trailingViewSend = nil
        waterfallView = nil
        waterfallState = .off
        waterfall.reset()
    }

    private func handle(_ event: KiwiWaterfallClient.Event) {
        switch event {
        case .ready(let geometry, let cal):
            logger.notice("waterfall running")
            waterfall.configure(geometry: geometry, cal: cal)
            waterfallState = .running
            let zoom = geometry.clampZoom(preferredZoom)
            requestView(WaterfallView(start: geometry.start(centredOn: passbandCentreHz, zoom: zoom), zoom: zoom))
        case .row(let row):
            waterfall.add(row)
        case .closed(let error):
            // The audio carries on: only the waterfall stopped.
            waterfallClient = nil
            waterfallView = nil
            trailingViewSend?.cancel()
            trailingViewSend = nil
            waterfallState = error.map(WaterfallState.failed) ?? .off
        }
    }

    /// Pans only when the passband is near or past an edge of the span.
    private func keepPassbandVisible() {
        guard let view = waterfallView else { return }
        let band = passbandHz
        if let start = waterfall.geometry.startKeeping(lowHz: band.low, highHz: band.high,
                                                       start: view.start, zoom: view.zoom) {
            requestView(WaterfallView(start: start, zoom: view.zoom))
        }
    }

    /// Zooms one step, centred on the passband (the Kiwi page's rule),
    /// or on the middle of the span when the passband is out of view.
    func zoom(by delta: Int) {
        guard let view = waterfallView else { return }
        let geometry = waterfall.geometry
        let zoom = geometry.clampZoom(view.zoom + delta)
        guard zoom != view.zoom else { return }
        let band = passbandHz
        let visible = geometry.startKeeping(lowHz: band.low, highHz: band.high, start: view.start,
                                            zoom: view.zoom, marginFraction: 0) == nil
        let centre = visible
            ? passbandCentreHz
            : geometry.hz(column: Double(geometry.fftSize) / 2, start: view.start, zoom: view.zoom)
        preferredZoom = zoom
        UserDefaults.standard.set(zoom, forKey: Keys.waterfallZoom)
        requestView(WaterfallView(start: geometry.start(centredOn: centre, zoom: zoom), zoom: zoom))
    }

    /// A drag: the new left edge (clamped to the band and a whole bin).
    func pan(toStart start: Int) {
        guard let view = waterfallView else { return }
        let clamped = waterfall.geometry.clampStart(start, zoom: view.zoom)
        guard clamped != view.start else { return }
        requestView(WaterfallView(start: clamped, zoom: view.zoom))
    }

    /// Publishes the view at once and sends it at most every 60 ms (a
    /// drag asks for one per mouse event), the last one always going out.
    private func requestView(_ view: WaterfallView) {
        waterfallView = view
        guard waterfallClient != nil else { return }
        let interval = Duration.milliseconds(60)
        let elapsed = ContinuousClock.now - lastViewSend
        if elapsed >= interval {
            trailingViewSend?.cancel()
            trailingViewSend = nil
            sendView()
        } else if trailingViewSend == nil {
            trailingViewSend = Task { [weak self] in
                try? await Task.sleep(for: interval - elapsed)
                guard !Task.isCancelled, let self else { return }
                self.trailingViewSend = nil
                self.sendView()
            }
        }
    }

    private func sendView() {
        guard let client = waterfallClient, let view = waterfallView else { return }
        lastViewSend = .now
        Task { await client.setView(zoom: view.zoom, start: view.start) }
    }
}

extension KiwiSDRMode {
    /// The waterfall's click snap and scroll step.
    var waterfallStepHz: Int {
        switch self {
        case .cw: 10
        case .usb, .lsb: 100
        case .am: 1_000
        case .fm: 5_000
        }
    }
}

/// The S-meter, ~10 updates a second while connected — observed only by
/// `LocalSDRMeterView`.
final class LocalSDRMeterStore: ObservableObject {
    @Published private(set) var dBm: Double?
    @Published private(set) var overload = false

    func update(dBm: Double, overload: Bool) {
        self.dBm = dBm
        if self.overload != overload { self.overload = overload }
    }

    func reset() {
        dBm = nil
        overload = false
    }
}

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
/// or past an edge pans it (`KiwiWaterfallGeometry.startKeeping`).
///
/// Rig link (phase 3), the WebSDR window's rules on the open socket
/// (`KiwiRigLink` holds the pure part): Follow tunes the Kiwi to the rig's
/// MAIN frequency/mode from `hub.$rigState` (removeDuplicates + 400 ms
/// debounce, as `WebSDRFollowModel`) with one "SET mod=… freq=…", no
/// reconnect; Tune rig sends the window's own tunes to the rig through
/// `HubService.send(_:)` (at most every 100 ms, the last always going out,
/// so a spun scroll wheel doesn't flood the command queue). Both only
/// while connected, subscribed on connect and cancelled on disconnect.
/// Mute on TX silences the playback while `rigState.ptt`; while the Kiwi
/// is audible the rig's Main playback is muted
/// (`HubService.setMainAudioOverride(.localSDR, …)`).
///
/// Decoders and recording (phase 4): every frame, as decoded and before
/// the volume/mute, goes to `HubService.localSDRSource` while a CW or
/// RTTY/PSK window has MyKiwiSDR selected (so a muted Kiwi still
/// decodes), and to the recording's `SDRAudioFileWriter` while Record is
/// on — 16-bit mono WAV at the Kiwi's rate, one file per frequency
/// (`KiwiRecordingSplit`: a retune of 500 Hz or more, or a mode change,
/// that holds for 1 s starts a new file). Disconnect, a dropped connection
/// and closing the window save the file. Not yet: following the rig's
/// filter width.
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
        static let followRig = "localSDR.followRig"
        static let tuneRig = "localSDR.tuneRig"
        static let muteOnTransmit = "localSDR.muteOnTransmit"
    }

    private struct RigTarget: Equatable {
        let frequencyHz: Int
        let mode: RigMode
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

    @Published private(set) var state: State = .disconnected {
        didSet { if state != oldValue { updateMainAudio() } }
    }
    /// "host" or "host:port" (8073 when absent).
    @Published var hostPort: String {
        didSet { UserDefaults.standard.set(hostPort, forKey: Keys.host) }
    }
    /// The password field. Saved to the keychain only once the Kiwi accepts
    /// it, so trying a wrong one doesn't overwrite the stored password.
    @Published var password: String
    @Published private(set) var frequencyHz: Int
    /// Set through `selectMode` (the window) or by Follow.
    @Published private(set) var mode: KiwiSDRMode
    @Published var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: Keys.volume)
            applyVolume()
        }
    }
    @Published private(set) var isMuted: Bool

    /// Rig → Kiwi.
    @Published var followRig: Bool {
        didSet {
            guard followRig != oldValue else { return }
            UserDefaults.standard.set(followRig, forKey: Keys.followRig)
            if followRig, let rigTarget { follow(rigTarget) } else { rigLinkNote = nil }
        }
    }
    /// Kiwi → rig.
    @Published var tuneRig: Bool {
        didSet {
            guard tuneRig != oldValue else { return }
            UserDefaults.standard.set(tuneRig, forKey: Keys.tuneRig)
            if !tuneRig { cancelRigSend(); link.reset(); rigLinkNote = nil }
        }
    }
    /// Silences the playback while the rig transmits; the Mute button and
    /// the rig's own audio are left alone.
    @Published var muteOnTransmit: Bool {
        didSet {
            UserDefaults.standard.set(muteOnTransmit, forKey: Keys.muteOnTransmit)
            applyVolume()
        }
    }
    /// The last refusal or "not following" reason, for the rig-link line.
    @Published private(set) var rigLinkNote: String?

    @Published private(set) var isRecording = false
    /// When the current file started (the Stop button's timer).
    @Published private(set) var segmentStartedAt: Date?
    /// "Saved …" after a file is finished, for the status line.
    @Published private(set) var recordingNote: String?

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

    private weak var hub: HubService?
    private var link = KiwiRigLink()
    private var rigCancellables: Set<AnyCancellable> = []
    /// The rig's last (debounced) MAIN frequency/mode.
    private var rigTarget: RigTarget?
    private var isTransmitting = false
    /// What the throttle will send the rig next (nil = leave that alone).
    private var queuedRigFrequency: Int?
    private var queuedRigMode: RigMode?
    private var lastRigSend = ContinuousClock.now - .seconds(1)
    private var trailingRigSend: Task<Void, Never>?
    private var pendingExpiry: Task<Void, Never>?

    private var recorder: SDRAudioFileWriter?
    private var recordingSplit: KiwiRecordingSplit?
    private var splitCheck: Task<Void, Never>?
    private var audioSampleRate: Double?

    static let frequencyRange = 10_000...30_000_000
    private static let rigSendInterval = Duration.milliseconds(100)

    init(hub: HubService?) {
        self.hub = hub
        let defaults = UserDefaults.standard
        hostPort = defaults.string(forKey: Keys.host) ?? ""
        let savedFrequency = defaults.integer(forKey: Keys.frequencyHz)
        frequencyHz = Self.frequencyRange.contains(savedFrequency) ? savedFrequency : 14_074_000
        mode = defaults.string(forKey: Keys.mode).flatMap(KiwiSDRMode.init(rawValue:)) ?? .usb
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        isMuted = defaults.bool(forKey: Keys.muted)
        password = LocalSDRPassword.read()
        preferredZoom = defaults.object(forKey: Keys.waterfallZoom) as? Int ?? 8
        followRig = defaults.object(forKey: Keys.followRig) as? Bool ?? true
        tuneRig = defaults.object(forKey: Keys.tuneRig) as? Bool ?? true
        muteOnTransmit = defaults.object(forKey: Keys.muteOnTransmit) as? Bool ?? true
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
        // Start where the rig is, so the first tune is already right.
        if followRig, let hub {
            let rig = RigTarget(frequencyHz: hub.rigState.frequencyHz, mode: hub.rigState.mode)
            rigTarget = rig
            if case let .tune(hz, kiwiMode) = link.follow(
                rigFrequencyHz: rig.frequencyHz, rigMode: rig.mode, kiwiFrequencyHz: frequencyHz, kiwiMode: mode,
                maxFrequencyHz: maxFrequencyHz, now: Self.now) {
                applyTuning(frequencyHz: hz, mode: kiwiMode)
            }
        }
        subscribeToRig()
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
        endAudioSession()
        stopRigLink()
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
            audioSampleRate = sampleRate
            hub?.localSDRSource.sessionStarted(sampleRate: sampleRate, mode: mode)
            if passwordInUse != LocalSDRPassword.read() {
                LocalSDRPassword.write(passwordInUse)
            }
            startPlayback(sampleRate: sampleRate)
            startWaterfall()
        case .audio(let chunk):
            let pcm = Self.littleEndianPCM(chunk.samples)
            playback?.push(pcm: pcm)
            // Both before the volume/mute: a muted Kiwi still decodes and records.
            if let recorder, let audioSampleRate {
                recorder.append(pcm: pcm, sampleRate: audioSampleRate)
            }
            if let source = hub?.localSDRSource, source.isWanted {
                source.deliver(chunk.samples)
            }
            let now = ContinuousClock.now
            if now - lastMeterPublish >= .milliseconds(100) {
                lastMeterPublish = now
                meter.update(dBm: chunk.smeterDBm, overload: chunk.flags.contains(.adcOverflow))
            }
        case .closed(let error):
            client = nil
            endAudioSession()
            stopRigLink()
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

    /// The Kiwi's reported bandwidth (30 MHz until the waterfall says).
    var maxFrequencyHz: Int {
        Int(waterfall.geometry.bandwidthHz)
    }

    /// A frequency the window tuned to (entry, steppers). Clamped to the
    /// Kiwi's range (from 10 kHz).
    func setFrequency(_ hz: Int) {
        let clamped = min(max(hz, Self.frequencyRange.lowerBound), maxFrequencyHz)
        guard clamped != frequencyHz else { return }
        applyTuning(frequencyHz: clamped, mode: nil)
        windowTuned()
    }

    /// The window's mode picker.
    func selectMode(_ newMode: KiwiSDRMode) {
        guard newMode != mode else { return }
        applyTuning(frequencyHz: nil, mode: newMode)
        windowTuned()
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

    /// Changes the Kiwi's tuning (nil = keep) and sends it on the open
    /// socket, panning the waterfall only if the passband nears an edge.
    /// Doesn't touch the rig: `windowTuned` does that for the window's own
    /// tunes, and Follow's must not echo back.
    private func applyTuning(frequencyHz newFrequency: Int?, mode newMode: KiwiSDRMode?) {
        var changed = false
        if let newFrequency, newFrequency != frequencyHz {
            frequencyHz = newFrequency
            UserDefaults.standard.set(newFrequency, forKey: Keys.frequencyHz)
            changed = true
        }
        if let newMode, newMode != mode {
            mode = newMode
            UserDefaults.standard.set(newMode.rawValue, forKey: Keys.mode)
            changed = true
        }
        guard changed else { return }
        retune()
        keepPassbandVisible()
        hub?.localSDRSource.modeChanged(mode)
        checkRecordingSplit()
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
    /// immediate. Mute on TX the same way, without touching `isMuted`.
    private func applyVolume() {
        let silent = isMuted || (muteOnTransmit && isTransmitting)
        playback?.volume = silent ? 0 : Float(volume)
        updateMainAudio()
    }

    /// While the Kiwi is audible (connected, not muted here), the rig's Main
    /// Mac playback is muted, and given back once it isn't.
    private func updateMainAudio() {
        guard let hub else { return }
        var audible = false
        if case .connected = state { audible = !isMuted }
        hub.setMainAudioOverride(.localSDR, active: audible)
    }

    // MARK: - Recording

    /// Record while connected; Stop saves the file.
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            guard case .connected = state else { return }
            isRecording = true
            recordingNote = nil
            beginFile()
        }
    }

    private var splitTuning: KiwiRecordingSplit.Tuning {
        KiwiRecordingSplit.Tuning(frequencyHz: frequencyHz, mode: mode)
    }

    private func beginFile() {
        recordingSplit = KiwiRecordingSplit(fileTuning: splitTuning)
        let label = "\(AudioRecorder.label(frequencyHz: frequencyHz, modeName: mode.label)) MyKiwiSDR"
        let date = Date()
        var url = AudioRecorder.newRecordingURL(label: label, date: date)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = AudioRecorder.newRecordingURL(label: "\(label) \(n)", date: date)
            n += 1
        }
        recorder = SDRAudioFileWriter(url: url)
        segmentStartedAt = date
        logger.notice("recording to \(url.lastPathComponent, privacy: .public)")
    }

    /// Closes the current file once everything handed over is written.
    private func finishFile() {
        guard let recorder else { return }
        self.recorder = nil
        Task { [weak self] in
            let url = await recorder.finish()
            guard let self else { return }
            if let url {
                logger.notice("saved \(url.lastPathComponent, privacy: .public)")
                recordingNote = String(localized: "localSDR.recording.saved \(url.deletingPathExtension().lastPathComponent)")
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        finishFile()
        isRecording = false
        segmentStartedAt = nil
        recordingSplit = nil
        splitCheck?.cancel()
        splitCheck = nil
    }

    /// After every tune, and again when a pending split has had time to
    /// settle: starts a new file once a retune has held.
    private func checkRecordingSplit() {
        guard isRecording, var split = recordingSplit else { return }
        splitCheck?.cancel()
        splitCheck = nil
        if let tuning = split.update(tuning: splitTuning, now: Self.now) {
            logger.notice("recording: retuned to \(tuning.frequencyHz) Hz \(tuning.mode.label, privacy: .public), new file")
            finishFile()
            beginFile()
            return
        }
        recordingSplit = split
        guard let next = split.nextCheck else { return }
        splitCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next - Self.now) + 0.02))
            guard !Task.isCancelled, let self else { return }
            splitCheck = nil
            checkRecordingSplit()
        }
    }

    /// The Kiwi's audio stopped (Disconnect, a dropped connection, the
    /// window closing): the recording is saved and the decoders told.
    private func endAudioSession() {
        stopRecording()
        audioSampleRate = nil
        hub?.localSDRSource.sessionEnded()
    }

    // MARK: - Rig link

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func stopRigLink() {
        rigCancellables.removeAll()
        rigTarget = nil
        isTransmitting = false
        cancelRigSend()
        pendingExpiry?.cancel()
        pendingExpiry = nil
        link.reset()
        rigLinkNote = nil
        applyVolume()
    }

    private func subscribeToRig() {
        rigCancellables.removeAll()
        guard let hub else { return }
        hub.$rigState
            .map { RigTarget(frequencyHz: $0.frequencyHz, mode: $0.mode) }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] target in
                guard let self else { return }
                rigTarget = target
                follow(target)
            }
            .store(in: &rigCancellables)
        // Not debounced: the playback should go quiet as soon as the rig is
        // seen transmitting.
        hub.$rigState
            .map(\.ptt)
            .removeDuplicates()
            .sink { [weak self] ptt in
                guard let self, isTransmitting != ptt else { return }
                isTransmitting = ptt
                logger.debug("rig link: PTT \(ptt ? "on" : "off", privacy: .public), playback \(self.muteOnTransmit && ptt ? "silenced" : "as set", privacy: .public)")
                applyVolume()
            }
            .store(in: &rigCancellables)
    }

    private func follow(_ target: RigTarget) {
        guard followRig, isConnected else { return }
        switch link.follow(rigFrequencyHz: target.frequencyHz, rigMode: target.mode, kiwiFrequencyHz: frequencyHz,
                           kiwiMode: mode, maxFrequencyHz: maxFrequencyHz, now: Self.now) {
        case let .tune(hz, kiwiMode):
            logger.debug("rig link: follow → Kiwi \(hz) Hz \(kiwiMode?.label ?? "-", privacy: .public)")
            if rigLinkNote != nil { rigLinkNote = nil }
            applyTuning(frequencyHz: hz, mode: kiwiMode)
        case .alreadyThere:
            if rigLinkNote != nil { rigLinkNote = nil }
        case .outOfRange(let hz):
            rigLinkNote = String(localized: "localSDR.rigLink.outOfRange \(FrequencyFormat.mhz(hz, fractionDigits: 3)) \(FrequencyFormat.mhz(maxFrequencyHz, fractionDigits: 0))")
        case .waitingForRig:
            logger.debug("rig link: ignored rig \(target.frequencyHz) Hz while it catches up")
        case .noRigFrequency:
            break
        }
    }

    private var rigSnapshot: KiwiRigSnapshot? {
        guard let hub else { return nil }
        let rig = hub.rigState
        return KiwiRigSnapshot(connected: hub.connectionState == .connected, transmitting: rig.ptt,
                               memoryMode: rig.vfoMemoryMode == .memory, frequencyHz: rig.frequencyHz,
                               mode: rig.mode)
    }

    /// A tune made in the window: to the rig too, if Tune rig is on.
    private func windowTuned() {
        guard tuneRig, isConnected, let rig = rigSnapshot else { return }
        switch link.windowTuned(kiwiFrequencyHz: frequencyHz, kiwiMode: mode, rig: rig, now: Self.now) {
        case let .send(hz, rigMode):
            if let hz { queuedRigFrequency = hz }
            if let rigMode { queuedRigMode = rigMode }
            scheduleRigSend()
            schedulePendingExpiry()
        case .refused(let refusal):
            noteRefusal(refusal)
        case .nothing:
            break
        }
    }

    private func noteRefusal(_ refusal: KiwiRigLink.Refusal) {
        let time = Date().formatted(date: .omitted, time: .standard)
        let reason = switch refusal {
        case .rigDisconnected: String(localized: "localSDR.rigLink.refused.disconnected")
        case .noRigFrequency: String(localized: "localSDR.rigLink.refused.noFrequency")
        case .transmitting: String(localized: "localSDR.rigLink.refused.transmitting")
        case .memoryMode: String(localized: "localSDR.rigLink.refused.memory")
        }
        rigLinkNote = String(localized: "localSDR.rigLink.refused \(reason) \(time)")
    }

    /// At most one rig tune every 100 ms, the last always going out.
    private func scheduleRigSend() {
        let elapsed = ContinuousClock.now - lastRigSend
        if elapsed >= Self.rigSendInterval {
            trailingRigSend?.cancel()
            trailingRigSend = nil
            sendQueuedRigTune()
        } else if trailingRigSend == nil {
            trailingRigSend = Task { [weak self] in
                try? await Task.sleep(for: Self.rigSendInterval - elapsed)
                guard !Task.isCancelled, let self else { return }
                trailingRigSend = nil
                sendQueuedRigTune()
            }
        }
    }

    private func sendQueuedRigTune() {
        let hz = queuedRigFrequency, rigMode = queuedRigMode
        queuedRigFrequency = nil
        queuedRigMode = nil
        guard hz != nil || rigMode != nil, let hub, let rig = rigSnapshot else { return }
        // The rig may have started transmitting (etc.) since the tune.
        if let refusal = KiwiRigLink.refusal(for: rig) {
            link.reset()
            noteRefusal(refusal)
            return
        }
        lastRigSend = .now
        logger.debug("rig link: Kiwi → rig \(hz ?? 0) Hz \(rigMode?.rawValue ?? "-", privacy: .public)")
        if rigLinkNote != nil { rigLinkNote = nil }
        if let hz { hub.send(.setFrequency(hz: hz)) }
        if let rigMode { hub.send(.setMode(rigMode)) }
    }

    private func cancelRigSend() {
        trailingRigSend?.cancel()
        trailingRigSend = nil
        queuedRigFrequency = nil
        queuedRigMode = nil
    }

    /// If the rig never shows the window's tune (rejected, link lost),
    /// follow its actual state again once the grace period is over.
    private func schedulePendingExpiry() {
        pendingExpiry?.cancel()
        pendingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(KiwiRigLink.rigTuneGrace + 0.1))
            guard !Task.isCancelled, let self else { return }
            pendingExpiry = nil
            if link.expirePending(now: Self.now), let rigTarget { follow(rigTarget) }
        }
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

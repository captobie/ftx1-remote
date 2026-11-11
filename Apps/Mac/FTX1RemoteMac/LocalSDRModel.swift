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
/// and closing the window save the file.
///
/// Passband (phase 5): `passband` is the current mode's, each mode's last
/// one remembered (`localSDR.passband.<mode>`); the waterfall drags its
/// edges (`KiwiPassband`) and it goes out with the tuning on the open
/// socket, at most every 50 ms with the last always sent. With Follow on,
/// Follow width replaces it with MAIN's receive filter
/// (`KiwiPassband(rigFilterOf:)`), not saved; turning that off goes back
/// to the mode's saved passband, and a drag or Reset turns it off.
///
/// Receiver controls (phase 5): AGC, blanker and filter
/// (`KiwiReceiverSettings`) are saved one key each and sent again by every
/// new connection's setup; while connected a change goes out at most every
/// 100 ms, and only the group that changed.
///
/// Playback queue (phase 5): `KiwiPlayoutAdjuster` keeps it near 250 ms on
/// the player's copy of the audio only.
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
        static let followRigWidth = "localSDR.followRigWidth"
        static let agc = "localSDR.agc"
        static let manualGain = "localSDR.agc.manualGain"
        static let threshold = "localSDR.agc.threshold"
        static let decay = "localSDR.agc.decay"
        static let noiseBlanker = "localSDR.nb.algorithm"
        static let gate = "localSDR.nb.gate"
        static let blankerThreshold = "localSDR.nb.threshold"
        static let wildThreshold = "localSDR.nb.wildThreshold"
        static let noiseFilter = "localSDR.nr.algorithm"
        static let denoise = "localSDR.nr.denoise"
        static let autonotch = "localSDR.nr.autonotch"
        static func passband(_ mode: KiwiSDRMode) -> String { "localSDR.passband.\(mode.rawValue)" }
    }

    private struct RigTarget: Equatable {
        let frequencyHz: Int
        let mode: RigMode
        /// MAIN's receive filter as a Kiwi passband, nil if unknown.
        let filter: KiwiPassband?

        init(_ rig: RigState) {
            frequencyHz = rig.frequencyHz
            mode = rig.mode
            filter = KiwiPassband(rigFilterOf: rig)
        }
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
    /// Empty until the keychain has answered (`isLoadingPassword`).
    @Published var password = ""
    /// The keychain read is still running (macOS may be showing its prompt).
    @Published private(set) var isLoadingPassword = true
    @Published private(set) var frequencyHz: Int
    /// Set through `selectMode` (the window) or by Follow.
    @Published private(set) var mode: KiwiSDRMode
    /// The current mode's passband.
    @Published private(set) var passband: KiwiPassband
    @Published var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: Keys.volume)
            applyVolume()
        }
    }
    @Published private(set) var isMuted: Bool
    /// AGC, noise blanker and noise filter.
    @Published private(set) var receiver: KiwiReceiverSettings

    /// Rig → Kiwi.
    @Published var followRig: Bool {
        didSet {
            guard followRig != oldValue else { return }
            UserDefaults.standard.set(followRig, forKey: Keys.followRig)
            if followRig, let rigTarget {
                follow(rigTarget)
            } else {
                rigLinkNote = nil
                if !followRig, followRigWidth { restoreSavedPassband() }
            }
        }
    }
    /// With Follow on, the passband follows MAIN's filter. Changed through
    /// `setFollowRigWidth` (the toggle) or by a manual drag.
    @Published private(set) var followRigWidth: Bool {
        didSet { UserDefaults.standard.set(followRigWidth, forKey: Keys.followRigWidth) }
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
    private var lastRetune = ContinuousClock.now - .seconds(1)
    private var trailingRetune: Task<Void, Never>?
    private var trailingReceiverSend: Task<Void, Never>?
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

    private var playoutMonitor = KiwiPlayoutMonitor()
    private var playoutAdjuster: KiwiPlayoutAdjuster?
    private var recorder: SDRAudioFileWriter?
    private var recordingSplit: KiwiRecordingSplit?
    private var splitCheck: Task<Void, Never>?
    private var audioSampleRate: Double?

    static let frequencyRange = 10_000...30_000_000
    private static let rigSendInterval = Duration.milliseconds(100)
    private static let retuneInterval = Duration.milliseconds(50)
    /// How far ahead the playback queue is kept (`KiwiPlayoutAdjuster`).
    private static let playoutTargetSeconds = 0.25

    init(hub: HubService?) {
        self.hub = hub
        let defaults = UserDefaults.standard
        hostPort = defaults.string(forKey: Keys.host) ?? ""
        let savedFrequency = defaults.integer(forKey: Keys.frequencyHz)
        frequencyHz = Self.frequencyRange.contains(savedFrequency) ? savedFrequency : 14_074_000
        let savedMode = defaults.string(forKey: Keys.mode).flatMap(KiwiSDRMode.init(rawValue:)) ?? .usb
        mode = savedMode
        passband = Self.savedPassband(for: savedMode)
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        isMuted = defaults.bool(forKey: Keys.muted)
        receiver = Self.savedReceiver()
        preferredZoom = defaults.object(forKey: Keys.waterfallZoom) as? Int ?? 8
        followRigWidth = defaults.bool(forKey: Keys.followRigWidth)
        followRig = defaults.object(forKey: Keys.followRig) as? Bool ?? true
        tuneRig = defaults.object(forKey: Keys.tuneRig) as? Bool ?? true
        muteOnTransmit = defaults.object(forKey: Keys.muteOnTransmit) as? Bool ?? true
        Task { [weak self] in
            let saved = await Task.detached { LocalSDRPassword.read() }.value
            guard let self else { return }
            // Something typed while the prompt was up wins.
            if password.isEmpty { password = saved }
            isLoadingPassword = false
        }
    }

    var isConnected: Bool {
        switch state {
        case .connecting, .connected: true
        case .disconnected, .failed: false
        }
    }

    var canConnect: Bool { !isLoadingPassword && KiwiProtocol.soundURL(hostPort: hostPort) != nil }

    // MARK: - Connection

    func connect() {
        guard !isLoadingPassword else { return }
        hostPort = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        closeSession()
        guard canConnect else {
            state = .failed(.invalidHost)
            return
        }
        // Start where the rig is, so the first tune is already right.
        if followRig, let hub {
            let rig = RigTarget(hub.rigState)
            rigTarget = rig
            if case let .tune(hz, kiwiMode) = link.follow(
                rigFrequencyHz: rig.frequencyHz, rigMode: rig.mode, kiwiFrequencyHz: frequencyHz, kiwiMode: mode,
                maxFrequencyHz: maxFrequencyHz, now: Self.now) {
                applyTuning(frequencyHz: hz, mode: kiwiMode)
            }
            applyRigWidth(rig)
        }
        subscribeToRig()
        sessionTimestamp = Date()
        let client = KiwiSDRClient(hostPort: hostPort, password: password, identUser: "FTX1Remote",
                                   compression: false, tuning: currentTuning, receiver: receiver,
                                   timestamp: sessionTimestamp,
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
        cancelTrailingRetune()
        cancelReceiverSend()
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
            let accepted = passwordInUse
            Task.detached {
                if accepted != LocalSDRPassword.read() { LocalSDRPassword.write(accepted) }
            }
            startPlayback(sampleRate: sampleRate)
            startWaterfall()
        case .audio(let chunk):
            let pcm = Self.littleEndianPCM(chunk.samples)
            // Only the player's copy is adjusted: the recording and the
            // decoders below get every sample as it came.
            if var adjuster = playoutAdjuster {
                let adjusted = adjuster.process(chunk.samples, bufferedSeconds: playback?.playoutStatus()?.bufferedSeconds,
                                                now: Self.now)
                playoutAdjuster = adjuster
                if !adjusted.isEmpty { playback?.push(pcm: Self.littleEndianPCM(adjusted)) }
            } else {
                playback?.push(pcm: pcm)
            }
            notePlayout()
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
            cancelTrailingRetune()
            cancelReceiverSend()
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
        let engine = AudioPlaybackEngine(squelchEnabled: false, inputSampleRate: sampleRate,
                                         prebufferSeconds: Self.playoutTargetSeconds)
        engine.setOutputDevice(AudioOutputDeviceLister.deviceID(forUID: AudioOutputSettings.deviceUID))
        engine.start()
        playback = engine
        playoutMonitor = KiwiPlayoutMonitor()
        var target = Self.playoutTargetSeconds
        #if DEBUG
        // Pass e.g. "-localSDR.playoutTargetOverride 0.20" at launch to make
        // the queue be off target, so the slow corrections can be heard.
        if UserDefaults.standard.object(forKey: "localSDR.playoutTargetOverride") != nil {
            target = UserDefaults.standard.double(forKey: "localSDR.playoutTargetOverride")
        }
        #endif
        playoutAdjuster = KiwiPlayoutAdjuster(sampleRate: sampleRate, targetSeconds: target)
        applyVolume()
    }

    /// One line per 30 s while connected: how far ahead the audio is
    /// queued. Its slow drift is the Kiwi's clock against the Mac's output.
    private func notePlayout() {
        guard let status = playback?.playoutStatus() else { return }
        guard let report = playoutMonitor.add(bufferedSeconds: status.bufferedSeconds, underruns: status.underruns,
                                              now: Self.now) else { return }
        let text = String(format: "avg=%.1f min=%.1f max=%.1f", report.averageMs, report.minimumMs, report.maximumMs)
        logger.debug("playout: buffered ms \(text, privacy: .public) underruns=\(report.underruns) splices=\(self.playoutAdjuster?.splices ?? 0) discarded=\(self.playoutAdjuster?.discardedSeconds ?? 0, privacy: .public) padded=\(self.playoutAdjuster?.paddedSeconds ?? 0, privacy: .public) t=\(Int(report.elapsedSeconds))")
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

    private var currentTuning: KiwiTuning {
        KiwiTuning(dialHz: frequencyHz, mode: mode, lowCut: passband.low, highCut: passband.high,
                   cwShiftHz: passband.cwShiftHz)
    }

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
            passband = rigBand(for: rigTarget, mode: newMode) ?? Self.savedPassband(for: newMode)
            UserDefaults.standard.set(newMode.rawValue, forKey: Keys.mode)
            changed = true
        }
        guard changed else { return }
        retune()
        keepPassbandVisible()
        hub?.localSDRSource.modeChanged(mode)
        checkRecordingSplit()
    }

    /// Retunes the open socket ("SET mod=… freq=…"), no reconnect. At most
    /// every 50 ms (a drag asks for one per mouse event), the last one
    /// always going out.
    private func retune() {
        guard client != nil else { return }
        let elapsed = ContinuousClock.now - lastRetune
        if elapsed >= Self.retuneInterval {
            cancelTrailingRetune()
            sendRetune()
        } else if trailingRetune == nil {
            trailingRetune = Task { [weak self] in
                try? await Task.sleep(for: Self.retuneInterval - elapsed)
                guard !Task.isCancelled, let self else { return }
                trailingRetune = nil
                sendRetune()
            }
        }
    }

    private func sendRetune() {
        guard let client else { return }
        lastRetune = .now
        let tuning = currentTuning
        Task { await client.tune(tuning) }
    }

    private func cancelTrailingRetune() {
        trailingRetune?.cancel()
        trailingRetune = nil
    }

    // MARK: - Receiver controls

    /// A change from the Receiver section: saved at once, and sent at most
    /// every 100 ms so a dragged slider doesn't flood the socket.
    func updateReceiver(_ change: (inout KiwiReceiverSettings) -> Void) {
        var new = receiver
        change(&new)
        new = new.clamped
        guard new != receiver else { return }
        receiver = new
        Self.saveReceiver(new)
        guard client != nil, trailingReceiverSend == nil else { return }
        trailingReceiverSend = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            trailingReceiverSend = nil
            guard let client else { return }
            let settings = receiver
            await client.setReceiver(settings)
        }
    }

    private func cancelReceiverSend() {
        trailingReceiverSend?.cancel()
        trailingReceiverSend = nil
    }

    private static func savedReceiver() -> KiwiReceiverSettings {
        let defaults = UserDefaults.standard
        var settings = KiwiReceiverSettings()
        if let value = defaults.object(forKey: Keys.agc) as? Bool { settings.agc = value }
        if let value = defaults.object(forKey: Keys.manualGain) as? Int { settings.manualGain = value }
        if let value = defaults.object(forKey: Keys.threshold) as? Int { settings.threshold = value }
        if let value = defaults.object(forKey: Keys.decay) as? Int { settings.decay = value }
        if let value = (defaults.object(forKey: Keys.noiseBlanker) as? Int).flatMap(KiwiReceiverSettings.NoiseBlanker.init(rawValue:)) {
            settings.noiseBlanker = value
        }
        if let value = defaults.object(forKey: Keys.gate) as? Int { settings.gate = value }
        if let value = defaults.object(forKey: Keys.blankerThreshold) as? Int { settings.blankerThreshold = value }
        if let value = defaults.object(forKey: Keys.wildThreshold) as? Double { settings.wildThreshold = value }
        if let value = (defaults.object(forKey: Keys.noiseFilter) as? Int).flatMap(KiwiReceiverSettings.NoiseFilter.init(rawValue:)) {
            settings.noiseFilter = value
        }
        if let value = defaults.object(forKey: Keys.denoise) as? Bool { settings.denoise = value }
        if let value = defaults.object(forKey: Keys.autonotch) as? Bool { settings.autonotch = value }
        return settings.clamped
    }

    private static func saveReceiver(_ settings: KiwiReceiverSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.agc, forKey: Keys.agc)
        defaults.set(settings.manualGain, forKey: Keys.manualGain)
        defaults.set(settings.threshold, forKey: Keys.threshold)
        defaults.set(settings.decay, forKey: Keys.decay)
        defaults.set(settings.noiseBlanker.rawValue, forKey: Keys.noiseBlanker)
        defaults.set(settings.gate, forKey: Keys.gate)
        defaults.set(settings.blankerThreshold, forKey: Keys.blankerThreshold)
        defaults.set(settings.wildThreshold, forKey: Keys.wildThreshold)
        defaults.set(settings.noiseFilter.rawValue, forKey: Keys.noiseFilter)
        defaults.set(settings.denoise, forKey: Keys.denoise)
        defaults.set(settings.autonotch, forKey: Keys.autonotch)
    }

    // MARK: - Passband

    var isPassbandDefault: Bool { passband == KiwiPassband(defaultFor: mode) }

    /// A drag of one edge on the waterfall; `hz` is where the mouse is.
    func dragPassbandEdge(_ edge: KiwiPassband.Edge, toWaterfallHz hz: Double) {
        if followRigWidth { followRigWidth = false }
        setPassband(passband.dragging(edge, toOffsetHz: hz - Double(frequencyHz), mode: mode))
    }

    func resetPassband() {
        if followRigWidth { followRigWidth = false }
        setPassband(KiwiPassband(defaultFor: mode))
        keepPassbandVisible()
    }

    /// The Follow width toggle.
    func setFollowRigWidth(_ on: Bool) {
        guard on != followRigWidth else { return }
        followRigWidth = on
        if on, let rigTarget {
            applyRigWidth(rigTarget)
        } else if !on {
            restoreSavedPassband()
        }
    }

    private var isFollowingRigWidth: Bool { followRig && followRigWidth }

    /// MAIN's filter as a passband, if it's being followed and applies to
    /// `mode`.
    private func rigBand(for target: RigTarget?, mode: KiwiSDRMode) -> KiwiPassband? {
        guard isFollowingRigWidth, let target, KiwiSDRMode(rigMode: target.mode) == mode else { return nil }
        return target.filter
    }

    private func applyRigWidth(_ target: RigTarget) {
        guard let band = rigBand(for: target, mode: mode), band != passband else { return }
        logger.debug("rig link: passband \(band.low)…\(band.high) from the rig")
        passband = band
        retune()
        keepPassbandVisible()
    }

    /// Following stopped: the mode's own passband again.
    private func restoreSavedPassband() {
        let saved = Self.savedPassband(for: mode)
        guard saved != passband else { return }
        passband = saved
        retune()
        keepPassbandVisible()
    }

    private func setPassband(_ newPassband: KiwiPassband) {
        guard newPassband != passband else { return }
        passband = newPassband
        UserDefaults.standard.set([newPassband.low, newPassband.high], forKey: Keys.passband(mode))
        retune()
    }

    private static func savedPassband(for mode: KiwiSDRMode) -> KiwiPassband {
        guard let saved = UserDefaults.standard.array(forKey: Keys.passband(mode)) as? [Int], saved.count == 2
        else { return KiwiPassband(defaultFor: mode) }
        let band = KiwiPassband(low: saved[0], high: saved[1])
        return band.isValid(for: mode) ? band : KiwiPassband(defaultFor: mode)
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
        if isFollowingRigWidth { restoreSavedPassband() }
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
            .map { RigTarget($0) }
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
            applyRigWidth(target)
        case .alreadyThere:
            if rigLinkNote != nil { rigLinkNote = nil }
            applyRigWidth(target)
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
        let carrier = Double(tuning.carrierHz)
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

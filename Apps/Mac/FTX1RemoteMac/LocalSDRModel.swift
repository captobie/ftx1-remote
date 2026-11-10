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
/// not 12000), squelch off. Phase 1: no waterfall, rig following, WebSDR-
/// style automatic muting, decoder sources or recording.
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

    private var client: KiwiSDRClient?
    private var eventsTask: Task<Void, Never>?
    private var playback: AudioPlaybackEngine?
    private var connectedHost = ""
    private var passwordInUse = ""
    private var lastMeterPublish = ContinuousClock.now
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
        let client = KiwiSDRClient(hostPort: hostPort, password: password, identUser: "FTX1Remote",
                                   compression: false, tuning: currentTuning,
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
        case .audio(let chunk):
            playback?.push(pcm: Self.littleEndianPCM(chunk.samples))
            let now = ContinuousClock.now
            if now - lastMeterPublish >= .milliseconds(100) {
                lastMeterPublish = now
                meter.update(dBm: chunk.smeterDBm, overload: chunk.flags.contains(.adcOverflow))
            }
        case .closed(let error):
            client = nil
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
    }

    func step(byHz delta: Int) { setFrequency(frequencyHz + delta) }

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

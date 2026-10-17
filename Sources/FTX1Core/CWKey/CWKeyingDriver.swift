import Foundation
import os

/// Runs a `CWStraightKeyEngine` against real time: consumes a key
/// source's events, sets the keyer line after every change, and fires a
/// dispatch timer at the engine's next deadline (playout times, heartbeat
/// timeout, max key-down). Everything happens on one user-interactive
/// serial queue, so neither the main thread nor the UI can delay a
/// transition; the UI gets `Snapshot`s.
///
/// The keyer is opened when armed and closed when disarmed, so the
/// keying port is only held (and the rig only exposed to it) while the
/// operator means to key.
///
/// Every key-up is confirmed (`CWKeyer.release` reads the line back). If
/// setting or confirming the line fails, keying stops and the keyer is
/// kept and retried every `releaseRetry` (reopened every
/// `releaseReopenEvery`th try) until the line reads up — through disarm,
/// and with arming refused meanwhile. A failed USB control transfer must
/// never leave the rig transmitting.
/// What `StraightKeyController` drives: the local RTS/DTR driver below, or
/// `CWRemoteKeyingDriver` (keying on the Pi).
public protocol CWKeyingDriving: AnyObject, Sendable {
    func start()
    func setArmed(_ armed: Bool)
    func setBlockReason(_ reason: String?)
    func setPlayoutDelay(_ seconds: Double)
    func setMaxKeyDown(_ seconds: Double)
    func shutdown()
}

public final class CWKeyingDriver: CWKeyingDriving, @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var link: CWKeyLinkState = .closed
        public var armed = false
        /// The keying line.
        public var keyed = false
        /// The operator's key, as played out.
        public var operatorKeyDown = false
        /// What currently stops keying (nil = would key), and the cutoff
        /// holding the current press up until the key is released.
        public var cutoff: CWKeyingSafety.Cutoff?
        public var latch: CWKeyingSafety.Cutoff?
        /// The keying port's last failure, nil while fine.
        public var keyerError: String?
        public var deviceStatus: CWKeyDeviceStatus?
        public var restartCount = 0

        public init() {}
    }

    private let queue = DispatchQueue(label: "com.ftx1remote.cw-keying", qos: .userInteractive)
    private let source: CWKeySource
    private let makeKeyer: @Sendable () -> CWKeyer?
    private let clock: CWHostClock
    private let onSnapshot: @Sendable (Snapshot) -> Void
    private let logger: Logger

    // Queue-confined.
    private var engine: CWStraightKeyEngine
    private var keyer: CWKeyer?
    private var lineKeyed = false
    private var keyerError: String?
    private var lastSnapshot: Snapshot?
    private var timer: DispatchSourceTimer?
    /// A keyer whose line couldn't be confirmed up, being retried.
    private var releasing: (keyer: CWKeyer, reason: String, tries: Int, since: Double, nextAt: Double, loggedAt: Double)?
    public static let releaseRetry = 0.02
    public static let releaseReopenEvery = 5
    private var consumer: Task<Void, Never>?
    private var shutDown = false

    /// `makeKeyer` builds the keyer for the current settings each time the
    /// driver is armed (nil = none configured: arming fails).
    public init(source: CWKeySource,
                engine: CWStraightKeyEngine = CWStraightKeyEngine(),
                clock: CWHostClock = CWMonotonicClock(),
                logSubsystem: String,
                makeKeyer: @escaping @Sendable () -> CWKeyer?,
                onSnapshot: @escaping @Sendable (Snapshot) -> Void) {
        self.source = source
        self.engine = engine
        self.clock = clock
        self.makeKeyer = makeKeyer
        self.onSnapshot = onSnapshot
        logger = Logger(subsystem: logSubsystem, category: "cw-key")
    }

    /// Starts consuming the source and starts it.
    public func start() {
        queue.async { [self] in
            guard consumer == nil, !shutDown else { return }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.setEventHandler { [weak self] in self?.timerFired() }
            timer.resume()
            self.timer = timer
            let events = source.events
            consumer = Task.detached(priority: .high) { [weak self] in
                for await event in events {
                    self?.queue.async { self?.ingest(event) }
                }
            }
            source.start()
            update()
        }
    }

    public func setArmed(_ armed: Bool) {
        queue.async { [self] in
            guard !shutDown else { return }
            let now = clock.now()
            if armed {
                guard keyer == nil else { return }
                guard releasing == nil else {
                    keyerError = "Still releasing the keying line after a port error — try again shortly"
                    update()
                    return
                }
                guard let newKeyer = makeKeyer() else {
                    keyerError = "No keying port selected"
                    update()
                    return
                }
                do {
                    try newKeyer.open()
                    keyer = newKeyer
                    lineKeyed = false
                    keyerError = nil
                    engine.setKeyerReady(true, now: now)
                    engine.setArmed(true, now: now)
                    logger.notice("armed")
                    #if os(macOS)
                    if let modem = newKeyer as? ModemLineCWKeyer, !modem.readBackSupported {
                        logger.error("the serial driver can't report RTS/DTR (TIOCMGET): key-ups are not confirmed")
                    }
                    #endif
                } catch {
                    keyerError = "\(error)"
                    logger.error("arming failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                engine.setArmed(false, now: now)
                apply()
                closeKeyer()
                engine.setKeyerReady(false, now: now)
                logger.notice("disarmed")
            }
            update()
        }
    }

    /// nil when transmitting is allowed (Enable Transmit, band, mode of
    /// connection), else why not. Unkeys at once if it appears mid-press.
    public func setBlockReason(_ reason: String?) {
        queue.async { [self] in
            engine.setBlockReason(reason, now: clock.now())
            update()
        }
    }

    public func setPlayoutDelay(_ seconds: Double) {
        queue.async { [self] in
            engine.setPlayoutDelay(seconds)
            update()
        }
    }

    public func setMaxKeyDown(_ seconds: Double) {
        queue.async { [self] in
            engine.setMaxKeyDown(seconds, now: clock.now())
            update()
        }
    }

    /// Unkeys and closes everything, synchronously — for app quit. The
    /// driver does nothing after this.
    public func shutdown() {
        queue.sync {
            shutDown = true
            engine.setArmed(false, now: clock.now())
            apply()
            closeKeyer()
            // Don't quit with a line we couldn't confirm up (bounded; HUPCL
            // drops it at exit regardless).
            let giveUp = clock.now() + 3
            while releasing != nil, clock.now() < giveUp {
                releaseTick(now: clock.now())
                if releasing != nil { usleep(UInt32(Self.releaseRetry * 1_000_000)) }
            }
            timer?.cancel()
            timer = nil
            consumer?.cancel()
            consumer = nil
            source.stop()
        }
    }

    // MARK: - Queue-confined

    private func ingest(_ event: CWKeySourceEvent) {
        guard !shutDown else { return }
        if case .link(let state) = event {
            logger.info("link \(String(describing: state), privacy: .public)")
        }
        engine.ingest(event, now: clock.now())
        handleFeedback()
        update()
    }

    /// The engine disarmed itself on RF feedback: finish the disarm here
    /// (line up, port closed) and say why.
    private func handleFeedback() {
        guard engine.feedbackDetected, keyer != nil else { return }
        logger.error("RF feedback detected: the key input is following the rig's own keying — disarmed")
        apply()
        closeKeyer()
        engine.setKeyerReady(false, now: clock.now())
        keyerError = Self.feedbackMessage
    }

    public static let feedbackMessage =
        "RF feedback detected: the key input was following the rig's own transmissions, so keying stopped and the key was disarmed. Check the key lead's ferrite, then re-arm."


    private func timerFired() {
        guard !shutDown else { return }
        let now = clock.now()
        if let deadline = engine.nextDeadline, now - deadline > 0.005 {
            logger.debug("timer late by \((now - deadline) * 1000, format: .fixed(precision: 1)) ms")
        }
        releaseTick(now: now)
        engine.tick(now: now)
        update()
    }

    /// Applies the engine's key state, reschedules the timer, publishes.
    private func update() {
        apply()
        if let deadline = [engine.nextDeadline, releasing?.nextAt].compactMap({ $0 }).min() {
            let nanoseconds = UInt64(max(0, deadline) * 1_000_000_000)
            timer?.schedule(deadline: DispatchTime(uptimeNanoseconds: nanoseconds), repeating: .never, leeway: .nanoseconds(0))
        } else {
            timer?.schedule(deadline: .distantFuture, repeating: .never)
        }
        publish()
    }

    private func apply() {
        let wanted = engine.keyed
        guard wanted != lineKeyed else { return }
        guard let keyer else {
            lineKeyed = false
            return
        }
        do {
            if wanted {
                try keyer.setKeyed(true)
            } else {
                try keyer.release()   // read back
            }
            lineKeyed = wanted
        } catch {
            // The line state is unknown: stop keying until re-armed, and
            // keep at it until the line reads up.
            logger.error("keying failed: \(String(describing: error), privacy: .public)")
            self.keyer = nil
            lineKeyed = false
            startReleasing(keyer, reason: "\(error)")
            engine.setKeyerReady(false, now: clock.now())
        }
    }

    /// Closes the keyer with its line confirmed up, else keeps it for
    /// `releaseTick`.
    private func closeKeyer() {
        lineKeyed = false
        guard let keyer else { return }
        self.keyer = nil
        do {
            try keyer.release()
            keyer.close()
        } catch {
            startReleasing(keyer, reason: "on close: \(error)")
        }
    }

    private func startReleasing(_ keyer: CWKeyer, reason: String) {
        let now = clock.now()
        logger.error("releasing the keying line (\(reason, privacy: .public))")
        keyerError = "Keying port failed (\(reason)) — releasing the line"
        releasing = (keyer, reason, 0, now, now, now)
    }

    private func releaseTick(now: Double) {
        guard var entry = releasing, now >= entry.nextAt else { return }
        entry.tries += 1
        do {
            if entry.tries % Self.releaseReopenEvery == 0 {
                try entry.keyer.reopen()
            }
            try entry.keyer.release()
        } catch {
            entry.nextAt = now + Self.releaseRetry
            if now - entry.loggedAt >= 1 {
                entry.loggedAt = now
                logger.error("keying line still not confirmed up after \(entry.tries) tries: \(String(describing: error), privacy: .public)")
                keyerError = "Keying port failed (\(entry.reason)) — still releasing the line, \(entry.tries) tries"
            }
            releasing = entry
            return
        }
        entry.keyer.close()
        releasing = nil
        let ms = Int((now - entry.since) * 1000)
        logger.notice("keying line released and confirmed after \(entry.tries) tries (\(ms) ms)")
        keyerError = "Keying port failed (\(entry.reason)); the line was released — re-arm to key again"
    }

    private func publish() {
        let now = clock.now()
        var snapshot = Snapshot()
        snapshot.link = engine.link
        snapshot.armed = engine.safety.armed
        snapshot.keyed = lineKeyed
        snapshot.operatorKeyDown = engine.operatorKeyDown
        snapshot.cutoff = engine.safety.cutoff(now: now)
        snapshot.latch = engine.safety.latch
        snapshot.keyerError = keyerError
        snapshot.deviceStatus = engine.deviceStatus
        snapshot.restartCount = engine.restartCount
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshot(snapshot)
    }
}

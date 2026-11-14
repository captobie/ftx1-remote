import FT8Kit
import Foundation
import FTX1Core
import os

/// Coordinates FT8 or FT4 decoding of live rig audio (one instance per
/// mode, `HubService.ft8Coordinator`/`ft4Coordinator`): resamples
/// `AudioCaptureEngine`'s taps down to 12000 Hz, accumulates them into
/// exact `FT8Decoder.blockSize`-sized blocks, and runs one decode pass per
/// UTC slot boundary (15 s FT8, 7.5 s FT4) (assumes the Mac's clock is NTP-synced —
/// same assumption WSJT-X itself makes; see the repo's FT8 plan for the
/// real-hardware validation step that checks this).
///
/// Unlike `APRSDecoder` (always-on, gated by VFO frequency match against a
/// single configured APRS frequency), FT8 has no one fixed frequency to
/// gate on — decoding here only runs between `start()` and `stop()`, called
/// from the Tools/FT8 window's lifecycle. `ingest(samples:sampleRate:channel:)`
/// drops audio cheaply when not running, and audio from any source but
/// the window's (MAIN, SUB or MyKiwiSDR, `setChannel(_:)`).
///
/// Owns a private serial queue for all decode work, same shape as
/// `APRSDecoder` — CPU-bound (LDPC decode), doesn't belong on the real-time
/// audio thread or the main actor.
final class FT8DecodeCoordinator {
    struct Spot {
        let utcTimestamp: Date
        let dialFrequencyHz: Int
        /// Where the slot's audio came from (MAIN, SUB or MyKiwiSDR).
        let channel: ReceiveAudioChannel
        let message: FT8Kit.RawMessage
    }

    enum CycleStatus: Equatable {
        case idle
        case accumulating
        case decoding
    }

    /// Always invoked on the main actor, same contract as
    /// `APRSDecoder.onStation`/`onMessage`.
    var onSpotsDecoded: (([Spot]) -> Void)?
    var onCycleStatusChanged: ((CycleStatus) -> Void)?

    let mode: FT8Kit.Mode
    private let queue: DispatchQueue
    private let resampler = FT8Resampler()
    private let logger: Logger

    init(mode: FT8Kit.Mode) {
        self.mode = mode
        let tag = mode.name.lowercased()
        queue = DispatchQueue(label: "com.ftx1remote.\(tag)-decoder")
        logger = Logger(subsystem: "com.ftx1remote.mac", category: "\(tag)-decoder")
    }

    /// The dial frequency of a source: MAIN's or SUB's frequency, or the
    /// MyKiwiSDR window's. A settable closure property
    /// (assigned by `HubService.init`, same as `audioCapture.onAudioSamples`)
    /// rather than a required init parameter — sidesteps capturing `[weak
    /// self]` for a `HubService`-owned `let` property before all of
    /// `HubService`'s other stored properties are initialized, and keeps
    /// this independently constructible/testable without a `HubService`.
    var dialFrequencyProvider: (ReceiveAudioChannel) -> Int = { _ in 0 }

    private var isRunning = false
    private var decoder: FT8Decoder?
    private var pendingSamples: [Float] = []
    private var timer: DispatchSourceTimer?
    private var lastSlotPhase: Double?
    private var currentSlotStart: Date?
    private var currentSlotDialFrequencyHz: Int?
    /// Only this source's audio is decoded. Set through `setChannel(_:)`.
    private var channel = ReceiveAudioChannel.main

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    /// Switches the decoded source. The slot in progress starts over: its
    /// audio so far came from the old source (and maybe another rate), and
    /// its spots would carry the old source's dial frequency.
    func setChannel(_ channel: ReceiveAudioChannel) {
        queue.async { [weak self] in
            guard let self, self.channel != channel else { return }
            self.channel = channel
            guard self.isRunning else { return }
            self.resampler.reset()
            self.beginSlot(at: Date())
            self.logger.debug("source now \(channel.rawValue, privacy: .public)")
        }
    }

    /// Cheap from the caller's side — copies the array reference into the
    /// closure and returns immediately; resample/accumulate/decode all
    /// happen on `queue`. Dropped entirely (no-op) when not running or
    /// when `channel` isn't the selected source.
    func ingest(samples: [Float], sampleRate: Double, channel: ReceiveAudioChannel) {
        queue.async { [weak self] in
            guard let self, self.isRunning, channel == self.channel else { return }
            self.ingestOnQueue(samples: samples, sampleRate: sampleRate)
        }
    }

    private func startOnQueue() {
        guard !isRunning else { return }
        isRunning = true
        resampler.reset()
        beginSlot(at: Date())
        scheduleTimer()
        notifyStatus(.accumulating)
        logger.debug("started")
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        pendingSamples = []
        decoder = nil
        currentSlotStart = nil
        currentSlotDialFrequencyHz = nil
        lastSlotPhase = nil
        notifyStatus(.idle)
        logger.debug("stopped")
    }

    /// Ticks well inside the slot period so a boundary crossing is never
    /// missed by more than this margin — 0.5s costs nothing against a 15s
    /// (or FT4's 7.5s) slot and matches the general granularity ft8_lib's own demo uses for
    /// its live-capture polling loop.
    private func scheduleTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { [weak self] in
            self?.checkSlotBoundary()
        }
        source.resume()
        timer = source
    }

    private func checkSlotBoundary() {
        guard isRunning else { return }
        let now = Date()
        let phase = now.timeIntervalSince1970.truncatingRemainder(dividingBy: mode.slotTimeSeconds)
        defer { lastSlotPhase = phase }
        // A slot boundary was crossed since the last tick when the phase
        // wraps back down (e.g. 14.7s -> 0.2s for FT8, 7.3s -> 0.1s for FT4). Guards against the trivial
        // case of `lastSlotPhase` not yet set (first tick after start()).
        if let lastSlotPhase, phase < lastSlotPhase {
            finishSlotAndStartNext(at: now)
        }
    }

    /// Starts accumulating a fresh slot. Uses a new `FT8Decoder` rather than
    /// `reset()`-ing the previous one so any samples that arrive between
    /// detecting the boundary and this call (bounded by the timer's 0.5s
    /// granularity) land in the new decoder's own buffer, not stay
    /// discarded mid-flight.
    private func beginSlot(at date: Date) {
        let phase = date.timeIntervalSince1970.truncatingRemainder(dividingBy: mode.slotTimeSeconds)
        currentSlotStart = date.addingTimeInterval(-phase)
        currentSlotDialFrequencyHz = dialFrequencyProvider(channel)
        decoder = FT8Decoder(sampleRate: FT8Resampler.targetSampleRate, mode: mode)
        pendingSamples = []
        lastSlotPhase = phase
    }

    private func finishSlotAndStartNext(at date: Date) {
        notifyStatus(.decoding)
        defer {
            beginSlot(at: date)
            notifyStatus(.accumulating)
        }
        guard let decoder, let slotStart = currentSlotStart, let dialFrequencyHz = currentSlotDialFrequencyHz else { return }

        let messages = decoder.decode()
        logger.debug("slot \(slotStart.timeIntervalSince1970, privacy: .public): decoded \(messages.count) message(s)")
        guard !messages.isEmpty else { return }

        let channel = channel
        let spots = messages.map { Spot(utcTimestamp: slotStart, dialFrequencyHz: dialFrequencyHz, channel: channel, message: $0) }
        let callback = onSpotsDecoded
        DispatchQueue.main.async { callback?(spots) }
    }

    private func ingestOnQueue(samples: [Float], sampleRate: Double) {
        guard let decoder else { return }
        let resampled = resampler.convert(samples, sourceRate: sampleRate)
        guard !resampled.isEmpty else { return }
        pendingSamples.append(contentsOf: resampled)

        while pendingSamples.count >= decoder.blockSize {
            let block = Array(pendingSamples.prefix(decoder.blockSize))
            pendingSamples.removeFirst(decoder.blockSize)
            decoder.process(block: block)
        }
    }

    private func notifyStatus(_ status: CycleStatus) {
        let callback = onCycleStatusChanged
        DispatchQueue.main.async { callback?(status) }
    }
}

import Foundation

/// Sums up how far ahead the Local SDR window's audio is queued, one
/// report per `interval` of playback. The queue's level follows the Kiwi's
/// clock against the Mac's output device, plus network jitter on top; the
/// reports' slow trend is the clock drift. `now` is seconds on any
/// monotonic clock, so it can be tested with a fake one.
public struct KiwiPlayoutMonitor: Sendable {
    public struct Report: Equatable, Sendable {
        public let averageMs: Double
        public let minimumMs: Double
        public let maximumMs: Double
        public let underruns: Int
        public let elapsedSeconds: Double
    }

    public let interval: TimeInterval
    private var started: TimeInterval?
    private var windowStarted: TimeInterval = 0
    private var total = 0.0
    private var count = 0
    private var minimum = Double.infinity
    private var maximum = -Double.infinity

    public init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    public mutating func add(bufferedSeconds: Double, underruns: Int, now: TimeInterval) -> Report? {
        if started == nil {
            started = now
            windowStarted = now
        }
        total += bufferedSeconds
        count += 1
        minimum = min(minimum, bufferedSeconds)
        maximum = max(maximum, bufferedSeconds)
        guard now - windowStarted >= interval, let started else { return nil }
        let report = Report(averageMs: total / Double(count) * 1000, minimumMs: minimum * 1000,
                            maximumMs: maximum * 1000, underruns: underruns, elapsedSeconds: now - started)
        windowStarted = now
        total = 0
        count = 0
        minimum = .infinity
        maximum = -.infinity
        return report
    }
}

/// Decides how to keep the Local SDR window's playback queue near its
/// target. Measured over 36 minutes (2026-11-10): the queue grew ~5 ppm
/// (the Kiwi's clock against the Mac's output, ~19 ms an hour), and one
/// ~2 s network stall left 2 s of extra latency for the rest of the
/// session (the backlog arrived at once and nothing ever took it out). So:
///
/// - slow drift: once the 10 s average is `deadband` off target, one small
///   splice per `correctionInterval` until it's within `settled`;
/// - a backlog: when even the queue's lowest level in the last 0.5 s is
///   `backlogExcess` over target, audio that hasn't been queued yet is
///   discarded to bring it back in one step;
/// - a dry queue: the audio resumes behind `target` seconds of silence, so
///   one stall doesn't leave it running on empty.
///
/// `now` is seconds on any monotonic clock.
public struct KiwiPlayoutController: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Take a little out (+1) or add a little (−1).
        case splice(direction: Int)
        case discard(seconds: Double)
        case pad(seconds: Double)
    }

    public static let deadband = 0.03
    public static let settled = 0.01
    public static let backlogExcess = 0.3
    public static let correctionInterval: TimeInterval = 0.5
    static let longWindow: TimeInterval = 10
    static let floorWindow: TimeInterval = 0.5

    public let target: Double
    private var history: [(time: TimeInterval, buffered: Double)] = []
    private var firstTime: TimeInterval?
    private var lastCorrection = -Double.infinity
    private var correcting = false

    public init(target: Double) {
        self.target = target
    }

    /// `queued`: seconds queued just before this chunk is added. The level
    /// compared with `target` includes the chunk, so it means the same as
    /// the warm-up (`target` queued once a chunk has just gone in).
    public mutating func observe(bufferedSeconds queued: Double, chunkSeconds: Double, now: TimeInterval) -> Action {
        if queued <= 0.001, firstTime != nil {
            reset()
            return .pad(seconds: max(target - chunkSeconds, 0))
        }
        let buffered = queued + chunkSeconds
        if firstTime == nil { firstTime = now }
        history.append((now, buffered))
        if let stale = history.firstIndex(where: { now - $0.time <= Self.longWindow }), stale > 0 {
            history.removeFirst(stale)
        }
        guard let first = firstTime, now - first >= Self.floorWindow else { return .none }

        let floor = history.reversed().prefix { now - $0.time <= Self.floorWindow }.map(\.buffered).min() ?? buffered
        if floor - target > Self.backlogExcess {
            reset()
            return .discard(seconds: floor - target)
        }

        guard now - first >= Self.longWindow, now - lastCorrection >= Self.correctionInterval else { return .none }
        let error = history.map(\.buffered).reduce(0, +) / Double(history.count) - target
        if abs(error) >= Self.deadband { correcting = true }
        if abs(error) <= Self.settled { correcting = false }
        guard correcting else { return .none }
        lastCorrection = now
        return .splice(direction: error > 0 ? 1 : -1)
    }

    /// A splice took `seconds` out (negative: added them): history shows
    /// the queue as it would have been, so the average doesn't lag.
    public mutating func applied(seconds: Double) {
        for index in history.indices { history[index].buffered -= seconds }
    }

    /// After a discard finishes, or anything else that moves the queue.
    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
        firstTime = nil
        correcting = false
    }
}

/// Applies `KiwiPlayoutController`'s decisions to the Kiwi's samples on
/// their way to the player (only there: decoders and recordings get every
/// sample as it came).
///
/// A splice crossfades a few milliseconds of the audio against itself
/// about a millisecond later or earlier, choosing the offset where the two
/// line up best, so a steady CW tone keeps its phase. A discard fades out
/// the chunk in hand and in on the first one kept; a pad fades in after
/// its silence.
public struct KiwiPlayoutAdjuster: Sendable {
    /// Crossfade/fade length (8 ms at 12 kHz), and the offsets tried.
    static let fadeSamples = 96
    static let offsets = 6...30

    public private(set) var splices = 0
    public private(set) var discardedSeconds = 0.0
    public private(set) var paddedSeconds = 0.0

    private let sampleRate: Double
    private var controller: KiwiPlayoutController
    private var discardRemaining = 0
    private var fadeInNext = false

    public init(sampleRate: Double, targetSeconds: Double) {
        self.sampleRate = sampleRate
        controller = KiwiPlayoutController(target: targetSeconds)
    }

    /// `bufferedSeconds`: what's queued now, nil before playback has
    /// started (the samples go through untouched then).
    public mutating func process(_ samples: [Int16], bufferedSeconds: Double?, now: TimeInterval) -> [Int16] {
        guard !samples.isEmpty else { return samples }
        if discardRemaining > 0 {
            discardRemaining -= samples.count
            if discardRemaining <= 0 {
                discardRemaining = 0
                controller.reset()
                fadeInNext = true
            }
            return []
        }
        var output = samples
        if fadeInNext {
            fadeInNext = false
            Self.fadeIn(&output)
        }
        guard let bufferedSeconds else { return output }
        switch controller.observe(bufferedSeconds: bufferedSeconds, chunkSeconds: Double(samples.count) / sampleRate, now: now) {
        case .none:
            return output
        case .splice(let direction):
            guard let spliced = Self.spliced(output, direction: direction) else { return output }
            splices += 1
            controller.applied(seconds: Double(output.count - spliced.count) / sampleRate)
            return spliced
        case .discard(let seconds):
            discardedSeconds += seconds
            discardRemaining = Int(seconds * sampleRate)
            Self.fadeOut(&output)
            return output
        case .pad(let seconds):
            paddedSeconds += seconds
            Self.fadeIn(&output)
            return [Int16](repeating: 0, count: Int(seconds * sampleRate)) + output
        }
    }

    /// `samples` a little shorter (direction +1) or longer (−1), or nil if
    /// the chunk is too short to splice.
    static func spliced(_ x: [Int16], direction: Int) -> [Int16]? {
        let start = offsets.upperBound
        guard x.count >= start + fadeSamples + offsets.upperBound else { return nil }
        // The offset where the crossfaded stretches match best.
        var best = offsets.lowerBound
        var bestScore = -Double.infinity
        for offset in offsets {
            let shift = direction * offset
            var dot = 0.0, energyA = 1.0, energyB = 1.0
            for k in 0..<fadeSamples {
                let a = Double(x[start + k]), b = Double(x[start + shift + k])
                dot += a * b
                energyA += a * a
                energyB += b * b
            }
            let score = dot / (energyA * energyB).squareRoot()
            if score > bestScore {
                bestScore = score
                best = offset
            }
        }
        let shift = direction * best
        var output = [Int16]()
        output.reserveCapacity(x.count - shift)
        output.append(contentsOf: x[0..<start])
        for k in 0..<fadeSamples {
            let w = (Double(k) + 0.5) / Double(fadeSamples)
            let blended = Double(x[start + k]) * (1 - w) + Double(x[start + shift + k]) * w
            output.append(Int16(blended.rounded()))
        }
        output.append(contentsOf: x[(start + shift + fadeSamples)...])
        return output
    }

    private static func fadeIn(_ x: inout [Int16]) {
        for k in 0..<min(fadeSamples, x.count) {
            x[k] = Int16((Double(x[k]) * (Double(k) + 0.5) / Double(fadeSamples)).rounded())
        }
    }

    private static func fadeOut(_ x: inout [Int16]) {
        let count = min(fadeSamples, x.count)
        for k in 0..<count {
            let index = x.count - 1 - k
            x[index] = Int16((Double(x[index]) * (Double(k) + 0.5) / Double(fadeSamples)).rounded())
        }
    }
}

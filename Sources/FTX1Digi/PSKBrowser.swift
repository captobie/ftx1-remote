import Foundation

/// One line of the PSK browser: a signal the browser found and decodes.
public struct PSKBrowserChannel: Identifiable, Equatable, Sendable {
    public let id: Int
    /// The channel's carrier after AFC.
    public var frequencyHz: Double
    public var quality: Float
    /// The newest decoded text, one line (newlines shown as spaces),
    /// at most `PSKBrowser.lineLength` characters.
    public var text: String
    /// Whether the signal is still there (carrier seen or printing).
    public var isActive: Bool
}

/// Decodes every BPSK31/BPSK63 signal in the passband at once, like
/// fldigi's signal browser.
///
/// Carriers are found in the tuning strip's spectrum: the power is
/// averaged over time, summed over the signal's width (±1 baud around each
/// bin), and every local maximum standing `detectionDb` above the median
/// gets a `PSKDemodulator` of its own (AFC on, ±15 Hz around where it was
/// found). The demodulator's quality and the squelch decide what prints,
/// as in the single-signal decoder. Two channels that AFC pulls onto one
/// signal are merged; a channel is dropped once its signal has been gone
/// for `idleDropSeconds` (sooner if it never printed anything).
///
/// Time is counted in samples, not wall-clock time, so tests and files
/// behave the same as live audio. Not thread-safe; used on the
/// `DigiDecoder`'s queue only.
final class PSKBrowser {
    static let sampleRate = PSKDemodulator.inputRate
    static let maxChannels = 24
    static let lineLength = 160
    static let lowestHz = 150.0
    static let highestHz = DigiDecoder.stripSpanHz - 150
    /// How far above the median a carrier has to stand (power summed over
    /// its width, averaged over ~0.5 s).
    static let detectionDb: Float = 5
    static let detectEveryRows = 5
    static let idleDropSeconds = 60.0
    static let silentDropSeconds = 10.0
    /// A snapshot for the window every 0.25 s.
    static let snapshotHop = 2000
    /// Text prints only while the carrier was found this recently: the
    /// demodulator's quality average takes about a second to fall after a
    /// signal ends, and would print that second of noise.
    static let printHoldSamples = 4000

    let baud: Double
    var squelch: Float {
        didSet { for channel in channels { channel.demodulator.squelch = squelch } }
    }

    private final class Channel {
        let id: Int
        let demodulator: PSKDemodulator
        var text = ""
        var printedAnything = false
        /// Sample time the signal was last seen (carrier detected, or
        /// quality above the squelch).
        var lastSeen: Int
        /// Sample time the carrier was last found in the spectrum.
        var lastDetected: Int

        init(id: Int, demodulator: PSKDemodulator, now: Int) {
            self.id = id
            self.demodulator = demodulator
            lastSeen = now
            lastDetected = now
        }
    }

    private var channels: [Channel] = []
    private var nextID = 1
    private var now = 0
    private var samplesSinceSnapshot = 0
    private var averagePower: [Float] = []
    private var rowsSinceDetection = 0

    init(baud: Double, squelch: Float) {
        self.baud = baud
        self.squelch = squelch
    }

    func reset() {
        channels = []
        averagePower = []
        rowsSinceDetection = 0
        samplesSinceSnapshot = 0
    }

    /// 8 kHz audio. Returns a snapshot about four times a second.
    func process(_ audio: [Float]) -> [PSKBrowserChannel]? {
        guard !audio.isEmpty else { return nil }
        for channel in channels {
            let decoded = channel.demodulator.process(audio)
            guard now - channel.lastDetected < Self.printHoldSamples else { continue }
            if channel.demodulator.quality >= squelch { channel.lastSeen = now + audio.count }
            if !decoded.isEmpty {
                channel.printedAnything = true
                append(decoded, to: channel)
            }
        }
        now += audio.count
        samplesSinceSnapshot += audio.count
        guard samplesSinceSnapshot >= Self.snapshotHop else { return nil }
        samplesSinceSnapshot = 0
        mergeAndDrop()
        return snapshot()
    }

    /// One spectrum row in dB, `binHz` apart from 0 Hz (the strip's row
    /// before normalization).
    func spectrumRow(db: [Float], binHz: Double) {
        if averagePower.count != db.count {
            averagePower = [Float](repeating: 0, count: db.count)
        }
        for k in db.indices {
            let power = pow(10, db[k] / 10)
            // Falls faster than it rises (~4 dB a row), so a strong
            // signal that stopped doesn't look present for seconds.
            let alpha: Float = power > averagePower[k] ? 0.3 : 0.6
            averagePower[k] += alpha * (power - averagePower[k])
        }
        markPresentCarriers(db: db, binHz: binHz)
        rowsSinceDetection += 1
        guard rowsSinceDetection >= Self.detectEveryRows else { return }
        rowsSinceDetection = 0
        detect(binHz: binHz)
    }

    // MARK: - Detection

    /// Each channel whose carrier stands above the noise in this one row
    /// (not the average, which lags) is marked present: what lets it
    /// print.
    private func markPresentCarriers(db: [Float], binHz: Double) {
        guard noiseFloor > 0 else { return }
        let half = max(1, Int((baud / binHz).rounded()))
        let threshold = noiseFloor * pow(10, Self.detectionDb / 10)
        for channel in channels {
            let center = Int((channel.demodulator.centerHz / binHz).rounded())
            var sum: Float = 0
            for j in max(0, center - half)...min(db.count - 1, center + half) { sum += pow(10, db[j] / 10) }
            if sum > threshold { channel.lastDetected = now }
        }
    }

    /// The median of the width-summed average power at the last detection.
    private var noiseFloor: Float = 0

    static func carriers(averagePower: [Float], binHz: Double, baud: Double) -> [(hz: Double, strength: Float)] {
        carrierSearch(averagePower: averagePower, binHz: binHz, baud: baud).carriers
    }

    static func carrierSearch(averagePower: [Float], binHz: Double, baud: Double)
        -> (carriers: [(hz: Double, strength: Float)], noiseFloor: Float) {
        let low = max(1, Int(lowestHz / binHz))
        let high = min(averagePower.count - 1, Int(highestHz / binHz))
        guard high > low else { return ([], 0) }
        let half = max(1, Int((baud / binHz).rounded()))
        // Power summed over the signal's width around each bin.
        var summed = [Float](repeating: 0, count: averagePower.count)
        for k in low...high {
            var sum: Float = 0
            for j in max(0, k - half)...min(averagePower.count - 1, k + half) { sum += averagePower[j] }
            summed[k] = sum
        }
        let sorted = summed[low...high].sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return ([], 0) }
        let threshold = median * pow(10, detectionDb / 10)
        // A peak is the largest within two bauds either side.
        let reach = 2 * half
        var found: [(Double, Float)] = []
        for k in low...high where summed[k] > threshold {
            var isPeak = true
            for j in max(low, k - reach)...min(high, k + reach) where j != k {
                if summed[j] > summed[k] || (summed[j] == summed[k] && j < k) {
                    isPeak = false
                    break
                }
            }
            guard isPeak else { continue }
            // The power-weighted centre of the peak's width: the carrier
            // of an idle (two-tone) or texting PSK signal.
            var weight: Float = 0
            var moment: Float = 0
            for j in max(0, k - half)...min(averagePower.count - 1, k + half) {
                weight += averagePower[j]
                moment += averagePower[j] * Float(j)
            }
            let bin = weight > 0 ? Double(moment / weight) : Double(k)
            found.append((bin * binHz, 10 * log10(summed[k] / median)))
        }
        return (found, median)
    }

    private func detect(binHz: Double) {
        let search = Self.carrierSearch(averagePower: averagePower, binHz: binHz, baud: baud)
        noiseFloor = search.noiseFloor
        for carrier in search.carriers.sorted(by: { $0.strength > $1.strength }) {
            if let near = channels.first(where: { abs($0.demodulator.centerHz - carrier.hz) < baud }) {
                near.lastSeen = now
                continue
            }
            guard channels.count < Self.maxChannels else { break }
            let demodulator = PSKDemodulator(baud: baud, centerHz: carrier.hz)
            demodulator.squelch = squelch
            channels.append(Channel(id: nextID, demodulator: demodulator, now: now))
            nextID += 1
        }
    }

    // MARK: - Bookkeeping

    private func append(_ decoded: String, to channel: Channel) {
        let line = decoded.replacingOccurrences(of: "\n", with: " ")
        // No run of spaces from a string of newlines.
        for character in line {
            if character == " ", channel.text.last == " " { continue }
            channel.text.append(character)
        }
        if channel.text.count > Self.lineLength {
            channel.text = String(channel.text.suffix(Self.lineLength))
        }
    }

    private func mergeAndDrop() {
        let sampleRate = Self.sampleRate
        channels.removeAll { channel in
            let idle = Double(now - channel.lastSeen) / sampleRate
            // A stray character or two at a signal's end doesn't count.
            let printed = channel.printedAnything && channel.text.count >= 3
            return idle > (printed ? Self.idleDropSeconds : Self.silentDropSeconds)
        }
        // AFC can walk two channels onto one signal: keep the better one.
        var kept: [Channel] = []
        for channel in channels.sorted(by: Self.isBetter) {
            if let other = kept.first(where: { abs($0.demodulator.centerHz - channel.demodulator.centerHz) < baud / 2 }) {
                if other.text.isEmpty, !channel.text.isEmpty { other.text = channel.text }
                continue
            }
            kept.append(channel)
        }
        channels = kept
    }

    private static func isBetter(_ a: Channel, _ b: Channel) -> Bool {
        if a.demodulator.quality != b.demodulator.quality { return a.demodulator.quality > b.demodulator.quality }
        return a.id < b.id
    }

    private func snapshot() -> [PSKBrowserChannel] {
        let activeWithin = 3 * Self.sampleRate
        return channels
            .map { channel in
                PSKBrowserChannel(
                    id: channel.id,
                    frequencyHz: channel.demodulator.centerHz,
                    quality: channel.demodulator.quality,
                    text: channel.text,
                    isActive: Double(now - channel.lastSeen) < activeWithin
                )
            }
            .sorted { $0.frequencyHz < $1.frequencyHz }
    }
}

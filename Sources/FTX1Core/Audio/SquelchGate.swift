import Foundation

/// A pure client-side "virtual squelch" — independent of the rig's own
/// hardware squelch (which the FTX-1's USB audio output ignores anyway). No
/// AVFoundation dependency, so this is unit-testable without any real audio
/// hardware.
///
/// Gates on *quieting*, not loudness. Two real hardware captures
/// (2026-09-08) — one on a dead frequency (144.0, static only), one on NOAA
/// weather radio (162.55, a strong continuous signal) — showed static and a
/// real signal's audio sitting in the *same* RMS band while a station is
/// actually talking (~0.06-0.08 in both). An amplitude threshold can't tell
/// them apart there; a high-pass-filtered RMS didn't separate them either
/// (tried and dropped — see git history). What *did* separate them cleanly:
/// static, being continuous broadband noise, never dipped anywhere near true
/// silence across 50+ consecutive samples, while the real signal repeatedly
/// dropped to near-total silence between phrases (as low as 0.001) — a
/// strong, cleanly-locked FM carrier quiets the receiver completely when
/// there's no modulation, something dead air never does. So this gate looks
/// for that quieting dip as evidence a real carrier is present, opens on it,
/// and holds open through a hangover long enough to bridge the loud parts of
/// real speech — which, per the same data, look just like static and can't
/// be judged on their own.
///
/// Untested against actual ham voice traffic's PTT/pause cadence (only
/// NOAA's continuous, evenly-paced announcer speech) and untested on modes
/// other than FM — see the pinned status note for what still needs
/// real-world confirmation.
struct SquelchGate {
    /// RMS level (0...1) at or below which a chunk counts as a genuine
    /// quieting dip — how close to true silence the audio must get to count
    /// as evidence of a locked signal, rather than just an ordinary lull in
    /// static. Smaller = stricter (only a very cleanly-locked signal will
    /// ever trigger it); larger = more lenient, but risks mistaking a
    /// natural low point in static for a real quieting dip.
    var threshold: Float

    /// How long the gate stays open after the last detected quieting dip —
    /// needs to comfortably bridge the loud, signal-and-static-
    /// indistinguishable stretch between one pause and the next in real
    /// speech, not just the brief "avoid chatter right at the threshold
    /// edge" window the old amplitude-threshold design needed (0.3s). 4s is
    /// a starting guess (NOAA's own phrase-to-phrase pauses were well under
    /// that in the capture this design is based on) pending real ham-voice
    /// traffic tuning.
    var releaseDuration: TimeInterval = 4.0

    private(set) var isOpen = false
    private var lastQuietDetected: Date?

    init(threshold: Float = 0.015) {
        self.threshold = threshold
    }

    /// Feed one chunk's RMS level; returns the gate's state after this
    /// update (also available via `isOpen`).
    @discardableResult
    mutating func update(rms: Float, now: Date = Date()) -> Bool {
        if rms <= threshold {
            lastQuietDetected = now
            isOpen = true
        } else if let last = lastQuietDetected, now.timeIntervalSince(last) < releaseDuration {
            isOpen = true
        } else {
            isOpen = false
        }
        return isOpen
    }

    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Convenience for raw Int16 PCM bytes (the wire format — see
    /// `AudioStreamFormat`), normalized to the same 0...1 scale as
    /// `rms(of:)`. Both endpoints run on little-endian Apple platforms, so
    /// no explicit byte-swapping is needed.
    static func rms(ofInt16Bytes data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sumOfSquares: Float = 0
        data.withUnsafeBytes { raw in
            guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                let normalized = Float(samples[i]) / Float(Int16.max)
                sumOfSquares += normalized * normalized
            }
        }
        return (sumOfSquares / Float(sampleCount)).squareRoot()
    }
}

import Foundation

/// A pure client-side "virtual squelch" — a noise gate on the audio level
/// itself, independent of the rig's own hardware squelch (which the FTX-1's
/// USB audio output ignores anyway). No AVFoundation dependency, so this is
/// unit-testable without any real audio hardware.
struct SquelchGate {
    /// RMS level (0...1) above which the gate should open — user-adjustable
    /// via the squelch slider, or continuously recomputed by
    /// `updateAutoThreshold` while `isAutoEnabled`.
    var threshold: Float

    /// How long the level must stay below `threshold` before the gate
    /// actually closes — avoids rapid chattering right at the threshold
    /// edge, same "squelch tail" behavior real hardware squelch has.
    var releaseDuration: TimeInterval = 0.3

    /// When true, `threshold` is no longer user-set — every `update(rms:)`
    /// call derives it from `noiseFloor` instead. Toggling this on reseeds
    /// `noiseFloor` so a stale reading from a previous session (or from
    /// before the radio was retuned) doesn't linger.
    var isAutoEnabled = false {
        didSet {
            if isAutoEnabled && !oldValue {
                noiseFloor = nil
            }
        }
    }

    /// Added on top of the tracked noise floor — enough headroom that
    /// ordinary static/hiss fluctuation doesn't chatter the gate open, but
    /// small enough not to meaningfully delay opening on a real signal.
    private let autoMargin: Float = 0.01

    /// How fast the tracked floor is allowed to creep upward per update —
    /// deliberately tiny, so a single long, loud transmission can't drag it
    /// up toward the signal itself (see `updateAutoThreshold`). A drop to a
    /// quieter level is applied immediately instead, so the tracker still
    /// settles on the true background noise quickly.
    private let noiseFloorRisePerUpdate: Float = 0.000005

    private var noiseFloor: Float?
    private(set) var isOpen = false
    private var lastAboveThreshold: Date?

    init(threshold: Float = 0.02) {
        self.threshold = threshold
    }

    /// Feed one chunk's RMS level; returns the gate's state after this
    /// update (also available via `isOpen`).
    @discardableResult
    mutating func update(rms: Float, now: Date = Date()) -> Bool {
        if isAutoEnabled {
            updateAutoThreshold(rms: rms)
        }
        if rms >= threshold {
            lastAboveThreshold = now
            isOpen = true
        } else if let last = lastAboveThreshold, now.timeIntervalSince(last) < releaseDuration {
            isOpen = true
        } else {
            isOpen = false
        }
        return isOpen
    }

    /// Fast-attack (jumps straight down to a quieter reading), slow-release
    /// (only creeps up gradually otherwise) — mirrors `AudioCaptureEngine`'s
    /// peak-hold-and-decay auto-gain, but tracking the *minimum* incoming
    /// level instead of the maximum. That asymmetry is what makes this
    /// "find the lowest squelch setting that still mutes the static": on
    /// activation (or after the noise floor genuinely drops) it converges
    /// on the true background level within one update, while a sustained
    /// strong signal — which is loud, not quiet — can't pull it upward
    /// fast enough to threaten closing the gate mid-transmission.
    private mutating func updateAutoThreshold(rms: Float) {
        let floor: Float
        if let previous = noiseFloor {
            floor = rms < previous ? rms : previous + noiseFloorRisePerUpdate
        } else {
            floor = rms
        }
        noiseFloor = floor
        threshold = floor + autoMargin
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

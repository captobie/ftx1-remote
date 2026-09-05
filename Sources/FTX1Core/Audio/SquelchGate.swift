import Foundation

/// A pure client-side "virtual squelch" — a noise gate on the audio level
/// itself, independent of the rig's own hardware squelch (which the FTX-1's
/// USB audio output ignores anyway). No AVFoundation dependency, so this is
/// unit-testable without any real audio hardware.
struct SquelchGate {
    /// RMS level (0...1) above which the gate should open — user-adjustable
    /// via the iPad's squelch slider.
    var threshold: Float

    /// How long the level must stay below `threshold` before the gate
    /// actually closes — avoids rapid chattering right at the threshold
    /// edge, same "squelch tail" behavior real hardware squelch has.
    var releaseDuration: TimeInterval = 0.3

    private(set) var isOpen = false
    private var lastAboveThreshold: Date?

    init(threshold: Float = 0.02) {
        self.threshold = threshold
    }

    /// Feed one chunk's RMS level; returns the gate's state after this
    /// update (also available via `isOpen`).
    @discardableResult
    mutating func update(rms: Float, now: Date = Date()) -> Bool {
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

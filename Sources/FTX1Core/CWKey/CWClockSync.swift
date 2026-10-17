import Foundation

/// Estimates the offset from the key interface's clock to the host's
/// monotonic clock: `hostTime ≈ deviceTime + offset`.
///
/// Each received line with a device time gives one sample, `hostReceived -
/// deviceTime`. The transport only ever *adds* delay (USB polling, the
/// UNO's serial bridge, the reader thread waking), so the smallest recent
/// sample is the one closest to the true offset — a min filter, not an
/// average. Heartbeats every 250 ms keep it fed while the key is idle.
///
/// The window is kept short on purpose: the UNO's clock is a ceramic
/// resonator, off by up to ~0.5%, so an old minimum would be off by that
/// drift times its age (2 s × 0.5% = 10 ms at worst).
public struct CWClockSync: Sendable {
    /// Host seconds a sample stays in the minimum.
    public var window: Double

    private var samples: [(host: Double, offset: Double)] = []

    public init(window: Double = 2.0) {
        self.window = window
    }

    /// Adds one line's sample. `deviceMs` is the unwrapped device time,
    /// `hostReceived` the host clock (seconds) when its bytes were read.
    public mutating func add(deviceMs: Int64, hostReceived: Double) {
        samples.append((hostReceived, hostReceived - Double(deviceMs) / 1000))
        let oldest = hostReceived - window
        if let firstKept = samples.firstIndex(where: { $0.host >= oldest }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    /// nil until the first sample.
    public var offset: Double? {
        samples.map(\.offset).min()
    }

    public mutating func reset() {
        samples.removeAll()
    }
}

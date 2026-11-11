import Foundation

/// The Local SDR window's receiver controls: AGC, noise blanker and noise
/// filter, with the commands the Kiwi's own page sends for them
/// (`set_agc` in `openwebrx.js`, `noise_blank.js`, `noise_filter.js`,
/// read at v1.902). The ranges are the page's sliders'. Pure, so the
/// command text can be unit-tested.
///
/// The defaults are what a new connection has always sent: AGC on with
/// the page's values, blanker and filter off. Only the algorithm and the
/// main knobs are offered; the rest keep the page's defaults.
public struct KiwiReceiverSettings: Equatable, Sendable {
    public enum NoiseBlanker: Int, CaseIterable, Sendable {
        case off = 0, standard = 1, wild = 2
    }

    public enum NoiseFilter: Int, CaseIterable, Sendable {
        case off = 0, wdsp = 1, lms = 2, spectral = 3

        /// The two filters the Denoise and Auto notch switches apply to.
        public var hasSeparateFilters: Bool { self == .wdsp || self == .lms }
    }

    public var agc = true
    public var manualGain = 50
    public var threshold = -100
    public var decay = 1000

    public var noiseBlanker = NoiseBlanker.off
    public var gate = 100
    public var blankerThreshold = 50
    public var wildThreshold = 0.95

    public var noiseFilter = NoiseFilter.off
    public var denoise = false
    public var autonotch = false

    public static let manualGainRange = 0...120
    public static let thresholdRange = -130...0
    public static let decayRange = 20...5000
    public static let decayStep = 10
    public static let gateRange = 100...5000
    public static let gateStep = 100
    public static let blankerThresholdRange = 0...100
    public static let wildThresholdRange = 0.05...3.0
    public static let wildThresholdStep = 0.05

    public init() {}

    /// Everything inside the Kiwi's ranges (for saved values).
    public var clamped: KiwiReceiverSettings {
        var copy = self
        copy.manualGain = Self.clamp(manualGain, Self.manualGainRange)
        copy.threshold = Self.clamp(threshold, Self.thresholdRange)
        copy.decay = Self.clamp(decay, Self.decayRange)
        copy.gate = Self.clamp(gate, Self.gateRange)
        copy.blankerThreshold = Self.clamp(blankerThreshold, Self.blankerThresholdRange)
        copy.wildThreshold = Self.clamp(wildThreshold, Self.wildThresholdRange)
        return copy
    }

    private static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Picks the filter. As on the Kiwi's page, choosing WDSP or LMS with
    /// neither switch on turns Denoise on (it would do nothing otherwise).
    public mutating func select(noiseFilter newFilter: NoiseFilter) {
        noiseFilter = newFilter
        if newFilter.hasSeparateFilters, !denoise, !autonotch { denoise = true }
    }

    // MARK: - Commands

    /// Hang and slope stay at the page's defaults.
    public var agcCommand: String {
        "SET agc=\(agc ? 1 : 0) hang=0 thresh=\(threshold) slope=6 decay=\(decay) manGain=\(manualGain)"
    }

    /// `noise_blank_send`. "algo" clears every enable, so the parameters
    /// and enables follow it. Type 1 is the same blanker on the waterfall
    /// (on when the page's default is on: with any blanker).
    public var noiseBlankerCommands: [String] {
        var commands = ["SET nb algo=\(noiseBlanker.rawValue)"]
        switch noiseBlanker {
        case .off:
            break
        case .standard:
            commands += ["SET nb type=0 param=0 pval=\(gate)", "SET nb type=0 param=1 pval=\(blankerThreshold)"]
        case .wild:
            commands += ["SET nb type=0 param=0 pval=\(Self.number(wildThreshold))",
                         "SET nb type=0 param=1 pval=10", "SET nb type=0 param=2 pval=7"]
        }
        let on = noiseBlanker != .off ? 1 : 0
        commands += ["SET nb type=0 en=\(on)", "SET nb type=1 en=\(on)"]
        return commands
    }

    /// `nr_algo_cb` + `noise_filter_send` for both filters, with the
    /// page's default parameters.
    public var noiseFilterCommands: [String] {
        var commands = ["SET nr algo=\(noiseFilter.rawValue)"]
        guard noiseFilter != .off else { return commands }
        for (type, enabled) in [(0, denoise), (1, autonotch)] {
            let parameters: [Double]
            switch noiseFilter {
            case .off:
                parameters = []
            case .wdsp:
                // gain 10 and leakage 7 on the page's non-linear sliders.
                parameters = [64, 16, 8.192e-2 / pow(2, 10), 8192 / pow(2, 16)]
            case .lms:
                parameters = type == 0 ? [1, 0.05, 0.98, 0] : [48, 0.125, 0.99915, 0]
            case .spectral:
                // Gain 0 dB, alpha 0.95, active SNR 30 dB.
                parameters = [1, 0.95, 1000, 0]
            }
            for (index, value) in parameters.enumerated() {
                commands.append("SET nr type=\(type) param=\(index) pval=\(Self.number(value))")
            }
            commands.append("SET nr type=\(type) en=\(enabled ? 1 : 0)")
        }
        return commands
    }

    /// What differs from `old`, one group at a time.
    public func commands(changedFrom old: KiwiReceiverSettings) -> [String] {
        var commands: [String] = []
        if agcCommand != old.agcCommand { commands.append(agcCommand) }
        if noiseBlankerCommands != old.noiseBlankerCommands { commands += noiseBlankerCommands }
        if noiseFilterCommands != old.noiseFilterCommands { commands += noiseFilterCommands }
        return commands
    }

    private static func number(_ value: Double) -> String {
        String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), value).lowercased()
    }
}

import Foundation

/// A named amateur band with the frequency range that defines it and a
/// sensible calling-frequency fallback for the first time it's selected
/// (before any per-band "last used frequency" has been recorded).
public struct Band: Equatable, Sendable {
    public let name: String
    public let range: ClosedRange<Int>
    public let defaultFrequencyHz: Int

    public init(name: String, range: ClosedRange<Int>, defaultFrequencyHz: Int) {
        self.name = name
        self.range = range
        self.defaultFrequencyHz = defaultFrequencyHz
    }
}

/// The amateur bands this app's band selector offers, HF through UHF.
/// Shared (not Mac-only) since band naming/lookup is platform-agnostic —
/// mobile clients may want to render the current band too.
public enum BandPlan {
    public static let all: [Band] = [
        Band(name: "160m", range: 1_800_000...2_000_000, defaultFrequencyHz: 1_900_000),
        Band(name: "80m", range: 3_500_000...4_000_000, defaultFrequencyHz: 3_985_000),
        Band(name: "60m", range: 5_330_000...5_410_000, defaultFrequencyHz: 5_358_500),
        Band(name: "40m", range: 7_000_000...7_300_000, defaultFrequencyHz: 7_200_000),
        Band(name: "30m", range: 10_100_000...10_150_000, defaultFrequencyHz: 10_130_000),
        Band(name: "20m", range: 14_000_000...14_350_000, defaultFrequencyHz: 14_200_000),
        Band(name: "17m", range: 18_068_000...18_168_000, defaultFrequencyHz: 18_130_000),
        Band(name: "15m", range: 21_000_000...21_450_000, defaultFrequencyHz: 21_300_000),
        Band(name: "12m", range: 24_890_000...24_990_000, defaultFrequencyHz: 24_950_000),
        Band(name: "10m", range: 28_000_000...29_700_000, defaultFrequencyHz: 28_400_000),
        Band(name: "6m", range: 50_000_000...54_000_000, defaultFrequencyHz: 52_525_000),
        Band(name: "2m", range: 144_000_000...148_000_000, defaultFrequencyHz: 146_520_000),
        Band(name: "70cm", range: 420_000_000...450_000_000, defaultFrequencyHz: 446_000_000),
    ]

    /// Which band a frequency falls in, if any — used to label the active
    /// VFO's band and to record "last frequency used on this band".
    public static func band(containing hz: Int) -> Band? {
        all.first { $0.range.contains(hz) }
    }

    public static func band(named name: String) -> Band? {
        all.first { $0.name == name }
    }
}

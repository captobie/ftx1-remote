import Foundation

/// A named non-amateur segment worth jumping straight to — shortwave/AM/FM
/// broadcast, aircraft, marine, weather — with a conventional receive mode,
/// so picking one (or tuning into one) can default to a sensible mode
/// instead of leaving whatever was last selected. Kept as its own type
/// rather than folded into `BandPlan`'s `Band`, since amateur band
/// selection deliberately never touches mode and should stay that way —
/// same "separate small type next to the main one" precedent as `HomeBand`.
public struct GeneralCoverageSegment: Equatable, Sendable {
    public enum Category: String, Sendable {
        case broadcast = "Broadcast"
        case utility = "Utility"
    }

    public let name: String
    public let range: ClosedRange<Int>
    public let defaultFrequencyHz: Int
    public let defaultMode: RigMode
    public let category: Category

    public init(name: String, range: ClosedRange<Int>, defaultFrequencyHz: Int, defaultMode: RigMode, category: Category) {
        self.name = name
        self.range = range
        self.defaultFrequencyHz = defaultFrequencyHz
        self.defaultMode = defaultMode
        self.category = category
    }
}

/// General-coverage listening segments the app's Band picker offers
/// alongside `BandPlan`'s amateur bands. Names are prefixed `"SW "` for the
/// shortwave broadcast meter bands specifically because a couple of them
/// (60m, 15m) would otherwise collide with `BandPlan`'s ham band names —
/// both tables share `BandMemory`'s per-name last-frequency dictionary and
/// populate the same picker, so every name across both must be unique.
public enum GeneralCoverageSegments {
    public static let all: [GeneralCoverageSegment] = [
        GeneralCoverageSegment(name: "AM BCB", range: 530_000...1_700_000, defaultFrequencyHz: 1_000_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "FM BCB", range: 88_000_000...108_000_000, defaultFrequencyHz: 100_000_000, defaultMode: .fm, category: .broadcast),
        GeneralCoverageSegment(name: "SW 120m", range: 2_300_000...2_495_000, defaultFrequencyHz: 2_400_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 90m", range: 3_200_000...3_400_000, defaultFrequencyHz: 3_300_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 75m", range: 3_900_000...4_000_000, defaultFrequencyHz: 3_950_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 60m", range: 4_750_000...5_060_000, defaultFrequencyHz: 4_885_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 49m", range: 5_900_000...6_200_000, defaultFrequencyHz: 6_000_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 41m", range: 7_200_000...7_450_000, defaultFrequencyHz: 7_325_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 31m", range: 9_400_000...9_900_000, defaultFrequencyHz: 9_650_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 25m", range: 11_600_000...12_100_000, defaultFrequencyHz: 11_850_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 22m", range: 13_570_000...13_870_000, defaultFrequencyHz: 13_700_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 19m", range: 15_100_000...15_800_000, defaultFrequencyHz: 15_400_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 16m", range: 17_480_000...17_900_000, defaultFrequencyHz: 17_650_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 15m", range: 18_900_000...19_020_000, defaultFrequencyHz: 18_950_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 13m", range: 21_450_000...21_850_000, defaultFrequencyHz: 21_600_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "SW 11m", range: 25_670_000...26_100_000, defaultFrequencyHz: 25_800_000, defaultMode: .am, category: .broadcast),
        GeneralCoverageSegment(name: "CB", range: 26_965_000...27_405_000, defaultFrequencyHz: 27_185_000, defaultMode: .am, category: .utility),
        GeneralCoverageSegment(name: "Aircraft", range: 108_000_000...137_000_000, defaultFrequencyHz: 121_500_000, defaultMode: .am, category: .utility),
        GeneralCoverageSegment(name: "Marine VHF", range: 156_000_000...162_000_000, defaultFrequencyHz: 156_800_000, defaultMode: .fm, category: .utility),
        GeneralCoverageSegment(name: "NOAA WX", range: 162_400_000...162_550_000, defaultFrequencyHz: 162_550_000, defaultMode: .fm, category: .utility),
    ]

    /// Which segment a frequency falls in, if any. Callers that need to
    /// treat an amateur allocation as taking precedence over an
    /// overlapping segment (e.g. SW 41m vs. ham 40m) must check
    /// `BandPlan.band(containing:)` first themselves — this type has no
    /// dependency on `BandPlan` and always reports a match on its own
    /// terms.
    public static func segment(containing hz: Int) -> GeneralCoverageSegment? {
        all.first { $0.range.contains(hz) }
    }

    public static func segment(named name: String) -> GeneralCoverageSegment? {
        all.first { $0.name == name }
    }
}

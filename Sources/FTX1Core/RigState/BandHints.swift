import Foundation

/// A labelled stretch of spectrum for a waterfall's band bar: an amateur
/// band ("40m Amateur"), a broadcast band ("MW Broadcast", "31m
/// Broadcast"), an aeronautical or maritime mobile band ("8.8 MHz
/// Aeronautical", "12 MHz Maritime", "VHF Aeronautical") or another
/// service ("CB"). `label` is the short part shown as is ("40m", "MW",
/// "8.8 MHz", "CB"); the view adds the kind's localized word.
public struct BandHint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case amateur
        case broadcast
        case aeronautical
        case maritime
        case utility
    }

    public let label: String
    public let kind: Kind
    public let lowerHz: Int
    public let upperHz: Int
    /// The amateur band, for `AmateurBandPlan` (nil for the others).
    public let band: Band?

    public init(label: String, kind: Kind, lowerHz: Int, upperHz: Int, band: Band? = nil) {
        self.label = label
        self.kind = kind
        self.lowerHz = lowerHz
        self.upperHz = upperHz
        self.band = band
    }
}

/// The band bar's table: `BandPlan`'s amateur bands plus 2200 m and 630 m,
/// LW/MW and the shortwave broadcast bands (`GeneralCoverageSegments`) and
/// its utility segments, and the HF aeronautical and maritime mobile bands.
/// Amateur bands win where they overlap another band: SW 41m shows as
/// 7.300–7.450 MHz, and SW 75m and aeronautical 3.9 MHz (inside 80 m) not
/// at all. Region 2 edges, like `BandPlan`.
///
/// Aeronautical: the ITU's aeronautical mobile allocations (RR Article 5,
/// Appendix 27), (R) civil and (OR) military together, joined where they
/// touch — where HF air traffic control (MWARA), VOLMET and military
/// aircraft are heard. Maritime: the maritime mobile bands (Appendix 17)
/// from 4 to 26 MHz, plus 2045–2194 kHz around the 2182 kHz distress and
/// calling frequency. Each band is named by its lower edge in MHz, the
/// way these bands are usually referred to.
public enum BandHints {
    public static let all: [BandHint] = {
        let amateur = ([
            Band(name: "2200m", range: 135_700...137_800, defaultFrequencyHz: 136_000),
            Band(name: "630m", range: 472_000...479_000, defaultFrequencyHz: 475_000),
        ] + BandPlan.all).map {
            BandHint(label: $0.name, kind: .amateur, lowerHz: $0.range.lowerBound,
                     upperHz: $0.range.upperBound, band: $0)
        }
        let others = [BandHint(label: "LW", kind: .broadcast, lowerHz: 148_500, upperHz: 283_500)]
            + GeneralCoverageSegments.all.map { segment in
                switch segment.name {
                case "AM BCB":
                    BandHint(label: "MW", kind: .broadcast, lowerHz: segment.range.lowerBound,
                             upperHz: segment.range.upperBound)
                case "FM BCB":
                    BandHint(label: "FM", kind: .broadcast, lowerHz: segment.range.lowerBound,
                             upperHz: segment.range.upperBound)
                case "Aircraft":
                    BandHint(label: "VHF", kind: .aeronautical, lowerHz: segment.range.lowerBound,
                             upperHz: segment.range.upperBound)
                case "Marine VHF":
                    BandHint(label: "VHF", kind: .maritime, lowerHz: segment.range.lowerBound,
                             upperHz: segment.range.upperBound)
                default:
                    BandHint(label: segment.name.hasPrefix("SW ") ? String(segment.name.dropFirst(3)) : segment.name,
                             kind: segment.category == .broadcast ? .broadcast : .utility,
                             lowerHz: segment.range.lowerBound, upperHz: segment.range.upperBound)
                }
            }
            + mobile(.aeronautical, kHz: aeronauticalKHz) + mobile(.maritime, kHz: maritimeKHz)
            // MF maritime mobile, home of NAVTEX (490/518 kHz); 630 m cuts it in two.
            + [BandHint(label: "MF", kind: .maritime, lowerHz: 415_000, upperHz: 526_500)]
        let clipped = others.flatMap { hint in
            subtract(amateur.map { ($0.lowerHz, $0.upperHz) }, from: (hint.lowerHz, hint.upperHz)).map {
                BandHint(label: hint.label, kind: hint.kind, lowerHz: $0.0, upperHz: $0.1)
            }
        }
        return (amateur + clipped).sorted { $0.lowerHz < $1.lowerHz }
    }()

    static let aeronauticalKHz: [(Int, Int)] = [
        (2_850, 3_155), (3_400, 3_500), (3_900, 3_950), (4_650, 4_750), (5_450, 5_730), (6_525, 6_765),
        (8_815, 9_040), (10_005, 10_100), (11_175, 11_400), (13_200, 13_360), (15_010, 15_100),
        (17_900, 18_030), (21_924, 22_000),
    ]

    static let maritimeKHz: [(Int, Int)] = [
        (2_045, 2_194), (4_063, 4_438), (6_200, 6_525), (8_195, 8_815), (12_230, 13_200), (16_360, 17_410),
        (18_780, 18_900), (19_680, 19_800), (22_000, 22_855), (25_070, 25_210), (26_100, 26_175),
    ]

    private static func mobile(_ kind: BandHint.Kind, kHz ranges: [(Int, Int)]) -> [BandHint] {
        ranges.map { low, high in
            // Aeronautical bands go by one decimal (2.8, 8.8, 10.0 MHz),
            // maritime ones by whole MHz (4, 8, 12 MHz).
            let mhz = Double(low) / 1_000
            let label = kind == .maritime
                ? "\(Int(mhz))"
                : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), mhz)
            return BandHint(label: "\(label) MHz", kind: kind, lowerHz: low * 1_000, upperHz: high * 1_000)
        }
    }

    /// The hints overlapping `lowHz…highHz`.
    public static func hints(lowHz: Double, highHz: Double) -> [BandHint] {
        all.filter { Double($0.upperHz) > lowHz && Double($0.lowerHz) < highHz }
    }

    /// Whether to show `band`'s plan (amateur) or its GMDSS frequencies
    /// (maritime) in a view `lowHz…highHz` wide: once
    /// the band covers at least `detailMinimumFraction` of the view, which
    /// is wide enough on screen for its segments to be read (20 m from a
    /// ~1 MHz span, 40 m from ~0.5 MHz). Below that, only the band's name.
    public static func showsPlan(for hint: BandHint, lowHz: Double, highHz: Double) -> Bool {
        let hasDetail = hint.band.map { !AmateurBandPlan.segments(for: $0).isEmpty }
            ?? (hint.kind == .maritime && !GMDSSFrequencies.markers(in: hint).isEmpty)
        guard hasDetail, highHz > lowHz else { return false }
        let visible = min(Double(hint.upperHz), highHz) - max(Double(hint.lowerHz), lowHz)
        guard visible > 0 else { return false }
        return Double(hint.upperHz - hint.lowerHz) / (highHz - lowHz) >= detailMinimumFraction
    }

    public static let detailMinimumFraction = 1.0 / 3.0

    private static func subtract(_ cuts: [(Int, Int)], from range: (Int, Int)) -> [(Int, Int)] {
        var pieces = [range]
        for cut in cuts {
            pieces = pieces.flatMap { piece -> [(Int, Int)] in
                guard cut.1 > piece.0, cut.0 < piece.1 else { return [piece] }
                var rest: [(Int, Int)] = []
                if cut.0 > piece.0 { rest.append((piece.0, cut.0)) }
                if cut.1 < piece.1 { rest.append((cut.1, piece.1)) }
                return rest
            }
        }
        return pieces
    }
}

/// The US license classes, lowest first. Novice HF is the same as
/// Technician's, so it isn't listed apart.
public enum USLicenseClass: Int, CaseIterable, Comparable, Sendable {
    case technician
    case general
    case advanced
    case extra

    var preset: PrivilegePreset {
        switch self {
        case .technician: .usTechnician
        case .general: .usGeneral
        case .advanced: .usAdvanced
        case .extra: .usExtra
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A piece of a US amateur band's plan: what may be sent there (by an
/// Extra, who may send everything anyone may) and the lowest class with
/// any privileges there.
public struct AmateurBandPlanSegment: Equatable, Sendable {
    public enum Usage: Equatable, Sendable {
        /// CW and data (RTTY, digital); no phone.
        case cwData
        /// Phone and image, CW too.
        case phone
        /// Every mode (160 m, 6 m above 50.1, 2 m above 144.1, 70 cm).
        case allModes
        /// CW only (bottom of 6 m and 2 m).
        case cwOnly
        /// One of 60 m's five channels (USB, CW, data).
        case channel
    }

    public let lowerHz: Int
    public let upperHz: Int
    public let usage: Usage
    public let lowestClass: USLicenseClass

    public init(lowerHz: Int, upperHz: Int, usage: Usage, lowestClass: USLicenseClass) {
        self.lowerHz = lowerHz
        self.upperHz = upperHz
        self.usage = usage
        self.lowestClass = lowestClass
    }
}

/// The US band plan of an amateur band, derived from the license tables
/// the transmit guardrail uses (`PrivilegePresets`, 47 CFR §97.301/305),
/// so the two can't disagree. The legal sub-bands only — not the ARRL's
/// voluntary plan inside them (digital watering holes, SSTV, …).
public enum AmateurBandPlan {
    /// With `showsTechnician` false (the operator isn't a Technician or
    /// Novice), Technician-and-up parts are labelled General, the lowest
    /// class that matters to them, and merge with their General neighbours.
    public static func segments(for band: Band, showsTechnician: Bool = true) -> [AmateurBandPlanSegment] {
        let plan = cache[band.name] ?? []
        guard !showsTechnician else { return plan }
        var merged: [AmateurBandPlanSegment] = []
        for segment in plan {
            let lowest = max(segment.lowestClass, .general)
            if let last = merged.last, last.upperHz == segment.lowerHz, last.usage == segment.usage,
               last.lowestClass == lowest, segment.usage != .channel {
                merged[merged.count - 1] = AmateurBandPlanSegment(lowerHz: last.lowerHz, upperHz: segment.upperHz,
                                                                  usage: last.usage, lowestClass: lowest)
            } else {
                merged.append(AmateurBandPlanSegment(lowerHz: segment.lowerHz, upperHz: segment.upperHz,
                                                     usage: segment.usage, lowestClass: lowest))
            }
        }
        return merged
    }

    private static let cache: [String: [AmateurBandPlanSegment]] = {
        let profiles = USLicenseClass.allCases.map { ($0, $0.preset.profile.segments) }
        let extra = USLicenseClass.extra.preset.profile.segments
        var result: [String: [AmateurBandPlanSegment]] = [:]
        for band in BandPlan.all {
            let low = band.range.lowerBound, high = band.range.upperBound
            var edges = Set([low, high])
            for (_, segments) in profiles {
                for segment in segments {
                    for edge in [segment.lowerHz, segment.upperHz] where edge > low && edge < high {
                        edges.insert(edge)
                    }
                }
            }
            let sorted = edges.sorted()
            var plan: [AmateurBandPlanSegment] = []
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let mid = (a + b) / 2
                let here = extra.filter { $0.lowerHz <= mid && mid < $0.upperHz }
                guard let usage = usage(of: here),
                      let lowest = profiles.first(where: { _, segments in
                          segments.contains { $0.lowerHz <= mid && mid < $0.upperHz }
                      })?.0
                else { continue }
                if let last = plan.last, last.upperHz == a, last.usage == usage, last.lowestClass == lowest,
                   usage != .channel {
                    plan[plan.count - 1] = AmateurBandPlanSegment(lowerHz: last.lowerHz, upperHz: b,
                                                                  usage: usage, lowestClass: lowest)
                } else {
                    plan.append(AmateurBandPlanSegment(lowerHz: a, upperHz: b, usage: usage, lowestClass: lowest))
                }
            }
            result[band.name] = plan
        }
        return result
    }()

    private static func usage(of segments: [PrivilegeSegment]) -> AmateurBandPlanSegment.Usage? {
        guard !segments.isEmpty else { return nil }
        if segments.contains(where: { $0.onlyModes != nil }) { return .channel }
        let emissions = segments.reduce(into: Set<TransmitEmission>()) { $0.formUnion($1.emissions) }
        if emissions == [.cw] { return .cwOnly }
        if emissions.contains(.phone) { return emissions.contains(.data) ? .allModes : .phone }
        return .cwData
    }
}

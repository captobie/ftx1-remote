import Foundation

/// A mark on the band bar's third line. Mostly the ARRL's voluntary HF band plan (arrl.org/band-plan,
/// read 2026-11-15): a range (RTTY/data, packet, DX window…) or a single
/// frequency (`lowerHz == upperHz`: SSTV, AM calling, QRP calling,
/// NCDXF beacons). These are conventions inside the legal sub-bands
/// (`AmateurBandPlan`), not rules. The ARRL's CW/phone lines that only
/// repeat the legal sub-bands are left out. 160–10 m, what a KiwiSDR
/// covers.
///
/// Also the usual digital-mode dial frequencies (USB; the signals sit
/// 0.2–3 kHz above): FT8, FT4, JS8Call, WSPR and PSK31 — not part of the
/// ARRL plan, but where those modes are actually found (WSJT-X's and
/// JS8Call's defaults).
public struct BandPlanMarker: Equatable, Sendable {
    public enum Kind: Equatable, Sendable, CaseIterable {
        case data
        case dataDX
        case packet
        case dxWindow
        case qrpCW
        case qrpSSB
        case sstv
        case amCalling
        case am
        case beacons
        case ncdxfBeacons
        case experimental
        case satellite
        case repeaterInputs
        case repeaterOutputs
        case fmSimplex
        case ft8
        case ft4
        case js8
        case wspr
        case psk31
        case dscDistress
        case voiceDistress
        case nbdpDistress
        case navtex
        case msi

        /// Which spot label gets its place first when they crowd: the
        /// busiest digital modes, then the ARRL's spots, then the rest.
        public var labelPriority: Int {
            switch self {
            case .ft8, .dscDistress, .voiceDistress: 0
            case .ft4, .nbdpDistress, .navtex: 1
            case .js8, .wspr, .psk31: 3
            default: 2
            }
        }

        public var isDigitalMode: Bool {
            switch self {
            case .ft8, .ft4, .js8, .wspr, .psk31: true
            default: false
            }
        }
    }

    public let lowerHz: Int
    public let upperHz: Int
    public let kind: Kind

    public var isSpot: Bool { lowerHz == upperHz }

    public init(lowerHz: Int, upperHz: Int, kind: Kind) {
        self.lowerHz = lowerHz
        self.upperHz = upperHz
        self.kind = kind
    }
}

public enum ARRLBandPlan {
    /// The band's marks, ranges first (so spots draw on top) by frequency,
    /// then spots by `labelPriority` and frequency (the order their labels
    /// are placed in).
    public static func markers(for band: Band) -> [BandPlanMarker] {
        let marks = all.filter { band.range.contains($0.lowerHz) && band.range.contains($0.upperHz) }
        return marks.filter { !$0.isSpot }.sorted { $0.lowerHz < $1.lowerHz }
            + marks.filter(\.isSpot).sorted {
                ($0.kind.labelPriority, $0.lowerHz) < ($1.kind.labelPriority, $1.lowerHz)
            }
    }

    static func range(_ lowKHz: Double, _ highKHz: Double, _ kind: BandPlanMarker.Kind)
        -> BandPlanMarker {
        BandPlanMarker(lowerHz: Int((lowKHz * 1_000).rounded()), upperHz: Int((highKHz * 1_000).rounded()),
                           kind: kind)
    }

    static func spot(_ kHz: Double, _ kind: BandPlanMarker.Kind) -> BandPlanMarker {
        range(kHz, kHz, kind)
    }

    static let all: [BandPlanMarker] = [
        // 160 m
        range(1_800, 1_810, .data), spot(1_810, .qrpCW), spot(1_910, .qrpSSB),
        range(1_995, 2_000, .experimental), range(1_999, 2_000, .beacons),
        // 80 m
        range(3_500, 3_510, .dxWindow), spot(3_560, .qrpCW), range(3_570, 3_600, .data), spot(3_590, .dataDX),
        range(3_790, 3_800, .dxWindow), spot(3_845, .sstv), spot(3_885, .amCalling), spot(3_985, .qrpSSB),
        // 40 m
        spot(7_030, .qrpCW), spot(7_040, .dataDX), range(7_080, 7_125, .data), spot(7_171, .sstv),
        spot(7_285, .qrpSSB), spot(7_290, .amCalling),
        // 30 m
        range(10_130, 10_140, .data), range(10_140, 10_150, .packet),
        // 20 m
        spot(14_060, .qrpCW), range(14_070, 14_095, .data), range(14_095, 14_099.5, .packet),
        spot(14_100, .ncdxfBeacons), range(14_100.5, 14_112, .packet), spot(14_230, .sstv),
        spot(14_285, .qrpSSB), spot(14_286, .amCalling),
        // 17 m
        range(18_100, 18_105, .data), range(18_105, 18_110, .packet), spot(18_110, .ncdxfBeacons),
        // 15 m
        spot(21_060, .qrpCW), range(21_070, 21_110, .data), spot(21_150, .ncdxfBeacons), spot(21_340, .sstv),
        spot(21_385, .qrpSSB),
        // 12 m
        range(24_920, 24_925, .data), range(24_925, 24_930, .packet), spot(24_930, .ncdxfBeacons),
        // 10 m
        spot(28_060, .qrpCW), range(28_070, 28_150, .data), range(28_200, 28_300, .beacons),
        spot(28_200, .ncdxfBeacons), spot(28_385, .qrpSSB), spot(28_680, .sstv), range(29_000, 29_200, .am),
        range(29_300, 29_510, .satellite), range(29_520, 29_590, .repeaterInputs), spot(29_600, .fmSimplex),
        range(29_610, 29_700, .repeaterOutputs),
    ] + digital

    private static let digital: [BandPlanMarker] = [
        // FT8
        spot(1_840, .ft8), spot(3_573, .ft8), spot(5_357, .ft8), spot(7_074, .ft8), spot(10_136, .ft8),
        spot(14_074, .ft8), spot(18_100, .ft8), spot(21_074, .ft8), spot(24_915, .ft8), spot(28_074, .ft8),
        spot(50_313, .ft8),
        // FT4
        spot(3_575, .ft4), spot(7_047.5, .ft4), spot(10_140, .ft4), spot(14_080, .ft4), spot(18_104, .ft4),
        spot(21_140, .ft4), spot(24_919, .ft4), spot(28_180, .ft4), spot(50_318, .ft4),
        // JS8Call
        spot(1_842, .js8), spot(3_578, .js8), spot(7_078, .js8), spot(10_130, .js8), spot(14_078, .js8),
        spot(18_104, .js8), spot(21_078, .js8), spot(24_922, .js8), spot(28_078, .js8),
        // WSPR
        spot(1_836.6, .wspr), spot(3_568.6, .wspr), spot(7_038.6, .wspr), spot(10_138.7, .wspr),
        spot(14_095.6, .wspr), spot(18_104.6, .wspr), spot(21_094.6, .wspr), spot(24_924.6, .wspr),
        spot(28_124.6, .wspr), spot(50_293, .wspr),
        // PSK31
        spot(3_580, .psk31), spot(7_070, .psk31), spot(10_142, .psk31), spot(14_070, .psk31),
        spot(18_100, .psk31), spot(21_070, .psk31), spot(24_920, .psk31), spot(28_120, .psk31),
    ]
}

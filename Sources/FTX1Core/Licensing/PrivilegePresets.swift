import Foundation

/// The built-in privilege tables: the US license classes (47 CFR §97.301
/// and §97.305, as of 2026-10; power limits left out, the FTX-1 can't
/// exceed them) and each ITU region's amateur allocations as outer band
/// edges with every mode allowed — the latter a starting point for a
/// country's own table (Custom), not that country's rules.
///
/// Only the bands the FTX-1 transmits on (160 m–70 cm). US 70 cm is
/// 420–450 MHz without the Line A / Canadian-border exclusions, and US
/// 60 m is the five 2.8 kHz channels (USB, CW, data; centres 5332, 5348,
/// 5358.5, 5373, 5405 kHz).
public enum PrivilegePreset: String, CaseIterable, Sendable, Hashable {
    case usExtra = "us.extra"
    case usAdvanced = "us.advanced"
    case usGeneral = "us.general"
    case usTechnician = "us.technician"
    case usNovice = "us.novice"
    case ituRegion1 = "itu.region1"
    case ituRegion2 = "itu.region2"
    case ituRegion3 = "itu.region3"

    public var displayName: String {
        switch self {
        case .usExtra: "US Amateur Extra"
        case .usAdvanced: "US Advanced"
        case .usGeneral: "US General"
        case .usTechnician: "US Technician"
        case .usNovice: "US Novice"
        case .ituRegion1: "ITU Region 1 allocation"
        case .ituRegion2: "ITU Region 2 allocation"
        case .ituRegion3: "ITU Region 3 allocation"
        }
    }

    public var isUS: Bool {
        switch self {
        case .usExtra, .usAdvanced, .usGeneral, .usTechnician, .usNovice: true
        case .ituRegion1, .ituRegion2, .ituRegion3: false
        }
    }

    public var profile: PrivilegeProfile {
        PrivilegeProfile(name: displayName, segments: segments)
    }

    private var segments: [PrivilegeSegment] {
        switch self {
        case .usExtra:
            Self.usHF(
                band80: (cwData: 3_500, phone: 3_600), band40: (cwData: 7_000, phone: 7_125),
                band20: (cwData: 14_000, phone: 14_150), band15: (cwData: 21_000, phone: 21_200)
            ) + Self.usVHF
        case .usAdvanced:
            Self.usHF(
                band80: (cwData: 3_525, phone: 3_700), band40: (cwData: 7_025, phone: 7_125),
                band20: (cwData: 14_025, phone: 14_175), band15: (cwData: 21_025, phone: 21_225)
            ) + Self.usVHF
        case .usGeneral:
            Self.usHF(
                band80: (cwData: 3_525, phone: 3_800), band40: (cwData: 7_025, phone: 7_175),
                band20: (cwData: 14_025, phone: 14_225), band15: (cwData: 21_025, phone: 21_275)
            ) + Self.usVHF
        case .usTechnician:
            Self.usNoviceHF + Self.usVHF
        case .usNovice:
            // Novice VHF/UHF is 222 MHz and 1.25 GHz, neither on the FTX-1.
            Self.usNoviceHF
        case .ituRegion1:
            Self.allModes(kHz: [
                (1_810, 2_000), (3_500, 3_800), (5_351.5, 5_366.5), (7_000, 7_200),
                (10_100, 10_150), (14_000, 14_350), (18_068, 18_168), (21_000, 21_450),
                (24_890, 24_990), (28_000, 29_700), (50_000, 50_500), (144_000, 146_000),
                (430_000, 440_000),
            ])
        case .ituRegion2:
            Self.allModes(kHz: [
                (1_800, 2_000), (3_500, 4_000), (5_351.5, 5_366.5), (7_000, 7_300),
                (10_100, 10_150), (14_000, 14_350), (18_068, 18_168), (21_000, 21_450),
                (24_890, 24_990), (28_000, 29_700), (50_000, 54_000), (144_000, 148_000),
                (420_000, 450_000),
            ])
        case .ituRegion3:
            Self.allModes(kHz: [
                (1_800, 2_000), (3_500, 3_900), (5_351.5, 5_366.5), (7_000, 7_200),
                (10_100, 10_150), (14_000, 14_350), (18_068, 18_168), (21_000, 21_450),
                (24_890, 24_990), (28_000, 29_700), (50_000, 54_000), (144_000, 148_000),
                (430_000, 440_000),
            ])
        }
    }

    private static let cwData: Set<TransmitEmission> = [.cw, .data]
    private static let cwPhone: Set<TransmitEmission> = [.cw, .phone]
    private static let all = Set(TransmitEmission.allCases)

    private static func segment(_ lowerKHz: Double, _ upperKHz: Double, _ emissions: Set<TransmitEmission>,
                                onlyModes: Set<RigMode>? = nil) -> PrivilegeSegment {
        PrivilegeSegment(lowerHz: Int((lowerKHz * 1_000).rounded()), upperHz: Int((upperKHz * 1_000).rounded()),
                         emissions: emissions, onlyModes: onlyModes)
    }

    private static func allModes(kHz ranges: [(Double, Double)]) -> [PrivilegeSegment] {
        ranges.map { segment($0.0, $0.1, all) }
    }

    /// General, Advanced and Extra HF: the four bands whose sub-band edges
    /// differ by class are passed in (kHz: start of CW/data, start of
    /// phone), the rest are the same for all three.
    private static func usHF(band80: (cwData: Double, phone: Double), band40: (cwData: Double, phone: Double),
                             band20: (cwData: Double, phone: Double), band15: (cwData: Double, phone: Double))
        -> [PrivilegeSegment] {
        [
            segment(1_800, 2_000, all),
            segment(band80.cwData, 3_600, cwData), segment(band80.phone, 4_000, cwPhone),
        ] + us60mChannels + [
            segment(band40.cwData, 7_125, cwData), segment(band40.phone, 7_300, cwPhone),
            segment(10_100, 10_150, cwData),
            segment(band20.cwData, 14_150, cwData), segment(band20.phone, 14_350, cwPhone),
            segment(18_068, 18_110, cwData), segment(18_110, 18_168, cwPhone),
            segment(band15.cwData, 21_200, cwData), segment(band15.phone, 21_450, cwPhone),
            segment(24_890, 24_930, cwData), segment(24_930, 24_990, cwPhone),
            segment(28_000, 28_300, cwData), segment(28_300, 29_700, cwPhone),
        ]
    }

    /// Each channel's 2.8 kHz around its centre: USB with the dial 1.5 kHz
    /// below the centre, CW and data at the centre.
    private static let us60mChannels: [PrivilegeSegment] = [5_332, 5_348, 5_358.5, 5_373, 5_405].map {
        segment($0 - 1.4, $0 + 1.4, all, onlyModes: [.usb, .cw, .dataUSB])
    }

    /// Novice and Technician HF (the same for both).
    private static let usNoviceHF: [PrivilegeSegment] = [
        segment(3_525, 3_600, [.cw]),
        segment(7_025, 7_125, [.cw]),
        segment(21_025, 21_200, [.cw]),
        segment(28_000, 28_300, cwData),
        segment(28_300, 28_500, cwPhone, onlyModes: [.usb, .lsb, .cw]),
    ]

    /// Technician and up, 6 m–70 cm: CW only at the bottom of 6 m and 2 m.
    private static let usVHF: [PrivilegeSegment] = [
        segment(50_000, 50_100, [.cw]), segment(50_100, 54_000, all),
        segment(144_000, 144_100, [.cw]), segment(144_100, 148_000, all),
        segment(420_000, 450_000, all),
    ]
}

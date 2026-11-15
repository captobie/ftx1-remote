import Foundation

/// The GMDSS distress and safety frequencies (ITU Radio Regulations
/// Appendix 15) and the maritime safety information broadcasts, for the
/// band bar's marker line inside the maritime bands. All are the assigned
/// (carrier) frequencies, as listed by the ITU: to hear DSC or NBDP in
/// USB, tune the dial 1.7 kHz below (the 1615/1785 Hz tones of a 170 Hz
/// FSK signal centred on 1700 Hz); voice is USB on the dial.
///
/// - DSC distress: digital selective calling alerts (100 Bd FSK).
/// - Voice distress: radiotelephony distress and safety (2182 kHz etc.).
/// - NBDP distress: narrow-band direct printing (SITOR/telex) follow-up.
/// - NAVTEX: 518 kHz (international, English), 490 kHz (national
///   languages), 4209.5 kHz (HF) — navigational and weather warnings,
///   SITOR-B 100 Bd.
/// - MSI: HF maritime safety information by NBDP.
///
/// Also VHF channel 16 (voice) and 70 (DSC), for completeness.
public enum GMDSSFrequencies {
    public static let all: [BandPlanMarker] = {
        typealias M = ARRLBandPlan
        let dsc = [2_187.5, 4_207.5, 6_312, 8_414.5, 12_577, 16_804.5].map { M.spot($0, .dscDistress) }
        let voice = [2_182, 4_125, 6_215, 8_291, 12_290, 16_420].map { M.spot($0, .voiceDistress) }
        let nbdp = [2_174.5, 4_177.5, 6_268, 8_376.5, 12_520, 16_695].map { M.spot($0, .nbdpDistress) }
        let navtex = [490, 518, 4_209.5].map { M.spot($0, .navtex) }
        let msi = [4_210, 6_314, 8_416.5, 12_579, 16_806.5, 19_680.5, 22_376, 26_100.5].map { M.spot($0, .msi) }
        let vhf = [M.spot(156_800, .voiceDistress), M.spot(156_525, .dscDistress)]
        return dsc + voice + nbdp + navtex + msi + vhf
    }()

    /// The frequencies inside `hint`, by label priority (distress first)
    /// then frequency, the order their labels are placed in.
    public static func markers(in hint: BandHint) -> [BandPlanMarker] {
        all.filter { $0.lowerHz >= hint.lowerHz && $0.lowerHz <= hint.upperHz }
            .sorted { ($0.kind.labelPriority, $0.lowerHz) < ($1.kind.labelPriority, $1.lowerHz) }
    }
}

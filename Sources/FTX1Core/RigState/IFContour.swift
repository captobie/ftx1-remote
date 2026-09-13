import Foundation

/// Value spaces for the FTX-1's raw "CO" CAT command, which carries two
/// complementary IF-DSP functions on four MAIN-side sub-functions (P2):
/// CONTOUR on/off (`CO00`) and frequency (`CO01`, 10-3200 Hz, 4-digit Hz),
/// and APF on/off (`CO02`) and offset (`CO03`, a 4-digit code 0000-0050
/// standing for −250…+250 Hz around the CW pitch). See
/// `RigState.contourEnabled`/`.contourHz`/`.apfEnabled`/`.apfHz`.
///
/// The operating manual says CONTOUR "does not work in CW-L and CW-U" and
/// APF "only works in CW-L and CW-U", so the two never apply at the same
/// time — `face(for:)` picks which one a single UI slot should show.
///
/// Every "CO" field is 4 digits, including the on/off ones (0000/0001),
/// so — like "BP" (`IFNotch`) — they go through `getRawInt`/`setRawInt(
/// digits: 4)` and never `getRawBool`, which would read "0001" as off.
public enum IFContour {
    public enum Face: Hashable {
        case contour
        case apf
    }

    public static let contourRangeHz: ClosedRange<Int> = 10...3200
    public static let apfRangeHz: ClosedRange<Int> = -250...250
    public static let stepHz = 10

    /// Clamps into `contourRangeHz` and rounds to the nearest 10 Hz.
    public static func snappedContourHz(_ hz: Int) -> Int {
        let clamped = min(max(hz, contourRangeHz.lowerBound), contourRangeHz.upperBound)
        let rounded = Int((Double(clamped) / Double(stepHz)).rounded()) * stepHz
        return min(max(rounded, contourRangeHz.lowerBound), contourRangeHz.upperBound)
    }

    /// Clamps into `apfRangeHz` and rounds to the nearest 10 Hz, ties away
    /// from zero (same convention as `IFShift.snapped`).
    public static func snappedAPFHz(_ hz: Int) -> Int {
        let clamped = min(max(hz, apfRangeHz.lowerBound), apfRangeHz.upperBound)
        let rounded = Int((Double(clamped) / Double(stepHz)).rounded(.toNearestOrAwayFromZero)) * stepHz
        return min(max(rounded, apfRangeHz.lowerBound), apfRangeHz.upperBound)
    }

    /// The "CO03" wire code (0-50) for a snapped APF offset: −250 Hz is
    /// 0000, 0 Hz is 0025, +250 Hz is 0050.
    public static func apfCode(forHz hz: Int) -> Int {
        snappedAPFHz(hz) / stepHz + 25
    }

    /// APF offset in Hz for a "CO03" wire code, nil outside 0-50.
    public static func apfHz(forCode code: Int) -> Int? {
        guard (0...50).contains(code) else { return nil }
        return (code - 25) * stepHz
    }

    /// "1240 Hz"; "—" for nil.
    public static func contourLabel(_ hz: Int?) -> String {
        guard let hz else { return "—" }
        return "\(hz) Hz"
    }

    /// "+120 Hz" / "−120 Hz" / "0 Hz"; "—" for nil. Same formatting as
    /// IF SHIFT's signed label.
    public static func apfLabel(_ hz: Int?) -> String {
        IFShift.label(hz)
    }

    /// Modes where the rig honors CONTOUR: the variable-width SSB/RTTY/
    /// DATA modes. CW is excluded per the operating manual; AM/FM on the
    /// same fixed-width-DSP assumption as SHIFT/NOTCH (`IFShift.
    /// isSupported`), pending hardware confirmation.
    public static func contourSupported(mode: RigMode) -> Bool {
        switch mode {
        case .usb, .lsb, .rtty, .dataUSB: true
        case .cw, .am, .fm, .dataFM, .c4fm, .unknown: false
        }
    }

    /// APF only works in CW per the operating manual.
    public static func apfSupported(mode: RigMode) -> Bool {
        mode == .cw
    }

    /// Which of the two functions a single UI slot should present in
    /// `mode`: APF in CW, CONTOUR everywhere else that has an IF-DSP (the
    /// contour face is shown disabled in AM/FM), nothing for C4FM/unknown.
    public static func face(for mode: RigMode) -> Face? {
        switch mode {
        case .cw: .apf
        case .c4fm, .unknown: nil
        case .usb, .lsb, .rtty, .dataUSB, .am, .fm, .dataFM: .contour
        }
    }
}

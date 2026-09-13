import Foundation

/// IF SHIFT's value space (the FTX-1's raw "IS" CAT command, see
/// `RigState.ifShiftHz`): the DSP passband can be slid ±1200 Hz from
/// center in 20 Hz steps (operating manual p.34, CAT manual "IS" table).
/// Shared so the Mac UI, `CommandQueue`, and any future remote client all
/// agree on what a legal value is.
public enum IFShift {
    public static let range: ClosedRange<Int> = -1200...1200
    public static let stepHz = 20

    /// Whether the rig honors IF SHIFT in `mode`. Hardware-confirmed
    /// 2026-09-13: the FTX-1 accepts the "IS" write in AM and FM but the
    /// setting has no effect there (fixed-width modes, same set
    /// `FilterWidthTable.isAdjustable` excludes), so the UI disables the
    /// control rather than offering a knob that does nothing. C4FM/unknown
    /// have no IF shift at all.
    public static func isSupported(mode: RigMode) -> Bool {
        switch mode {
        case .usb, .lsb, .cw, .rtty, .dataUSB: true
        case .am, .fm, .dataFM, .c4fm, .unknown: false
        }
    }

    /// Clamps `hz` into `range` and rounds it to the nearest multiple of
    /// `stepHz` (ties away from zero), so a slider drag or a remote client
    /// can never hand the rig a value it would silently reject or clamp.
    public static func snapped(_ hz: Int) -> Int {
        let clamped = min(max(hz, range.lowerBound), range.upperBound)
        let step = Double(stepHz)
        let rounded = Int((Double(clamped) / step).rounded(.toNearestOrAwayFromZero)) * stepHz
        return min(max(rounded, range.lowerBound), range.upperBound)
    }

    /// "+240 Hz" / "−240 Hz" / "0 Hz"; "—" for nil (no poll yet). Uses a
    /// real minus sign for display, unlike the ASCII "-" the CAT wire
    /// format uses.
    public static func label(_ hz: Int?) -> String {
        guard let hz else { return "—" }
        if hz == 0 { return "0 Hz" }
        return hz < 0 ? "−\(-hz) Hz" : "+\(hz) Hz"
    }
}

import Foundation

/// The manual IF NOTCH's value space (the FTX-1's raw "BP" CAT command —
/// see `RigState.notchEnabled`/`.notchHz`): a single notch placed anywhere
/// from 10 to 3200 Hz within the passband, in 10 Hz steps. Distinct from
/// the auto notch (DNF, raw "BC", `RigState.dnfEnabled`) on the MENU grid.
///
/// "BP"'s frequency sub-function carries the value as a 3-digit *code* of
/// 10 Hz units (001-320), not Hz — `code(forHz:)`/`hz(forCode:)` convert.
/// Its on/off sub-function is also a 3-digit field (000/001), which is why
/// `CommandQueue`/`HubService` go through `getRawInt`/`setRawInt(digits:
/// 3)` for both rather than `getRawBool` (which would read "BP00001;" as
/// *off*, seeing only the leading "0").
public enum IFNotch {
    public static let rangeHz: ClosedRange<Int> = 10...3200
    public static let stepHz = 10

    /// Clamps into `rangeHz` and rounds to the nearest 10 Hz.
    public static func snappedHz(_ hz: Int) -> Int {
        let clamped = min(max(hz, rangeHz.lowerBound), rangeHz.upperBound)
        let rounded = Int((Double(clamped) / Double(stepHz)).rounded()) * stepHz
        return min(max(rounded, rangeHz.lowerBound), rangeHz.upperBound)
    }

    /// The "BP01" wire code (1-320) for a snapped Hz value.
    public static func code(forHz hz: Int) -> Int {
        snappedHz(hz) / stepHz
    }

    /// Hz for a "BP01" wire code, nil outside the documented 001-320.
    public static func hz(forCode code: Int) -> Int? {
        guard (1...320).contains(code) else { return nil }
        return code * stepHz
    }

    /// "1240 Hz"; "—" for nil (no poll yet).
    public static func label(_ hz: Int?) -> String {
        guard let hz else { return "—" }
        return "\(hz) Hz"
    }

    /// Whether the rig honors the manual notch in `mode`. Starts from the
    /// same set as IF SHIFT (`IFShift.isSupported`) — both live in the same
    /// IF-DSP block, which the rig bypasses in the fixed-width AM/FM modes
    /// — pending hardware confirmation; split this out if the rig turns
    /// out to honor one and not the other.
    public static func isSupported(mode: RigMode) -> Bool {
        IFShift.isSupported(mode: mode)
    }
}

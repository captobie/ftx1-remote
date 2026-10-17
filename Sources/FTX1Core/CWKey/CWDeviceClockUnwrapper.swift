import Foundation

/// Extends the key interface's 32-bit `millis()` (wraps every ~49.7 days)
/// into a continuous 64-bit millisecond count. Each sample is taken as the
/// nearest step from the previous one — the signed 32-bit difference — so a
/// wrap between two samples reads as the small forward step it is.
///
/// A step backwards of more than `resetThresholdMs` can't be a wrap or the
/// reordering of two lines; it means the device restarted (its banner
/// lost), so the count is rebased and `unwrap` reports it — the clock sync
/// must be reset then too. The device's banner resets this explicitly.
public struct CWDeviceClockUnwrapper: Sendable {
    public static let resetThresholdMs: Int64 = 1000

    private var last: UInt32?
    private var extended: Int64 = 0

    public init() {}

    /// The extended time of `deviceMs`, and whether the device clock was
    /// found to have restarted (the value then restarts the count).
    public mutating func unwrap(_ deviceMs: UInt32) -> (ms: Int64, restarted: Bool) {
        guard let last else {
            self.last = deviceMs
            extended = Int64(deviceMs)
            return (extended, false)
        }
        let step = Int64(Int32(bitPattern: deviceMs &- last))
        if step < -Self.resetThresholdMs {
            self.last = deviceMs
            extended = Int64(deviceMs)
            return (extended, true)
        }
        self.last = deviceMs
        extended += step
        return (extended, false)
    }

    public mutating func reset() {
        last = nil
        extended = 0
    }
}

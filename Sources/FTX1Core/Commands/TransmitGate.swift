import Foundation

/// The Mac's transmit gate (`HubService.send(_:)`'s two checks) for routes
/// that bypass the hub — the iPad's Pi direct, so far. A transmit action
/// goes through only while Enable Transmit is on AND the transmitting side
/// is inside an amateur allocation (`BandPlan`). Same shape as Windows'
/// `TransmitGate.BlockReason`. Only the keying direction is gated:
/// unkeying must always get through.
public enum TransmitGate {
    /// nil when keying may go ahead, otherwise why not (shown to the user).
    /// A frequency of 0 (not read yet) is outside every band, so nothing
    /// keys before the first poll.
    ///
    /// With `privileges` (the Mac's license-class guardrail), the
    /// transmitting side's signal — frequency *and* mode, see
    /// `PrivilegeProfile.allows` — also has to fit inside them. The
    /// amateur-band check stays the outer limit, so a mistyped custom
    /// segment can't open a broadcast band.
    public static func blockReason(transmitEnabled: Bool, state: RigState,
                                   privileges: PrivilegeProfile? = nil) -> String? {
        guard transmitEnabled else { return "Transmit disabled" }
        let hz = transmitFrequencyHz(of: state)
        guard BandPlan.band(containing: hz) != nil else {
            return "Transmit disabled: outside an amateur band"
        }
        if let privileges {
            let mode = transmitMode(of: state)
            guard mode != .unknown else { return "Transmit disabled: the transmitting side's mode isn't known yet" }
            guard privileges.allows(dialHz: hz, mode: mode) else {
                return "Transmit disabled: \(mode.displayName) on \(formatMHz(hz)) MHz is outside \(privileges.name) privileges"
            }
        }
        return nil
    }

    /// MAIN's or SUB's mode, whichever transmits (`.unknown` for SUB until
    /// it has been read).
    public static func transmitMode(of state: RigState) -> RigMode {
        transmitsOnSub(state) ? (state.secondaryMode ?? .unknown) : state.mode
    }

    private static func transmitsOnSub(_ state: RigState) -> Bool {
        state.splitEnabled == true || state.txSide == .sub
    }

    /// "14.225.000"-style, the VFO boxes' grouping.
    static func formatMHz(_ hz: Int) -> String {
        let mhz = hz / 1_000_000, khz = (hz / 1_000) % 1_000, rest = hz % 1_000
        return String(format: "%d.%03d.%03d", mhz, khz, rest)
    }

    /// MAIN's or SUB's frequency, whichever transmits — the VFO boxes'
    /// TXRX rule (`RigState.mainTxRxLabel`).
    public static func transmitFrequencyHz(of state: RigState) -> Int {
        if transmitsOnSub(state) {
            return state.secondaryFrequencyHz ?? 0
        }
        return state.frequencyHz
    }
}

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
        guard transmitEnabled else { return String(localized: "common.transmitDisabled", bundle: .module) }
        let hz = transmitFrequencyHz(of: state)
        guard BandPlan.band(containing: hz) != nil else {
            return String(localized: "common.transmitDisabledOutsideAn", bundle: .module)
        }
        if let privileges {
            let mode = transmitMode(of: state)
            guard mode != .unknown else { return String(localized: "transmitGate.transmitDisabledTheTransmitting", bundle: .module) }
            guard privileges.allows(dialHz: hz, mode: mode) else {
                return String(localized: "transmitGate.transmitDisabledOnMHz \(mode.displayName) \(formatMHz(hz)) \(privileges.name)", bundle: .module)
            }
        }
        return nil
    }

    /// The transmitting mode — `RigState.transmitMode` (`.unknown` for SUB
    /// until it has been read).
    public static func transmitMode(of state: RigState) -> RigMode {
        state.transmitMode ?? .unknown
    }

    /// "14.225.000"-style, the VFO boxes' grouping.
    static func formatMHz(_ hz: Int) -> String {
        FrequencyFormat.dotted(hz)
    }

    /// The transmitting frequency — `RigState.transmitFrequencyHz`.
    public static func transmitFrequencyHz(of state: RigState) -> Int {
        state.transmitFrequencyHz ?? 0
    }
}

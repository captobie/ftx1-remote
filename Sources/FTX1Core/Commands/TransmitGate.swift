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
    public static func blockReason(transmitEnabled: Bool, state: RigState) -> String? {
        guard transmitEnabled else { return "Transmit disabled" }
        guard BandPlan.band(containing: transmitFrequencyHz(of: state)) != nil else {
            return "Transmit disabled: outside an amateur band"
        }
        return nil
    }

    /// MAIN's or SUB's frequency, whichever transmits — the VFO boxes'
    /// TXRX rule (`RigState.mainTxRxLabel`).
    public static func transmitFrequencyHz(of state: RigState) -> Int {
        if state.splitEnabled == true || state.txSide == .sub {
            return state.secondaryFrequencyHz ?? 0
        }
        return state.frequencyHz
    }
}

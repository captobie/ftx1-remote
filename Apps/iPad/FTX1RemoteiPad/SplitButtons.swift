import FTX1Core
import SwiftUI

/// The Mac's SPLIT button and quick split (`ContentView.splitButton`) for
/// both iPad screens' top rows: SPLIT toggles the rig's split (raw "ST", see
/// `RigState.splitEnabled`), the chevron turns it on with the TX VFO at
/// MAIN's frequency plus an offset. Both refused while transmitting or
/// scanning (`RigState.canChangeSplit`).
struct SplitButtons: View {
    let state: RigState
    let send: (RigCommand) -> Void
    let quickSplit: (Int) -> Void

    /// Quick split offsets, kHz: the usual "up 1"/"up 5" and friends, as on
    /// the Mac.
    private static let offsetsKHz = [1, 2, 3, 5, 10, -1, -5]

    var body: some View {
        let isOn = state.splitEnabled == true
        HStack(spacing: 4) {
            Button {
                send(.setSplit(!isOn))
            } label: {
                Text("SPLIT")
                    .fontWeight(isOn ? .bold : .regular)
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
            }
            .tint(isOn ? .orange : nil)
            .disabled(!state.canChangeSplit)

            Menu {
                ForEach(Self.offsetsKHz, id: \.self) { kHz in
                    if kHz > 0 {
                        Button("splitButtons.quickSplitUp \(kHz)") { quickSplit(kHz * 1000) }
                    } else {
                        Button("splitButtons.quickSplitDown \(-kHz)") { quickSplit(kHz * 1000) }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(!state.canQuickSplit)
            .accessibilityLabel("splitButtons.quickSplit")
        }
    }
}

/// The left VFO box in split: the rig's split TX VFO instead of the SUB
/// receiver — "FB" with MAIN's mode, no memory channel, frequency entry
/// writes "FB" (see `RigState.splitEnabled`).
struct SplitVFOBox: View {
    let state: RigState
    let onSetFrequency: ((Int) -> Void)?

    var body: some View {
        VFODisplayBox(label: "SPLIT", frequencyHz: state.secondaryFrequencyHz, isActive: true, mode: state.mode.displayName, txRxLabel: state.subTxRxLabel, onSetFrequency: onSetFrequency)
    }
}

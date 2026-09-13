import SwiftUI

/// NARROW (raw "NA" command): a single toggle button labeled "N/W" to
/// match the rig's own key, in the second Filter row, fill = on like the
/// Notch/Contour buttons.
/// Generic over `RigController` like the other Filter-row views.
///
/// NAR snaps the DSP passband to the mode's preset narrow width — the NAR
/// WIDTH values in Deep Settings → RADIO/CW SETTING for SSB/DATA/RTTY/CW,
/// and the fixed second row of `FilterWidthTable` for AM (9000 → 6000 Hz)
/// and FM (16000 → 9000 Hz). In AM/FM it is the *only* way to change
/// width, which is why this stays enabled there while `FilterWidthControl`
/// is read-only. The Width readout follows a NAR press within ~2 s via
/// `HubService`'s one-off "SH0" re-read rather than the slow poll tier.
///
/// Hidden for C4FM/unknown (no IF filter).
public struct NarrowControl<Controller: RigController>: View {
    @EnvironmentObject private var hub: Controller

    public init() {}

    public var body: some View {
        let mode = hub.rigState.mode
        if mode != .c4fm && mode != .unknown {
            let isOn = hub.rigState.narrowEnabled ?? false
            let button = Button("N/W") {
                hub.send(.setNarrow(!isOn))
            }
            .disabled(hub.rigState.narrowEnabled == nil)
            .help("Narrow filter on/off")
            if isOn {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }
}

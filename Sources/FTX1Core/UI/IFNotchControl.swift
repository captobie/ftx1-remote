import SwiftUI

/// Manual IF NOTCH: an on/off button, a frequency slider, and a Hz label,
/// third control in the Filter row after `FilterWidthControl` and
/// `IFShiftControl`. Generic over `RigController` like those, so it can
/// drop into the iPad's `ContentView` later.
///
/// This is the rig's *manual* notch (raw "BP" command, one notch the
/// operator places on an interfering carrier), not the auto notch/DNF
/// button on the MENU grid (raw "BC"). See `IFNotch` for the value space
/// and for why its on/off state is a 3-digit raw field rather than a
/// plain boolean.
///
/// Same drag semantics as `IFShiftControl`: the slider and label track a
/// local value while dragging and the command goes out on release. Placing
/// the notch while it's off also turns it on — sending the frequency first
/// so the notch appears where it was dropped rather than at its old spot
/// — since dragging it onto a carrier is the whole point of the control.
/// The "Notch" button's fill shows the on/off state.
///
/// Hidden for C4FM/unknown; disabled in AM/FM on the same assumption as
/// SHIFT (`IFNotch.isSupported`), pending hardware confirmation.
public struct IFNotchControl<Controller: RigController>: View {
    @EnvironmentObject private var hub: Controller
    @State private var dragValue: Double?

    public init() {}

    public var body: some View {
        let mode = hub.rigState.mode
        if mode != .c4fm && mode != .unknown {
            let isOn = hub.rigState.notchEnabled ?? false
            HStack(spacing: 6) {
                toggleButton(isOn: isOn)

                Slider(
                    value: sliderValue,
                    in: Double(IFNotch.rangeHz.lowerBound)...Double(IFNotch.rangeHz.upperBound),
                    step: Double(IFNotch.stepHz),
                    onEditingChanged: { editing in
                        if !editing, let dragValue {
                            hub.send(.setNotchFrequency(hz: IFNotch.snappedHz(Int(dragValue))))
                            if hub.rigState.notchEnabled != true {
                                hub.send(.setNotch(true))
                            }
                            self.dragValue = nil
                        }
                    }
                )
                .frame(width: 160)

                Text(IFNotch.label(displayedHz))
                    .monospacedDigit()
                    .frame(minWidth: 58, alignment: .trailing)
            }
            .opacity(isOn ? 1 : 0.7)
            .disabled(!IFNotch.isSupported(mode: mode))
        }
    }

    /// Bordered when off, filled (prominent) when on — `buttonStyle` can't
    /// be chosen conditionally on one `Button`, hence the two branches.
    @ViewBuilder
    private func toggleButton(isOn: Bool) -> some View {
        let button = Button("Notch") {
            hub.send(.setNotch(!isOn))
        }
        .disabled(hub.rigState.notchEnabled == nil)
        .help("Manual notch on/off")
        if isOn {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// Mid-drag the local value wins; otherwise the rig's last-known one
    /// (nil before the first poll sits at the low end of the slider).
    private var displayedHz: Int? {
        if let dragValue { return IFNotch.snappedHz(Int(dragValue)) }
        return hub.rigState.notchHz
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { dragValue ?? Double(hub.rigState.notchHz ?? IFNotch.rangeHz.lowerBound) },
            set: { dragValue = $0 }
        )
    }
}

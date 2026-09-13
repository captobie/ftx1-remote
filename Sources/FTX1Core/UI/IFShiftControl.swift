import SwiftUI

/// IF SHIFT slider plus a center-reset button, meant to sit in the Filter
/// row under the Band/Mode pickers next to `FilterWidthControl`. Generic
/// over `RigController` like that view, so it can drop into the iPad's
/// `ContentView` later without change.
///
/// The value only goes to the rig when the drag ends (`onEditingChanged`
/// false), not on every 20 Hz tick — each `RigCommand.setIFShift` is a
/// fire-and-forget raw CAT write (`IS00±dddd;`), and a drag across the
/// ±1200 Hz range would otherwise queue ~120 of them. While dragging, the
/// slider and label track a local `dragValue`; once released, the
/// optimistic update in `HubService.send` keeps the label at the released
/// value until the next slow-tier poll confirms it.
///
/// Shown for every mode except C4FM/unknown (which have no IF shift), and
/// disabled in AM/FM like `FilterWidthControl` — hardware-confirmed that
/// the rig ignores shift in those fixed-width modes (see
/// `IFShift.isSupported`).
public struct IFShiftControl<Controller: RigController>: View {
    @EnvironmentObject private var hub: Controller
    @State private var dragValue: Double?

    public init() {}

    public var body: some View {
        let mode = hub.rigState.mode
        if mode != .c4fm && mode != .unknown {
            HStack(spacing: 6) {
                Text("Shift")

                Slider(
                    value: sliderValue,
                    in: Double(IFShift.range.lowerBound)...Double(IFShift.range.upperBound),
                    step: Double(IFShift.stepHz),
                    onEditingChanged: { editing in
                        if !editing, let dragValue {
                            hub.send(.setIFShift(hz: IFShift.snapped(Int(dragValue))))
                            self.dragValue = nil
                        }
                    }
                )
                .frame(width: 180)

                Text(IFShift.label(displayedHz))
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)

                Button {
                    hub.send(.setIFShift(hz: 0))
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .buttonStyle(.bordered)
                .disabled(hub.rigState.ifShiftHz == nil || hub.rigState.ifShiftHz == 0)
                .help("Center")
            }
            .disabled(!IFShift.isSupported(mode: mode))
        }
    }

    /// Mid-drag the local value wins; otherwise the rig's last-known one
    /// (nil, before the first poll, sits at center rather than jumping the
    /// knob to one end).
    private var displayedHz: Int? {
        if let dragValue { return IFShift.snapped(Int(dragValue)) }
        return hub.rigState.ifShiftHz
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { dragValue ?? Double(hub.rigState.ifShiftHz ?? 0) },
            set: { dragValue = $0 }
        )
    }
}

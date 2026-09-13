import SwiftUI

/// CONTOUR or APF — one slot in the second Filter row that changes face
/// with the mode, since the two are complementary (`IFContour.face(for:)`:
/// APF in CW, CONTOUR everywhere else) and share the rig's "CO" command.
/// Generic over `RigController` like the other Filter-row views.
///
/// Each face is a toggle button (fill = on), a slider and a label with the
/// same drag semantics as `IFNotchControl`: the slider tracks a local value
/// while dragging, the command goes out on release, and dragging while the
/// function is off also turns it on (frequency first, then on). The slot
/// is keyed by face (`.id`) so a CW ↔ SSB switch mid-drag discards the
/// in-flight value instead of committing a contour frequency as an APF
/// offset.
///
/// The related shape settings (CONTOUR LEVEL/WIDTH, APF WIDTH) stay in
/// Deep Settings → OPERATION SETTING → RX-DSP.
public struct ContourAPFControl<Controller: RigController>: View {
    @EnvironmentObject private var hub: Controller

    public init() {}

    public var body: some View {
        let mode = hub.rigState.mode
        switch IFContour.face(for: mode) {
        case nil:
            EmptyView()
        case .contour?:
            FilterToggleSlider(
                title: "Contour",
                help: "Contour on/off",
                range: IFContour.contourRangeHz,
                stepHz: IFContour.stepHz,
                isOn: hub.rigState.contourEnabled,
                valueHz: hub.rigState.contourHz,
                idleHz: IFContour.contourRangeHz.lowerBound,
                label: IFContour.contourLabel,
                onToggle: { hub.send(.setContour($0)) },
                onCommit: { hub.send(.setContourFrequency(hz: IFContour.snappedContourHz($0))) }
            )
            .id(IFContour.Face.contour)
            .disabled(!IFContour.contourSupported(mode: mode))
        case .apf?:
            FilterToggleSlider(
                title: "APF",
                help: "Audio peak filter on/off",
                range: IFContour.apfRangeHz,
                stepHz: IFContour.stepHz,
                isOn: hub.rigState.apfEnabled,
                valueHz: hub.rigState.apfHz,
                idleHz: 0,
                label: IFContour.apfLabel,
                onToggle: { hub.send(.setAPF($0)) },
                onCommit: { hub.send(.setAPFOffset(hz: IFContour.snappedAPFHz($0))) }
            )
            .id(IFContour.Face.apf)
            .disabled(!IFContour.apfSupported(mode: mode))
        }
    }
}

/// Toggle button + slider + label for one on/off-plus-frequency filter
/// function. `isOn`/`valueHz` are the rig's last-known state (nil before
/// the first poll: button disabled, slider parked at `idleHz`, label "—").
/// `onCommit` fires once per drag on release; if the function was off it
/// is followed by `onToggle(true)`.
private struct FilterToggleSlider: View {
    let title: String
    let help: String
    let range: ClosedRange<Int>
    let stepHz: Int
    let isOn: Bool?
    let valueHz: Int?
    let idleHz: Int
    let label: (Int?) -> String
    let onToggle: (Bool) -> Void
    let onCommit: (Int) -> Void

    @State private var dragValue: Double?

    var body: some View {
        let on = isOn ?? false
        HStack(spacing: 6) {
            toggleButton(isOn: on)

            Slider(
                value: sliderValue,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(stepHz),
                onEditingChanged: { editing in
                    if !editing, let dragValue {
                        onCommit(Int(dragValue))
                        if isOn != true { onToggle(true) }
                        self.dragValue = nil
                    }
                }
            )
            .frame(width: 160)

            Text(label(displayedHz))
                .monospacedDigit()
                .frame(minWidth: 58, alignment: .trailing)
        }
        .opacity(on ? 1 : 0.7)
    }

    /// Bordered when off, filled (prominent) when on — `buttonStyle` can't
    /// be chosen conditionally on one `Button`, hence the two branches.
    @ViewBuilder
    private func toggleButton(isOn on: Bool) -> some View {
        let button = Button(title) { onToggle(!on) }
            .disabled(isOn == nil)
            .help(help)
        if on {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var displayedHz: Int? {
        if let dragValue { return Int(dragValue) }
        return valueHz
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { dragValue ?? Double(valueHz ?? idleHz) },
            set: { dragValue = $0 }
        )
    }
}

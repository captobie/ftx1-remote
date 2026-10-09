import SwiftUI

/// The operating-mode buttons in `VFODisplayBox`'s frequency popover (the
/// iPad's, which has no mode row on its main screen): every settable
/// `RigMode`, three to a row, the current one filled. A tap sends the mode
/// and leaves the popover open, so a frequency can be entered after it.
public struct ModeButtonGrid: View {
    let currentMode: RigMode?
    let onSetMode: (RigMode) -> Void

    private static let modes = RigMode.allCases.filter { $0 != .unknown }

    public init(currentMode: RigMode?, onSetMode: @escaping (RigMode) -> Void) {
        self.currentMode = currentMode
        self.onSetMode = onSetMode
    }

    public var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: Self.modes.count, by: 3)), id: \.self) { start in
                GridRow {
                    ForEach(Self.modes[start..<min(start + 3, Self.modes.count)], id: \.self) { mode in
                        modeButton(mode)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modeButton(_ mode: RigMode) -> some View {
        let button = Button {
            onSetMode(mode)
        } label: {
            Text(mode.displayName)
                .frame(maxWidth: .infinity)
        }
        if mode == currentMode {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

#Preview {
    ModeButtonGrid(currentMode: .fm, onSetMode: { _ in })
        .padding()
        .frame(width: 320)
}

import SwiftUI

/// Popover content for manually entering a frequency or fine-tuning it with
/// up/down steps — presented by `VFODisplayBox` and iOS's `FrequencyDisplay`
/// when their frequency readout is tapped. Shared since both platforms want
/// identical entry behavior; only the display box around it differs.
public struct FrequencyEntryView: View {
    let currentHz: Int
    let onSetFrequency: (Int) -> Void

    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    /// Up/down step size — fixed, no picker (see repo root CLAUDE.md
    /// working-conventions note on keeping this UI simple for v1).
    private static let stepHz = 1_000

    public init(currentHz: Int, onSetFrequency: @escaping (Int) -> Void) {
        self.currentHz = currentHz
        self.onSetFrequency = onSetFrequency
        _text = State(initialValue: Self.formatMHz(currentHz))
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("MHz", text: $text)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit(commitText)
                Button("Set", action: commitText)
            }

            HStack(spacing: 20) {
                Button {
                    step(by: -Self.stepHz)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 32, height: 32)
                }
                Button {
                    step(by: Self.stepHz)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func commitText() {
        guard let mhz = Double(text), mhz.isFinite, mhz >= 0 else { return }
        let hz = Int((mhz * 1_000_000).rounded())
        onSetFrequency(hz)
        dismiss()
    }

    private func step(by deltaHz: Int) {
        let newHz = max(0, currentHz + deltaHz)
        text = Self.formatMHz(newHz)
        onSetFrequency(newHz)
    }

    private static func formatMHz(_ hz: Int) -> String {
        String(format: "%.6f", Double(hz) / 1_000_000)
    }
}

#Preview {
    FrequencyEntryView(currentHz: 147_380_000, onSetFrequency: { _ in })
}

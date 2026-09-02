import SwiftUI

/// Popover content for manually entering a frequency or fine-tuning it with
/// up/down steps — presented by `VFODisplayBox` and iOS's `FrequencyDisplay`
/// when their frequency readout is tapped. Shared since both platforms want
/// identical entry behavior; only the display box around it differs.
public struct FrequencyEntryView: View {
    let currentHz: Int
    let onSetFrequency: (Int) -> Void

    @State private var text: String
    @AppStorage("ui.frequencyStepSize") private var stepSize: StepSize = .oneKHz
    @Environment(\.dismiss) private var dismiss

    /// Up/down step size choices — persisted per device via `stepSize` so
    /// the last one picked carries over to the next time the popover opens.
    private enum StepSize: Int, CaseIterable {
        case oneHundredHz = 100
        case oneKHz = 1_000
        case tenKHz = 10_000

        var label: String {
            switch self {
            case .oneHundredHz: "100 Hz"
            case .oneKHz: "1 kHz"
            case .tenKHz: "10 kHz"
            }
        }
    }

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

            Picker("Step", selection: $stepSize) {
                ForEach(StepSize.allCases, id: \.self) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            HStack(spacing: 20) {
                Button {
                    step(by: -stepSize.rawValue)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 32, height: 32)
                }
                Button {
                    step(by: stepSize.rawValue)
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

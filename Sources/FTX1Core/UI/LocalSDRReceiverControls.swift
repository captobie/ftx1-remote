import SwiftUI

/// MyKiwiSDR's AGC, noise blanker and noise filter (the Mac window's
/// collapsed Receiver section, the iPad pane's Receiver sheet). Each row is
/// one group; a control that wouldn't do anything isn't shown.
public struct LocalSDRReceiverControls: View {
    @ObservedObject var model: LocalSDRModel

    public init(model: LocalSDRModel) {
        self.model = model
    }

    private typealias Settings = KiwiReceiverSettings

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            agcRow
            blankerRow
            filterRow
        }
    }

    private var agcRow: some View {
        HStack(spacing: 14) {
            Toggle(isOn: bind(\.agc)) { Text(verbatim: "AGC").lineLimit(1).fixedSize().frame(minWidth: 34, alignment: .leading) }
                .toggleStyle(.switch)
                .help(Text("localSDR.receiver.agcHelp", bundle: .module))
                .fixedSize()
            if model.receiver.agc {
                slider(String(localized: "localSDR.receiver.threshold", bundle: .module), value: intBinding(\.threshold), range: range(Settings.thresholdRange),
                       step: 1, readout: "\(model.receiver.threshold) dB")
                slider(String(localized: "localSDR.receiver.decay", bundle: .module), value: intBinding(\.decay), range: range(Settings.decayRange),
                       step: Double(Settings.decayStep), readout: "\(model.receiver.decay) ms")
            } else {
                slider(String(localized: "localSDR.receiver.manualGain", bundle: .module), value: intBinding(\.manualGain), range: range(Settings.manualGainRange),
                       step: 1, readout: "\(model.receiver.manualGain) dB")
            }
        }
    }

    private var blankerRow: some View {
        HStack(spacing: 14) {
            Text(verbatim: "NB").lineLimit(1).fixedSize().frame(minWidth: 34, alignment: .leading)
            Picker(String(localized: "localSDR.receiver.noiseBlanker", bundle: .module), selection: bind(\.noiseBlanker)) {
                Text("localSDR.receiver.off", bundle: .module).tag(Settings.NoiseBlanker.off)
                Text("localSDR.receiver.standard", bundle: .module).tag(Settings.NoiseBlanker.standard)
                Text(verbatim: "Wild").tag(Settings.NoiseBlanker.wild)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(Text("localSDR.receiver.noiseBlankerHelp", bundle: .module))
            switch model.receiver.noiseBlanker {
            case .off:
                EmptyView()
            case .standard:
                slider(String(localized: "localSDR.receiver.gate", bundle: .module), value: intBinding(\.gate), range: range(Settings.gateRange),
                       step: Double(Settings.gateStep), readout: "\(model.receiver.gate)")
                slider(String(localized: "localSDR.receiver.threshold", bundle: .module), value: intBinding(\.blankerThreshold),
                       range: range(Settings.blankerThresholdRange), step: 1, readout: "\(model.receiver.blankerThreshold)")
            case .wild:
                slider(String(localized: "localSDR.receiver.threshold", bundle: .module), value: bind(\.wildThreshold), range: Settings.wildThresholdRange,
                       step: Settings.wildThresholdStep,
                       readout: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), model.receiver.wildThreshold))
            }
            Spacer(minLength: 0)
        }
    }

    private var filterRow: some View {
        HStack(spacing: 14) {
            Text(verbatim: "NR").lineLimit(1).fixedSize().frame(minWidth: 34, alignment: .leading)
            Picker(String(localized: "localSDR.receiver.noiseFilter", bundle: .module), selection: Binding(
                get: { model.receiver.noiseFilter },
                set: { filter in model.updateReceiver { $0.select(noiseFilter: filter) } })) {
                Text("localSDR.receiver.off", bundle: .module).tag(Settings.NoiseFilter.off)
                Text(verbatim: "WDSP").tag(Settings.NoiseFilter.wdsp)
                Text(verbatim: "LMS").tag(Settings.NoiseFilter.lms)
                Text(verbatim: "Spectral").tag(Settings.NoiseFilter.spectral)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(Text("localSDR.receiver.noiseFilterHelp", bundle: .module))
            if model.receiver.noiseFilter.hasSeparateFilters {
                Toggle(String(localized: "localSDR.receiver.denoise", bundle: .module), isOn: bind(\.denoise))
                    .toggleStyle(.switch)
                    .fixedSize()
                Toggle(String(localized: "localSDR.receiver.autonotch", bundle: .module), isOn: bind(\.autonotch))
                    .toggleStyle(.switch)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        step: Double, readout: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title).font(.caption).themedSecondaryForeground().fixedSize()
            Slider(value: value, in: range, step: step).frame(minWidth: 90, maxWidth: 220)
            Text(verbatim: readout).font(.caption.monospacedDigit()).frame(minWidth: 52, alignment: .leading)
        }
    }

    private func range(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    private func bind<T: Equatable>(_ path: WritableKeyPath<KiwiReceiverSettings, T>) -> Binding<T> {
        Binding(get: { model.receiver[keyPath: path] },
                set: { value in model.updateReceiver { $0[keyPath: path] = value } })
    }

    private func intBinding(_ path: WritableKeyPath<KiwiReceiverSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(model.receiver[keyPath: path]) },
                set: { value in model.updateReceiver { $0[keyPath: path] = Int(value.rounded()) } })
    }
}

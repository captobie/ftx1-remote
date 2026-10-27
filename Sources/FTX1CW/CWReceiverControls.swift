import CWKit
import SwiftUI

// The receive controls shared by the Mac's CW window and the iPad's CW
// pane. Each observes only what it draws: `CWMeterStore` changes up to ten
// times a second and must not re-render the decoded text.

/// Neural/Classic.
public struct CWDecoderPicker: View {
    @EnvironmentObject private var receiver: CWReceiver

    public init() {}

    /// CWKit's own `title` is English; the picker's label is ours.
    static func label(_ kind: DecoderKind) -> String {
        switch kind {
        case .neural: String(localized: "cwReceiverControls.decoderNeural", bundle: .module)
        case .classic: String(localized: "cwReceiverControls.decoderClassic", bundle: .module)
        }
    }

    public var body: some View {
        Picker(String(localized: "cwReceiverControls.decoder", bundle: .module), selection: $receiver.decoder) {
            ForEach(DecoderKind.allCases, id: \.self) { kind in
                Text(Self.label(kind)).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(receiver.neuralUnavailableReason != nil)
        .help(receiver.neuralUnavailableReason
              ?? String(localized: "cwReceiverControls.neuralAModelTrained", bundle: .module))
    }
}

/// Key light, level, the Classic decoder's dits and dahs, a note on why
/// decoding is paused or odd, and tone/SNR/WPM.
public struct CWSignalStatusBar: View {
    @ObservedObject var meters: CWMeterStore
    let isDecodingFile: Bool
    let sourceNote: String?

    public init(meters: CWMeterStore, isDecodingFile: Bool, sourceNote: String?) {
        self.meters = meters
        self.isDecodingFile = isDecodingFile
        self.sourceNote = sourceNote
    }

    public var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(meters.keyDown ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 12, height: 12)
                .help(String(localized: "cwReceiverControls.keyDown", bundle: .module))

            CWLevelMeter(level: meters.signalLevel)
                .frame(width: 120, height: 8)
                .help(String(localized: "cwReceiverControls.toneLevelBetweenThe", bundle: .module))

            Text(String(meters.pendingSymbols.map { $0 == "." ? "·" : "–" }))
                .font(.system(.title3, design: .monospaced))
                .frame(minWidth: 110, alignment: .leading)
                .help(String(localized: "cwReceiverControls.elementsOfTheCharacter", bundle: .module))

            Spacer()

            if isDecodingFile {
                ProgressView().controlSize(.small)
                Text("cwReceiverControls.decodingFile", bundle: .module).foregroundStyle(.secondary)
            } else if let sourceNote {
                Label(sourceNote, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(sourceNote)
            }

            Group {
                Text("\(Int(meters.detectedFrequency.rounded())) Hz")
                Text("cwReceiverControls.snrDB \(Int(meters.snrDB.rounded()))", bundle: .module)
                Text(meters.wpm > 0 ? "\(Int(meters.wpm.rounded())) WPM" : "– WPM")
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

struct CWLevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * min(max(level, 0), 1))
            }
        }
    }
}

/// Auto-tune, the tone slider with Rig Pitch, and the Classic decoder's
/// squelch. One row where it fits; tone and squelch on a row each where
/// it doesn't (an iPad in portrait).
public struct CWTuningControls: View {
    @EnvironmentObject private var receiver: CWReceiver
    @ObservedObject var meters: CWMeterStore

    public init(meters: CWMeterStore) {
        self.meters = meters
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                autoTune
                tone
                squelch
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    autoTune
                    tone
                }
                squelch
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var autoTune: some View {
        Toggle(String(localized: "cwReceiverControls.autoTune", bundle: .module), isOn: $receiver.autoTune)
            .fixedSize()
            .help(String(localized: "cwReceiverControls.followTheStrongestTone \(Int(FrequencyTracker.searchRange.lowerBound)) \(Int(FrequencyTracker.searchRange.upperBound))", bundle: .module))
    }

    private var tone: some View {
        HStack {
            Text("cwReceiverControls.tone", bundle: .module)
            Slider(value: frequency, in: FrequencyTracker.searchRange, step: 10)
                .frame(minWidth: 160)
                .disabled(receiver.autoTune)
            Text("\(Int(frequency.wrappedValue.rounded())) Hz")
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 64, alignment: .trailing)
            Button(String(localized: "cwReceiverControls.rigPitch", bundle: .module)) {
                receiver.useRigPitch()
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(receiver.rigPitchHz == nil)
            .help(receiver.rigPitchHz.map { String(localized: "cwReceiverControls.turnOffAutoTune \($0)", bundle: .module) }
                  ?? String(localized: "cwReceiverControls.theRigsCwPitch", bundle: .module))
        }
    }

    private var squelch: some View {
        HStack {
            Text("cwReceiverControls.squelch", bundle: .module)
            Slider(value: $receiver.squelchDB, in: 3...30, step: 1)
                .frame(minWidth: 120, maxWidth: 160)
            Text("\(Int(receiver.squelchDB)) dB")
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .disabled(receiver.decoder == .neural)
        .help(receiver.decoder == .neural
              ? String(localized: "cwReceiverControls.theNeuralDecoderDoesnt", bundle: .module)
              : String(localized: "cwReceiverControls.minimumSignalToNoise", bundle: .module))
    }

    private var frequency: Binding<Double> {
        Binding(
            get: { receiver.autoTune ? meters.detectedFrequency : receiver.toneFrequency },
            set: { receiver.toneFrequency = $0 }
        )
    }
}

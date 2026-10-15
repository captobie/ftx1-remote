import CWKit
import SwiftUI

// The receive controls shared by the Mac's CW window and the iPad's CW
// pane. Each observes only what it draws: `CWMeterStore` changes up to ten
// times a second and must not re-render the decoded text.

/// Neural/Classic.
public struct CWDecoderPicker: View {
    @EnvironmentObject private var receiver: CWReceiver

    public init() {}

    public var body: some View {
        Picker("Decoder", selection: $receiver.decoder) {
            ForEach(DecoderKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(receiver.neuralUnavailableReason != nil)
        .help(receiver.neuralUnavailableReason
              ?? "Neural: a model trained on simulated CW, best on weak and noisy signals; text runs about 3½ s behind. Classic: tone threshold and timing rules.")
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
                .help("Key down")

            CWLevelMeter(level: meters.signalLevel)
                .frame(width: 120, height: 8)
                .help("Tone level between the noise floor and the signal peak")

            Text(String(meters.pendingSymbols.map { $0 == "." ? "·" : "–" }))
                .font(.system(.title3, design: .monospaced))
                .frame(minWidth: 110, alignment: .leading)
                .help("Elements of the character being received (Classic decoder)")

            Spacer()

            if isDecodingFile {
                ProgressView().controlSize(.small)
                Text("Decoding file…").foregroundStyle(.secondary)
            } else if let sourceNote {
                Label(sourceNote, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(sourceNote)
            }

            Group {
                Text("\(Int(meters.detectedFrequency.rounded())) Hz")
                Text("SNR \(Int(meters.snrDB.rounded())) dB")
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
        Toggle("Auto-tune", isOn: $receiver.autoTune)
            .fixedSize()
            .help("Follow the strongest tone between \(Int(FrequencyTracker.searchRange.lowerBound)) and \(Int(FrequencyTracker.searchRange.upperBound)) Hz")
    }

    private var tone: some View {
        HStack {
            Text("Tone")
            Slider(value: frequency, in: FrequencyTracker.searchRange, step: 10)
                .frame(minWidth: 160)
                .disabled(receiver.autoTune)
            Text("\(Int(frequency.wrappedValue.rounded())) Hz")
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 64, alignment: .trailing)
            Button("Rig Pitch") {
                receiver.useRigPitch()
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(receiver.rigPitchHz == nil)
            .help(receiver.rigPitchHz.map { "Turn off auto-tune and use the rig's CW pitch, \($0) Hz — where a zero-beat signal sounds" }
                  ?? "The rig's CW pitch hasn't been read yet")
        }
    }

    private var squelch: some View {
        HStack {
            Text("Squelch")
            Slider(value: $receiver.squelchDB, in: 3...30, step: 1)
                .frame(minWidth: 120, maxWidth: 160)
            Text("\(Int(receiver.squelchDB)) dB")
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .disabled(receiver.decoder == .neural)
        .help(receiver.decoder == .neural
              ? "The neural decoder doesn't need a squelch: it stays silent on noise"
              : "Minimum signal-to-noise ratio needed before anything is decoded")
    }

    private var frequency: Binding<Double> {
        Binding(
            get: { receiver.autoTune ? meters.detectedFrequency : receiver.toneFrequency },
            set: { receiver.toneFrequency = $0 }
        )
    }
}

import Combine
import FTX1Digi
import SwiftUI

/// The RTTY/PSK window's tuning strip: a small waterfall over 0–3 kHz of
/// the decoder's own audio, with the decoder's frequency marked. A click
/// tunes the decoder there (snapped to the signal nearby).
///
/// Rows come from `DigiMeterStore` about ten times a second and go into
/// the same `WaterfallBitmap` the main window's waterfall uses (one
/// `memmove` and a palette lookup per row).
struct DigiTuningStrip: View {
    @EnvironmentObject private var receiver: DigiReceiver
    @ObservedObject var meters: DigiMeterStore
    @StateObject private var waterfall = DigiWaterfallModel()

    private static let spanHz = DigiDecoder.stripSpanHz
    private static let scaleHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let waterfallHeight = geometry.size.height - Self.scaleHeight
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let image = waterfall.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                    }
                    markers(width: width, height: waterfallHeight)
                }
                .frame(width: width, height: waterfallHeight)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let hz = Double(location.x / max(width, 1)) * Self.spanHz
                    receiver.setCenter(waterfall.snap(hz, mode: receiver.mode, shiftHz: receiver.rttyShiftHz))
                }
                .help("digiWindow.clickToTune")
                scale(width: width)
            }
        }
        .onReceive(meters.$row) { row in
            waterfall.append(row)
        }
    }

    private func x(_ hz: Double, width: CGFloat) -> CGFloat {
        CGFloat(hz / Self.spanHz) * width
    }

    @ViewBuilder
    private func markers(width: CGFloat, height: CGFloat) -> some View {
        let center = meters.trackedHz
        if receiver.mode == .rtty {
            let half = receiver.rttyShiftHz / 2
            ForEach([center - half, center + half], id: \.self) { hz in
                Rectangle()
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: 1.5, height: height)
                    .offset(x: x(hz, width: width) - 0.75)
            }
        } else {
            let bandwidth = receiver.mode.bandwidthHz(rtty: receiver.rttySettings)
            let left = x(center - bandwidth / 2, width: width)
            let right = x(center + bandwidth / 2, width: width)
            Rectangle()
                .strokeBorder(Color.yellow.opacity(0.85), lineWidth: 1.5)
                .frame(width: max(right - left, 3), height: height)
                .offset(x: left)
        }
    }

    private func scale(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            ForEach(Array(stride(from: 500, to: Int(Self.spanHz), by: 500)), id: \.self) { hz in
                Text(verbatim: "\(hz)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: x(Double(hz), width: width) - 10, y: 2)
            }
        }
        .frame(width: width, height: Self.scaleHeight)
    }
}

/// The strip's bitmap and newest row, kept across re-renders.
@MainActor
final class DigiWaterfallModel: ObservableObject {
    @Published private(set) var image: CGImage?
    private var bitmap: WaterfallBitmap?
    private var lastRow: [Float] = []

    func append(_ row: [Float]) {
        guard !row.isEmpty else { return }
        if bitmap == nil || lastRow.count != row.count {
            bitmap = WaterfallBitmap(binCount: row.count, historyRows: 64)
        }
        lastRow = row
        image = bitmap?.appendRow(row)
    }

    /// Moves a click onto the signal near it. RTTY: the centre that puts
    /// the most energy on both tones, within half a shift of the click.
    /// PSK: the strongest bin within 15 Hz. Unchanged before any row.
    func snap(_ hz: Double, mode: DigiMode, shiftHz: Double) -> Double {
        guard !lastRow.isEmpty else { return hz }
        let binHz = DigiDecoder.stripSpanHz / Double(lastRow.count)
        func level(_ frequency: Double) -> Float {
            let bin = Int((frequency / binHz).rounded())
            guard bin >= 1, bin < lastRow.count - 1 else { return 0 }
            return max(lastRow[bin - 1], lastRow[bin], lastRow[bin + 1])
        }
        let reach = mode == .rtty ? shiftHz / 2 : 15
        var best = hz
        var bestScore: Float = -1
        var candidate = hz - reach
        while candidate <= hz + reach {
            let score = mode == .rtty
                ? min(level(candidate - shiftHz / 2), level(candidate + shiftHz / 2))
                : level(candidate)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
            candidate += binHz
        }
        return best
    }
}

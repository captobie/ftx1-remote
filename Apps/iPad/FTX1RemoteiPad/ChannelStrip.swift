import FTX1Core
import SwiftUI

/// One receiver's meter + audio controls in a single compact strip, laid
/// out under its `VFODisplayBox`: a segmented bar S-meter with a numeric
/// readout and a mute button on the top row, SQL and VOL sliders side by
/// side below. Used by both the hub screen (`HubControlView`, fed by
/// `RigClientViewModel`) and the Pi-direct screen (`PiDirectView`, fed by
/// `PiDirectViewModel`), which persist volume/squelch under the same
/// `AudioPlaybackSettings` keys.
///
/// Replaced (2026-10-09, user request) the Mac-style analog `SMeterView`
/// plus two tall label-over-slider columns, which together took ~2.5× the
/// height. The analog face stays on the Mac; on the iPad a bar reads at a
/// glance and fits beside the sliders.
///
/// While transmitting, MAIN's bar shows the TX meter chosen by tapping it
/// (PO/SWR/ALC/…, the same `MeterSettings.key` selection the analog meter
/// uses) with the SWR under the readout; SUB stays on its S-meter, since
/// the TX readings are Main's (see `SMeterView.isSub`).
///
/// Volume/squelch are written straight to `engine` on every change (not
/// routed back through a view model) since `AudioPlaybackEngine` is a
/// reference type the view model already owns.
struct ChannelStrip: View {
    let label: String
    let smeterDb: Double?
    /// TX readings for MAIN's strip; nil for SUB (always shows S).
    let txReadings: MeterReadings?
    let ptt: Bool
    @Binding var volume: Double
    @Binding var squelchThreshold: Double
    let isMuted: Bool
    let engine: AudioPlaybackEngine
    let onToggleMute: () -> Void

    @AppStorage(MeterSettings.key) private var txSelectionRaw: String = MeterSelection.po.rawValue
    @State private var showingMeterPicker = false

    /// Upper bound of the squelch slider's *displayed* range — see the
    /// Mac's identical constant/doc comment in its own `ContentView`.
    private static let squelchDisplayRange: Double = 0.05

    private var txSelection: MeterSelection { MeterSelection(rawValue: txSelectionRaw) ?? .po }
    private var showsTX: Bool { ptt && txReadings != nil }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(showsTX ? txSelection.title : label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(showsTX ? Color.orange : Color.secondary)
                    .frame(width: 38, alignment: .leading)
                meter
                muteButton
            }
            HStack(spacing: 14) {
                sliderRow("SQL", value: squelchDisplayBinding, range: 0...Self.squelchDisplayRange)
                sliderRow("VOL", value: $volume, range: 0...1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        .onChange(of: volume, initial: true) { _, newValue in
            engine.volume = Float(newValue)
        }
        .onChange(of: squelchThreshold, initial: true) { _, newValue in
            engine.squelchThreshold = Float(newValue)
        }
    }

    // MARK: - Meter

    private var meter: some View {
        HStack(spacing: 8) {
            BarMeter(
                fraction: showsTX ? BarMeter.fraction(fromFace: txSelection.fraction(from: txReadings!)) : BarMeter.fraction(forStrengthDb: smeterDb),
                ticks: showsTX ? txSelection.ticks.map { ($0.label, BarMeter.fraction(fromFace: $0.fraction)) } : BarMeter.sTicks,
                hotFrom: showsTX ? 1.1 : BarMeter.s9Fraction,
                litColor: showsTX ? .orange : .green
            )
            VStack(alignment: .trailing, spacing: 0) {
                Text(readout)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                if showsTX, txSelection != .swr {
                    Text(swrText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 56, alignment: .trailing)
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
        .contentShape(Rectangle())
        .onTapGesture { if txReadings != nil { showingMeterPicker = true } }
        .popover(isPresented: $showingMeterPicker) { meterPicker }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) meter")
        .accessibilityValue(readout)
    }

    private var readout: String {
        guard showsTX, let readings = txReadings else { return Self.sUnitText(smeterDb) }
        switch txSelection {
        case .po: return readings.powerWatts.map { String(format: "%.0f W", $0) } ?? "—"
        case .swr: return readings.swr.map { String(format: "%.1f", $0) } ?? "—"
        case .comp: return Self.percentText(readings.tx?.comp)
        case .alc: return Self.percentText(readings.tx?.alc)
        case .vdd: return Self.percentText(readings.tx?.vdd)
        case .id: return Self.percentText(readings.tx?.idd)
        }
    }

    private var swrText: String {
        txReadings?.swr.map { String(format: "SWR %.1f", $0) } ?? "SWR —"
    }

    /// "S7", "S9+12", or "—" with no reading. 6 dB per S unit below S9
    /// (hamlib STRENGTH: S0 = -54 dB, S9 = 0 dB).
    static func sUnitText(_ db: Double?) -> String {
        guard let db else { return "—" }
        if db > 0.5 { return "S9+\(Int(db.rounded()))" }
        let s = min(max(Int(((db + 54) / 6).rounded()), 0), 9)
        return "S\(s)"
    }

    /// Raw RM (0-255) as a percentage — the CAT manual gives no units.
    private static func percentText(_ raw: Int?) -> String {
        guard let raw else { return "—" }
        return "\(min(max(raw, 0), 255) * 100 / 255)%"
    }

    /// The rig's METER selector for MAIN's TX reading, like tapping the
    /// analog meter on the Mac.
    private var meterPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TX METER").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 8), count: 3), spacing: 8) {
                ForEach(MeterSelection.allCases, id: \.self) { item in
                    Button(item.title) {
                        txSelectionRaw = item.rawValue
                        showingMeterPicker = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(item == txSelection ? .accentColor : .gray)
                }
            }
        }
        .padding(14)
    }

    // MARK: - Audio

    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.body)
                .frame(width: 40, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(isMuted ? Color.red : Color.gray.opacity(0.2)))
                .foregroundStyle(isMuted ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute \(label)" : "Mute \(label)")
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel("\(label) \(title == "SQL" ? "squelch" : "volume")")
        }
    }

    /// `SquelchGate.threshold` is "how close to true silence counts as
    /// quieting" — smaller is stricter (see its doc comment). Inverted here
    /// so dragging right still tightens the squelch, matching a normal
    /// radio's knob and the Mac's own slider — see its `squelchBinding`
    /// doc comment.
    private var squelchDisplayBinding: Binding<Double> {
        Binding(
            get: { Self.squelchDisplayRange - squelchThreshold },
            set: { squelchThreshold = Self.squelchDisplayRange - $0 }
        )
    }
}

/// Segmented LED-style bar with tick labels underneath, drawn on the dark
/// meter background. Its own 0…1 scale: S0–S9 fill the first 60%, the
/// over-S9 dB the rest (drawn red, like a rig's over-S9 zone).
private struct BarMeter: View {
    let fraction: Double
    let ticks: [(String, Double)]
    /// Segments at or past this fraction are drawn red.
    let hotFrom: Double
    let litColor: Color

    static let s9Fraction = 0.6
    /// No "+40": at strip width it runs into "+60".
    static let sTicks: [(String, Double)] = [
        ("1", fraction(forStrengthDb: -48)), ("3", fraction(forStrengthDb: -36)),
        ("5", fraction(forStrengthDb: -24)), ("7", fraction(forStrengthDb: -12)),
        ("9", s9Fraction), ("+20", fraction(forStrengthDb: 20)),
        ("+60", 1.0),
    ]

    static func fraction(forStrengthDb db: Double?) -> Double {
        guard let db else { return 0 }
        if db <= 0 { return max(0, (db + 54) / 54) * s9Fraction }
        return s9Fraction + min(db, 60) / 60 * (1 - s9Fraction)
    }

    /// Maps a position on the analog face's sweep (`MeterSelection.ticks`/
    /// `fraction(from:)`, whose scales run from ~0.10 to ~0.88) onto the bar.
    static func fraction(fromFace face: Double) -> Double {
        min(max((face - 0.10) / 0.78, 0), 1)
    }

    private static let segmentCount = 36

    var body: some View {
        Canvas { context, size in
            let barHeight: CGFloat = 10
            let gap: CGFloat = 1.5
            let n = Self.segmentCount
            let segWidth = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for i in 0..<n {
                let mid = (Double(i) + 0.5) / Double(n)
                let lit = mid <= fraction
                let color: Color = mid >= hotFrom ? .red : litColor
                let rect = CGRect(x: CGFloat(i) * (segWidth + gap), y: 2, width: segWidth, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(lit ? color : color.opacity(0.15)))
            }
            for (label, f) in ticks {
                let anchor: UnitPoint = f < 0.03 ? .topLeading : (f > 0.97 ? .topTrailing : .top)
                context.draw(
                    Text(label).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.white.opacity(0.65)),
                    at: CGPoint(x: f * size.width, y: barHeight + 4),
                    anchor: anchor
                )
            }
        }
        .frame(height: 26)
    }
}

#Preview {
    VStack {
        ChannelStrip(label: "MAIN", smeterDb: 12, txReadings: MeterReadings(powerWatts: 8, swr: 1.3, tx: nil), ptt: false, volume: .constant(0.8), squelchThreshold: .constant(0.015), isMuted: false, engine: AudioPlaybackEngine(), onToggleMute: {})
        ChannelStrip(label: "MAIN", smeterDb: nil, txReadings: MeterReadings(powerWatts: 8, swr: 1.3, tx: nil), ptt: true, volume: .constant(0.8), squelchThreshold: .constant(0.015), isMuted: false, engine: AudioPlaybackEngine(), onToggleMute: {})
        ChannelStrip(label: "SUB", smeterDb: -30, txReadings: nil, ptt: false, volume: .constant(0.5), squelchThreshold: .constant(0.03), isMuted: true, engine: AudioPlaybackEngine(), onToggleMute: {})
    }
    .frame(width: 500)
    .padding()
}

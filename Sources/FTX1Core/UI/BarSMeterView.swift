import SwiftUI

/// One receiver's compact meter row: the label, a segmented bar S-meter
/// (S0–S9 in the first 60%, over-S9 red) and an "S7"/"S9+12" readout, on
/// a dark background. The iPad's `ChannelStrip` puts it on its top row
/// beside the mute button; the iPhone shows it on its own under the
/// frequency (2026-10-22).
///
/// While transmitting, the transmitting side's meter (`txReadings`
/// non-nil and `transmits`) shows the TX meter chosen by tapping it
/// (PO/SWR/ALC/…, the same `MeterSettings` selection the Mac's analog
/// meter uses) with the SWR under the readout.
///
/// `twoLines` (the iPhone, 2026-10-30) adds a second line, like the Mac's
/// Digital S-meter style: the S-meter on top and the picked TX meter
/// underneath, dim until this side transmits; then the top line is PO
/// (SWR when PO is the picked meter), so two TX readings show at once.
/// Tapping picks the second line's meter on either side. No MAIN/SUB
/// label beside it: `label` is only the accessibility name then.
public struct BarSMeterView: View {
    let label: String
    let smeterDb: Double?
    /// The rig's TX readings; nil = this meter never shows them.
    let txReadings: MeterReadings?
    let ptt: Bool
    /// This meter's receiver is the TX side (`RigState.subTransmits`).
    let transmits: Bool
    let twoLines: Bool

    @AppStorage private var txSelectionRaw: String
    @State private var showingMeterPicker = false

    /// `isSub` picks SUB's own remembered meter (`MeterSettings.subKey`),
    /// as on the Mac.
    public init(label: String, smeterDb: Double?, txReadings: MeterReadings?, ptt: Bool,
                transmits: Bool = true, twoLines: Bool = false, isSub: Bool = false) {
        self.label = label
        self.smeterDb = smeterDb
        self.txReadings = txReadings
        self.ptt = ptt
        self.transmits = transmits
        self.twoLines = twoLines
        _txSelectionRaw = AppStorage(wrappedValue: MeterSelection.po.rawValue, isSub ? MeterSettings.subKey : MeterSettings.key)
    }

    private var txSelection: MeterSelection { MeterSelection(rawValue: txSelectionRaw) ?? .po }
    private var showsTX: Bool { ptt && transmits && txReadings != nil }
    /// The two-line top row's meter while transmitting.
    private var topTXMeter: MeterSelection { txSelection == .po ? .swr : .po }

    public var body: some View {
        // Two lines name their meters on each line and leave the receiver
        // to the screen (the iPhone's MAIN/SUB switch), so no side label.
        if twoLines {
            twoLineMeter
        } else {
            HStack(spacing: 10) {
                // The meter's name while it shows TX.
                Text(showsTX ? txSelection.title : label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(showsTX ? Color.orange : Color.secondary)
                    .frame(width: 38, alignment: .leading)
                meter
            }
        }
    }

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
        .meterPicker(isPresented: $showingMeterPicker, enabled: txReadings != nil, selection: txSelection) {
            txSelectionRaw = $0.rawValue
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "barSMeter.meter \(label)", bundle: .module))
        .accessibilityValue(readout)
    }

    private var twoLineMeter: some View {
        VStack(spacing: 2) {
            if showsTX {
                txLine(topTXMeter, active: true)
            } else {
                line(
                    title: "S",
                    titleColor: .white.opacity(0.6),
                    readout: Self.sUnitText(smeterDb),
                    bar: BarMeter(
                        fraction: BarMeter.fraction(forStrengthDb: smeterDb),
                        ticks: BarMeter.sTicks,
                        hotFrom: BarMeter.s9Fraction,
                        litColor: .green
                    )
                )
            }
            txLine(txSelection, active: showsTX)
                .opacity(showsTX ? 1 : 0.45)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
        .meterPicker(isPresented: $showingMeterPicker, enabled: true, selection: txSelection) {
            txSelectionRaw = $0.rawValue
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "barSMeter.meter \(label)", bundle: .module))
        .accessibilityValue(twoLineReadout)
    }

    /// A TX meter's line; inactive = no reading (bar unlit, "—").
    private func txLine(_ meter: MeterSelection, active: Bool) -> some View {
        line(
            title: meter.title,
            titleColor: active ? .orange : .white.opacity(0.6),
            readout: active ? txReadings.map { Self.txReadout(meter, $0) } ?? "—" : "—",
            bar: BarMeter(
                fraction: active ? txReadings.map { BarMeter.fraction(fromFace: meter.fraction(from: $0)) } ?? 0 : 0,
                ticks: meter.ticks.map { ($0.label, BarMeter.fraction(fromFace: $0.fraction)) },
                hotFrom: 1.1,
                litColor: .orange
            )
        )
    }

    private func line(title: String, titleColor: Color, readout: String, bar: BarMeter) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 32, alignment: .leading)
            bar
            Text(verbatim: readout)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var twoLineReadout: String {
        guard showsTX, let readings = txReadings else { return Self.sUnitText(smeterDb) }
        return "\(topTXMeter.title) \(Self.txReadout(topTXMeter, readings)), \(txSelection.title) \(Self.txReadout(txSelection, readings))"
    }

    private var readout: String {
        guard showsTX, let readings = txReadings else { return Self.sUnitText(smeterDb) }
        return Self.txReadout(txSelection, readings)
    }

    /// The TX meter's readout: "10 W", "1.5", "42%", or "—".
    static func txReadout(_ selection: MeterSelection, _ readings: MeterReadings) -> String {
        switch selection {
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
    public static func sUnitText(_ db: Double?) -> String {
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

}

private extension View {
    /// Tap to open the rig's METER selector (like tapping the Mac's analog
    /// meter) as a popover grid.
    func meterPicker(isPresented: Binding<Bool>, enabled: Bool, selection: MeterSelection,
                     onPick: @escaping (MeterSelection) -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture { if enabled { isPresented.wrappedValue = true } }
            .popover(isPresented: isPresented) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "TX METER").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 3), spacing: 8) {
                        ForEach(MeterSelection.allCases, id: \.self) { item in
                            Button {
                                onPick(item)
                                isPresented.wrappedValue = false
                            } label: {
                                // One line: "COMP" wrapped in iOS 26's capsule.
                                Text(verbatim: item.title)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(item == selection ? .accentColor : .gray)
                        }
                    }
                }
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
    }
}

/// Segmented LED-style bar with tick labels underneath, drawn on the dark
/// meter background (also `SMeterView`'s digital style). Its own 0…1 scale: S0–S9 fill the first 60%, the
/// over-S9 dB the rest (drawn red, like a rig's over-S9 zone).
struct BarMeter: View {
    let fraction: Double
    let ticks: [(String, Double)]
    /// Segments at or past this fraction are drawn red.
    let hotFrom: Double
    let litColor: Color
    /// The segments' height; the tick labels sit under them.
    var barHeight: CGFloat = 10

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
        .frame(height: barHeight + 16)
    }
}

import Foundation

/// Geometry for the app's counterpart to the rig's Filter Function Display
/// (operating manual p.21): where the DSP passband, the manual notch, the
/// contour/APF marker and the per-mode top markers sit on a fixed 0…4000 Hz
/// audio-frequency span, derived purely from `RigState`. No drawing here —
/// `FilterDisplayView` renders it — so the mapping is unit-testable.
///
/// This is an *illustration* of the rig's display, not a readback of it:
/// WIDTH, SHIFT, NOTCH, CONTOUR, APF and the CW pitch are the rig's real
/// values (polled over CAT), but where each mode's passband sits on the
/// audio axis before SHIFT is applied is a convention chosen to match the
/// rig's pictures (SSB's default 3000 Hz filter ≈ 150–3150 Hz, CW centered
/// on the pitch, RTTY between the 2125/2295 Hz tones, DATA around 1500 Hz).
/// AM/FM have fixed filters wider than the span; they're drawn centered
/// and scaled against the mode's widest filter so NARROW visibly shrinks
/// them (AM 9000 → 6000 Hz, FM 16000 → 9000 Hz). In the variable-width
/// modes NARROW doesn't change the "SH" index the rig reports, so while
/// it's on the shape uses the mode's NAR WIDTH preset
/// (`RigState.narrowWidthHz`, see `NarrowWidthPreset`) and the caption
/// marks it with an "N".
public struct FilterPassbandModel: Equatable, Sendable {
    public static let spanHz: ClosedRange<Double> = 0...4000

    /// A labeled tick at the top of the passband, as the rig draws them:
    /// "P" (CW pitch), "M"/"S" (RTTY mark/space), "C" (DATA center). A nil
    /// label is the SSB bandwidth marker, drawn as a dot at the passband
    /// center (the manual's "DSP filter bandwidth" callout).
    public struct Marker: Equatable, Sendable {
        public let label: String?
        public let hz: Double
        public init(label: String?, hz: Double) {
            self.label = label
            self.hz = hz
        }
    }

    /// Passband edges in audio Hz, clipped to `spanHz`; nil when the mode
    /// has no IF filter (C4FM/unknown) or the width isn't known yet.
    public let passband: ClosedRange<Double>?
    /// Manual notch position, only while the notch is on in a mode that
    /// honors it.
    public let notchHz: Double?
    /// Contour center, only while contour is on in a mode that honors it.
    public let contourHz: Double?
    /// APF peak (pitch + offset), only while APF is on in CW.
    public let apfHz: Double?
    /// Per-mode top markers (see `Marker`); empty when there's no passband.
    public let markers: [Marker]
    /// The rig's own name for the mode, for the caption.
    public let modeName: String
    /// "2400 Hz" / "Default" / "—", for the caption.
    public let widthLabel: String

    public init(state: RigState) {
        let mode = state.mode
        modeName = mode.displayName

        let shift = Double(state.ifShiftHz.map(IFShift.snapped) ?? 0)
        let pitch = Double(state.cwPitchHz ?? 700)
        let wideWidth = state.filterWidthIndex.flatMap { FilterWidthTable.hz(forIndex: $0, mode: mode) }
        // NARROW in SSB/CW/RTTY/DATA: the preset wins when known; AM/FM
        // already reflect NARROW through the "SH" index itself.
        let narrowPreset = (state.narrowEnabled == true && NarrowWidthPreset.item(for: mode) != nil)
            ? state.narrowWidthHz : nil
        let width = narrowPreset ?? wideWidth

        var band: ClosedRange<Double>?
        var marks: [Marker] = []
        switch mode {
        case .am, .fm, .dataFM:
            // Fixed filters wider than the span: scale against the widest
            // one the mode offers so NARROW shows as a narrower shape.
            if let width, let widest = FilterWidthTable.entries(for: mode).map(\.hz).max(), widest > 0 {
                let fraction = min(Double(width) / Double(widest), 1)
                let half = (Self.spanHz.upperBound - Self.spanHz.lowerBound) * fraction / 2
                let center = (Self.spanHz.lowerBound + Self.spanHz.upperBound) / 2
                band = Self.clipped(center - half, center + half)
            }
        case .c4fm, .unknown:
            band = nil
        case .usb, .lsb, .cw, .rtty, .dataUSB:
            if let width {
                let center = Self.defaultCenterHz(for: mode, pitch: pitch) + shift
                let half = Double(width) / 2
                band = Self.clipped(center - half, center + half)
                switch mode {
                case .cw: marks = [Marker(label: "P", hz: pitch + shift)]
                case .rtty: marks = [Marker(label: "M", hz: 2125 + shift), Marker(label: "S", hz: 2295 + shift)]
                case .dataUSB: marks = [Marker(label: "C", hz: center)]
                case .usb, .lsb: marks = [Marker(label: nil, hz: center)]
                default: break
                }
            }
        }
        passband = band
        markers = band == nil ? [] : marks
        widthLabel = narrowPreset.map { "\($0) Hz N" }
            ?? FilterWidthTable.label(forIndex: state.filterWidthIndex, mode: mode)

        notchHz = (state.notchEnabled == true && IFNotch.isSupported(mode: mode))
            ? state.notchHz.map(Double.init) : nil
        contourHz = (state.contourEnabled == true && IFContour.contourSupported(mode: mode))
            ? state.contourHz.map(Double.init) : nil
        apfHz = (state.apfEnabled == true && IFContour.apfSupported(mode: mode))
            ? state.apfHz.map { pitch + Double($0) } : nil
    }

    /// Where the passband's center sits before SHIFT, per mode (see the
    /// type doc comment for why these are conventions).
    static func defaultCenterHz(for mode: RigMode, pitch: Double) -> Double {
        switch mode {
        case .usb, .lsb: 1650
        case .dataUSB: 1500
        case .rtty: 2210
        case .cw: pitch
        case .am, .fm, .dataFM, .c4fm, .unknown: (Self.spanHz.lowerBound + Self.spanHz.upperBound) / 2
        }
    }

    private static func clipped(_ lo: Double, _ hi: Double) -> ClosedRange<Double>? {
        let l = max(lo, spanHz.lowerBound)
        let h = min(hi, spanHz.upperBound)
        return l < h ? l...h : nil
    }

    /// Maps an audio frequency onto a horizontal pixel position for a view
    /// of the given width (0 Hz at the left edge, 4000 Hz at the right).
    public func x(_ hz: Double, in width: Double) -> Double {
        let clamped = min(max(hz, Self.spanHz.lowerBound), Self.spanHz.upperBound)
        return (clamped - Self.spanHz.lowerBound) / (Self.spanHz.upperBound - Self.spanHz.lowerBound) * width
    }
}

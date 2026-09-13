import SwiftUI

/// The app's version of the rig's Filter Function Display (operating manual
/// p.21): the DSP passband as set by WIDTH/SHIFT, the manual notch as a
/// narrow cut, contour as a rounded dip ("divot"), APF as a peak, the
/// per-mode top markers (P / M S / C / the SSB bandwidth dot), over an
/// optional live audio spectrum that's bright inside the passband and dim
/// outside — all on a fixed 0…4000 Hz span. A dumb `Canvas` view: the
/// placement logic is in `FilterPassbandModel`, and the spectrum (if any)
/// is handed in already normalized 0…1 per bin — on the Mac that comes
/// from `AudioCaptureEngine` via `ScopeFrameStore` (see the Mac-only
/// `FilterDisplayHost`); other targets can pass `[]` and get the shape
/// alone. Styled like `ScopeDisplayView`/`SMeterView` (black rounded box)
/// and dims per their `isActive` convention while disconnected.
public struct FilterDisplayView: View {
    public let model: FilterPassbandModel
    public let spectrum: [Float]
    public let isActive: Bool

    public init(model: FilterPassbandModel, spectrum: [Float], isActive: Bool) {
        self.model = model
        self.spectrum = spectrum
        self.isActive = isActive
    }

    public var body: some View {
        Canvas { context, size in
            let w = size.width
            let baseline = size.height - 14   // leaves room for the captions
            let top: CGFloat = 12             // leaves room for the top markers

            let band = passbandPath(width: w, baseline: baseline, top: top)
            drawSpectrum(&context, width: w, baseline: baseline, top: top, insidePath: band)
            if let band {
                context.fill(band, with: .color(Color.white.opacity(0.18)))
                context.stroke(band, with: .color(Color.white.opacity(0.85)), lineWidth: 1)
            }
            drawDips(&context, width: w, baseline: baseline, top: top)
            drawMarkers(&context, width: w, baseline: baseline, top: top)
            drawCaptions(&context, size: size)
        }
        .frame(width: 240, height: 64)
        .opacity(isActive ? 1 : 0.4)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.4), lineWidth: 1.5))
        .help("Filter function display: passband (WIDTH/SHIFT), notch, contour/APF")
    }

    /// The passband trapezoid (flat top, short skirts), or nil.
    private func passbandPath(width: CGFloat, baseline: CGFloat, top: CGFloat) -> Path? {
        guard let band = model.passband else { return nil }
        let lo = CGFloat(model.x(band.lowerBound, in: Double(width)))
        let hi = CGFloat(model.x(band.upperBound, in: Double(width)))
        let skirt = width * 0.04
        var path = Path()
        path.move(to: CGPoint(x: max(lo - skirt, 0), y: baseline))
        path.addLine(to: CGPoint(x: lo, y: top))
        path.addLine(to: CGPoint(x: hi, y: top))
        path.addLine(to: CGPoint(x: min(hi + skirt, width), y: baseline))
        path.closeSubpath()
        return path
    }

    /// Spectrum polygon, dim across the whole span and bright where it
    /// falls inside the passband (the rig's look).
    private func drawSpectrum(_ context: inout GraphicsContext, width: CGFloat, baseline: CGFloat, top: CGFloat, insidePath: Path?) {
        guard spectrum.count > 1 else { return }
        let usable = (baseline - top) * 0.75
        var path = Path()
        path.move(to: CGPoint(x: 0, y: baseline))
        let step = width / CGFloat(spectrum.count - 1)
        for (i, v) in spectrum.enumerated() {
            let clamped = CGFloat(min(max(v, 0), 1))
            path.addLine(to: CGPoint(x: CGFloat(i) * step, y: baseline - clamped * usable))
        }
        path.addLine(to: CGPoint(x: width, y: baseline))
        path.closeSubpath()
        context.fill(path, with: .color(Color.green.opacity(0.22)))
        if let insidePath {
            var inside = context
            inside.clip(to: insidePath)
            inside.fill(path, with: .color(Color.green.opacity(0.7)))
        }
    }

    /// Notch (narrow cut) and contour (rounded dip) carved into the top of
    /// the passband; APF drawn as a peak since it boosts rather than cuts.
    private func drawDips(_ context: inout GraphicsContext, width: CGFloat, baseline: CGFloat, top: CGFloat) {
        if let contour = model.contourHz {
            let x = CGFloat(model.x(contour, in: Double(width)))
            let halfWidth: CGFloat = 14
            let depth = (baseline - top) * 0.45
            var dip = Path()
            dip.move(to: CGPoint(x: x - halfWidth, y: top - 1))
            dip.addQuadCurve(to: CGPoint(x: x + halfWidth, y: top - 1), control: CGPoint(x: x, y: top + depth * 2))
            dip.closeSubpath()
            context.fill(dip, with: .color(.black))
            var edge = Path()
            edge.move(to: CGPoint(x: x - halfWidth, y: top))
            edge.addQuadCurve(to: CGPoint(x: x + halfWidth, y: top), control: CGPoint(x: x, y: top + depth * 2))
            context.stroke(edge, with: .color(Color.orange), lineWidth: 1)
        }
        if let notch = model.notchHz {
            let x = CGFloat(model.x(notch, in: Double(width)))
            var cut = Path()
            cut.move(to: CGPoint(x: x - 4, y: top - 1))
            cut.addLine(to: CGPoint(x: x + 4, y: top - 1))
            cut.addLine(to: CGPoint(x: x, y: baseline))
            cut.closeSubpath()
            context.fill(cut, with: .color(.black))
            var line = Path()
            line.move(to: CGPoint(x: x, y: top))
            line.addLine(to: CGPoint(x: x, y: baseline))
            context.stroke(line, with: .color(Color.red.opacity(0.9)), lineWidth: 1)
        }
        if let apf = model.apfHz {
            let x = CGFloat(model.x(apf, in: Double(width)))
            var peak = Path()
            peak.move(to: CGPoint(x: x - 5, y: top))
            peak.addQuadCurve(to: CGPoint(x: x + 5, y: top), control: CGPoint(x: x, y: top - 12))
            peak.closeSubpath()
            context.fill(peak, with: .color(Color.orange.opacity(0.7)))
            context.stroke(peak, with: .color(Color.orange), lineWidth: 1)
        }
    }

    /// Top markers: a boxed letter with a thin line down through the
    /// passband (P / M S / C), or a dot for the SSB bandwidth marker.
    private func drawMarkers(_ context: inout GraphicsContext, width: CGFloat, baseline: CGFloat, top: CGFloat) {
        for marker in model.markers {
            let x = CGFloat(model.x(marker.hz, in: Double(width)))
            if let label = marker.label {
                var line = Path()
                line.move(to: CGPoint(x: x, y: top))
                line.addLine(to: CGPoint(x: x, y: baseline))
                context.stroke(line, with: .color(Color.white.opacity(0.5)), lineWidth: 1)
                let box = CGRect(x: x - 5, y: 1, width: 10, height: 10)
                context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(Color.white.opacity(0.85)))
                context.draw(
                    Text(label).font(.system(size: 8, weight: .bold)).foregroundColor(.black),
                    at: CGPoint(x: x, y: box.midY), anchor: .center
                )
            } else {
                let dot = CGRect(x: x - 3, y: top - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.9)))
            }
        }
    }

    private func drawCaptions(_ context: inout GraphicsContext, size: CGSize) {
        let font = Font.system(size: 9, weight: .medium, design: .monospaced)
        let y = size.height - 7
        context.draw(
            Text(model.modeName).font(font).foregroundColor(.gray),
            at: CGPoint(x: 6, y: y), anchor: .leading
        )
        context.draw(
            Text(model.widthLabel).font(font).foregroundColor(.gray),
            at: CGPoint(x: size.width - 6, y: y), anchor: .trailing
        )
    }
}

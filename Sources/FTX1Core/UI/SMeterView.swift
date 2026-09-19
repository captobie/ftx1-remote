import SwiftUI

/// Maps meter readings onto the needle's sweep, as a fraction 0.0 (hard
/// left, needle at rest) ... 1.0 (hard right). Kept as pure static
/// functions, separate from the drawing, so the anchor points can be
/// unit-tested and later re-tuned against the real rig's meter without
/// touching view code.
///
/// The anchor fractions mirror the FTX-1's own meter face: S1-S9 occupy
/// the left ~55% of the sweep (one S unit = 6dB, evenly spaced), the blue
/// +20/+40/+60 region the rest; the SWR scale compresses non-linearly
/// toward ∞ the way the printed face does.
public enum SMeterScale {
    /// Labeled S-scale tick positions. `blue` marks the over-S9 region,
    /// drawn in blue like the rig's face.
    static let sTicks: [(label: String, fraction: Double, blue: Bool)] = [
        ("1", 0.05, false),
        ("3", 0.17, false),
        ("5", 0.29, false),
        ("7", 0.41, false),
        ("9", 0.53, false),
        ("+20", 0.66, true),
        ("+40", 0.79, true),
        ("+60", 0.92, true),
    ]

    /// Labeled SWR-scale tick positions.
    static let swrTicks: [(label: String, fraction: Double)] = [
        ("1.0", 0.10),
        ("1.5", 0.26),
        ("2", 0.38),
        ("3", 0.52),
        ("5", 0.65),
        ("∞", 0.87),
    ]

    /// RX: signal strength in dB relative to S9 (hamlib "STRENGTH"
    /// convention) -> needle fraction. nil (no reading) rests the needle.
    public static func fraction(forStrengthDb db: Double?) -> Double {
        guard let db else { return 0 }
        // -54dB = S0 (rest), then linear per S unit up to S9 = 0dB, then
        // linear per 20dB segment through the anchors above.
        return piecewise(db, anchors: [
            (-54, 0.0),
            (-48, 0.05),  // S1
            (0, 0.53),    // S9
            (20, 0.66),
            (40, 0.79),
            (60, 0.92),
        ])
    }

    /// TX: SWR reading -> needle fraction on the SWR scale. nil rests the
    /// needle. Clamps at the ∞ tick for anything wildly reflective.
    public static func fraction(forSWR swr: Double?) -> Double {
        guard let swr else { return 0 }
        return piecewise(swr, anchors: [
            (1.0, 0.10),
            (1.5, 0.26),
            (2.0, 0.38),
            (3.0, 0.52),
            (5.0, 0.65),
            (20.0, 0.87),  // effectively ∞
        ])
    }

    /// Linear interpolation through sorted (input, output) anchors,
    /// clamped to the first/last output beyond the ends.
    private static func piecewise(_ x: Double, anchors: [(x: Double, y: Double)]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for (a, b) in zip(anchors, anchors.dropFirst()) where x <= b.x {
            let t = (x - a.x) / (b.x - a.x)
            return a.y + t * (b.y - a.y)
        }
        return last.y
    }
}

/// The rig display's upper-left analog meter, recreated: arc-style S scale
/// (white S1-S9, blue +20/+40/+60 dB) over an SWR scale (1.0-∞), with a
/// red needle sweeping both from a pivot below the visible box. Shows
/// signal strength on the S scale while receiving and the SWR reading on
/// the SWR scale while transmitting. Shared by the Mac and iPad layouts
/// (like `VFODisplayBox`, whose dark-box styling this matches).
public struct SMeterView: View {
    let smeterDb: Double?
    let swr: Double?
    let ptt: Bool

    public init(smeterDb: Double?, swr: Double?, ptt: Bool) {
        self.smeterDb = smeterDb
        self.swr = swr
        self.ptt = ptt
    }

    private var needleFraction: Double {
        ptt ? SMeterScale.fraction(forSWR: swr) : SMeterScale.fraction(forStrengthDb: smeterDb)
    }

    public var body: some View {
        ZStack {
            Canvas { context, size in
                MeterFace.draw(in: &context, size: size)
            }
            NeedleShape(fraction: needleFraction)
                .stroke(Color.red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .shadow(color: .black.opacity(0.3), radius: 1.5, x: 1, y: 1)
        }
        .animation(.easeOut(duration: 0.4), value: needleFraction)
        .background(MeterFace.backlight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            // Recessed-bezel shading: darkens the rim so the lit face
            // reads as sitting behind glass.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.black.opacity(0.55), lineWidth: 3)
                .blur(radius: 2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.6), lineWidth: 1.5)
        )
        .aspectRatio(MeterFace.designSize.width / MeterFace.designSize.height, contentMode: .fit)
    }
}

/// Shared geometry + static face drawing for `SMeterView`. Everything is
/// laid out in a fixed 280x120 design space and scaled to the rendered
/// size (the view pins its aspect ratio, so the scale stays uniform).
/// The needle pivots well below the box, giving the shallow-arc "edge
/// meter" look of the real face.
private enum MeterFace {
    static let designSize = CGSize(width: 280, height: 120)

    /// Half-sweep of the needle/scale arc, radians. Chosen so the arc's
    /// curvature roughly matches the photo of the real face.
    private static let maxAngle = 17.0 * .pi / 180
    /// Outer radius reaching the S-numeral row; sized so the sweep spans
    /// ~92% of the design width.
    private static let outerRadius = 0.46 * 280 / sin(maxAngle)
    /// The S-numeral arc sits this far down the box at center sweep.
    private static let pivot = CGPoint(x: 140, y: 30 + outerRadius)

    /// Angle from vertical for a needle/tick fraction (0 = hard left).
    private static func angle(for fraction: Double) -> Double {
        maxAngle * (2 * fraction - 1)
    }

    /// Design-space point at `fraction` along the sweep, `radialOffset`
    /// inward from the S-numeral arc (larger offset = lower on screen).
    static func point(fraction: Double, radialOffset: Double) -> CGPoint {
        let a = angle(for: fraction)
        let r = outerRadius - radialOffset
        return CGPoint(x: pivot.x + r * sin(a), y: pivot.y - r * cos(a))
    }

    /// Incandescent-lamp look of a backlit analog meter (modeled on an MFJ
    /// SWR/wattmeter face): a warm amber hotspot low and centered, where
    /// the lamp sits, falling off to pale cream toward the edges.
    static var backlight: some View {
        RadialGradient(
            stops: [
                .init(color: Color(red: 1.00, green: 0.88, blue: 0.58), location: 0.0),
                .init(color: Color(red: 1.00, green: 0.94, blue: 0.78), location: 0.4),
                .init(color: Color(red: 0.96, green: 0.92, blue: 0.84), location: 0.75),
                .init(color: Color(red: 0.88, green: 0.85, blue: 0.79), location: 1.0),
            ],
            center: UnitPoint(x: 0.5, y: 0.8),
            startRadius: 0,
            endRadius: 190
        )
    }

    static func draw(in context: inout GraphicsContext, size: CGSize) {
        let scale = size.width / designSize.width
        context.scaleBy(x: scale, y: size.height / designSize.height)

        // Dark ink on the lit face (printed scale, not glowing text).
        let blue = Color(red: 0.10, green: 0.25, blue: 0.75)
        let white = Color(red: 0.10, green: 0.08, blue: 0.06)

        // Row placement, as radial offsets inward from the S-numeral arc.
        let sTickSpan = (14.0, 26.0)
        let swrLabelOffset = 40.0
        let swrTickSpan = (54.0, 64.0)

        func tick(_ fraction: Double, span: (Double, Double), color: Color, width: Double) {
            var path = Path()
            path.move(to: point(fraction: fraction, radialOffset: span.0))
            path.addLine(to: point(fraction: fraction, radialOffset: span.1))
            context.stroke(path, with: .color(color), lineWidth: width)
        }

        // S scale: labeled major ticks, unlabeled minors halfway between.
        // Row-name labels sit at a fixed left margin (leading-anchored, at
        // the arc's left-edge height) rather than on the arc itself, which
        // would center them past the box's left edge and clip them.
        context.draw(
            Text("S").font(.system(size: 13, weight: .bold, design: .rounded)).italic().foregroundStyle(white),
            at: CGPoint(x: 6, y: point(fraction: 0, radialOffset: 2).y), anchor: .leading
        )
        for (label, fraction, isBlue) in SMeterScale.sTicks {
            let color = isBlue ? blue : white
            context.draw(
                Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(color),
                at: point(fraction: fraction, radialOffset: 0)
            )
            tick(fraction, span: sTickSpan, color: color, width: 2)
        }
        for (a, b) in zip(SMeterScale.sTicks, SMeterScale.sTicks.dropFirst()) {
            let mid = (a.fraction + b.fraction) / 2
            tick(mid, span: (sTickSpan.0, sTickSpan.1 - 4), color: b.blue ? blue : white, width: 1)
        }
        context.draw(
            Text("dB").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(blue),
            at: point(fraction: 1.005, radialOffset: 0)
        )

        // SWR scale.
        context.draw(
            Text("SWR").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(white),
            at: CGPoint(x: 6, y: point(fraction: 0, radialOffset: swrLabelOffset - 2).y), anchor: .leading
        )
        for (label, fraction) in SMeterScale.swrTicks {
            context.draw(
                Text(label).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(white),
                at: point(fraction: fraction, radialOffset: swrLabelOffset)
            )
            tick(fraction, span: swrTickSpan, color: white, width: 1.5)
        }
    }

    /// Needle endpoints in design space — from below the bottom edge up
    /// into the S tick row.
    static func needlePoints(fraction: Double) -> (base: CGPoint, tip: CGPoint) {
        (point(fraction: fraction, radialOffset: outerRadius - pivot.y + designSize.height + 10),
         point(fraction: fraction, radialOffset: 10))
    }
}

/// The meter needle as its own `Shape` so SwiftUI can animate the sweep
/// (`Canvas` alone doesn't animate) — `fraction` is the animatable datum.
private struct NeedleShape: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / MeterFace.designSize.width
        let sy = rect.height / MeterFace.designSize.height
        let (base, tip) = MeterFace.needlePoints(fraction: fraction)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + base.x * sx, y: rect.minY + base.y * sy))
        path.addLine(to: CGPoint(x: rect.minX + tip.x * sx, y: rect.minY + tip.y * sy))
        return path
    }
}

#Preview("RX S9+20") {
    SMeterView(smeterDb: 20, swr: nil, ptt: false)
        .frame(width: 280)
        .padding()
}

#Preview("RX quiet") {
    SMeterView(smeterDb: -48, swr: nil, ptt: false)
        .frame(width: 280)
        .padding()
}

#Preview("TX SWR 1.5") {
    SMeterView(smeterDb: nil, swr: 1.5, ptt: true)
        .frame(width: 280)
        .padding()
}

#Preview("No reading") {
    SMeterView(smeterDb: nil, swr: nil, ptt: false)
        .frame(width: 280)
        .padding()
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import SwiftUI

/// The MyKiwiSDR waterfall (the Mac's window, the iPad's pane): the
/// KiwiSDR's rows (`LocalSDRWaterfallStore`), a frequency scale, the
/// passband as a translucent band with the dial line, zoom buttons, and the
/// pointer — click (tap) to tune, drag to pan, scroll wheel to tune in the
/// mode's steps (Mac), pinch to zoom (iPad); dragging the passband's edges
/// sets its width, dragging its middle tunes.
///
/// Everything is drawn in the *requested* view's frame while it has the
/// picture's zoom: the picture is offset to where its rows really are, so a
/// drag follows the mouse at once and the edge coming into view is black
/// until the Kiwi's rows (~150 ms later) fill it. During a zoom change the
/// picture's own frame is used until the first row at the new zoom.
///
/// Only `LocalSDRWaterfallPicture` observes the per-row picture; this view
/// observes the position, which changes only on a pan or zoom, so a row
/// redraws one image and not the scale, passband and controls (measured:
/// re-evaluating all of it per row was most of the window's CPU).
public struct LocalSDRWaterfallView: View {
    @ObservedObject var model: LocalSDRModel
    let store: LocalSDRWaterfallStore
    @ObservedObject private var position: LocalSDRWaterfallPosition

    public init(model: LocalSDRModel, store: LocalSDRWaterfallStore) {
        self.model = model
        self.store = store
        position = store.position
    }

    private static let scaleHeight: CGFloat = 20

    /// The requested start when the drag began.
    @State private var dragOrigin: Int?
    /// Settings → License: Technician-class labels only for a Technician
    /// (or Novice, the same HF privileges); everyone else sees General.
    @AppStorage(PrivilegeChoice.settingsKey) private var licenseChoice = "off"

    private var showsTechnicianPrivileges: Bool {
        switch PrivilegeChoice(rawValue: licenseChoice) {
        case .preset(.usTechnician), .preset(.usNovice): true
        default: false
        }
    }

    /// The dial when a drag of the passband's middle began.
    @State private var tuneDragOrigin: Int?

    public var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let size = proxy.size
                let frame = displayFrame
                VStack(spacing: 0) {
                    if let frame {
                        LocalSDRBandBar(geometry: store.geometry, start: frame.start, zoom: frame.zoom,
                                        width: size.width, showsTechnician: showsTechnicianPrivileges)
                            .frame(height: LocalSDRBandBar.height)
                            .help(Text("localSDR.bandBar.help", bundle: .module))
                    } else {
                        Color.clear.frame(height: LocalSDRBandBar.height)
                    }
                    ZStack(alignment: .topLeading) {
                        Color.black
                        if position.current != nil, let frame {
                            LocalSDRWaterfallPicture(store: store, frame: frame)
                            passbandLayer(frame: frame, width: size.width)
                        } else {
                            placeholder
                        }
                        #if os(macOS)
                        LocalSDRWaterfallMouse(
                            target: { x in dragTarget(atX: x, width: size.width) },
                            onClick: { x in click(atX: x, width: size.width) },
                            onDrag: { target, dx, x in drag(target, dx: dx, x: x, width: size.width) },
                            onDragEnd: {
                                dragOrigin = nil
                                tuneDragOrigin = nil
                            },
                            onScroll: model.scrollStep)
                        #else
                        LocalSDRWaterfallTouch(
                            target: { x in dragTarget(atX: x, width: size.width) },
                            onTap: { x in click(atX: x, width: size.width) },
                            onDrag: { target, dx, x in drag(target, dx: dx, x: x, width: size.width) },
                            onDragEnd: {
                                dragOrigin = nil
                                tuneDragOrigin = nil
                            },
                            onZoom: model.zoom(by:))
                        #endif
                    }
                    .frame(width: size.width,
                           height: max(size.height - Self.scaleHeight - LocalSDRBandBar.height, 0))
                    .clipped()
                    if let frame {
                        LocalSDRFrequencyScale(geometry: store.geometry, start: frame.start, zoom: frame.zoom,
                                               width: size.width)
                            .frame(height: Self.scaleHeight)
                    } else {
                        Color.clear.frame(height: Self.scaleHeight)
                    }
                }
            }
            .help(Text("localSDR.waterfall.help", bundle: .module))
            zoomRow
        }
    }

    // MARK: - Layers

    private func passbandLayer(frame: LocalSDRModel.WaterfallView, width: CGFloat) -> some View {
        let band = model.passbandHz
        let low = x(hz: band.low, frame: frame, width: width)
        let high = x(hz: band.high, frame: frame, width: width)
        let dial = x(hz: Double(model.frequencyHz), frame: frame, width: width)
        return Canvas { context, size in
            let left = min(low, high), right = max(low, high)
            context.fill(Path(CGRect(x: left, y: 0, width: max(right - left, 2), height: size.height)),
                         with: .color(.yellow.opacity(0.18)))
            // The edges, each with a tab at the top to show it can be held.
            for edge in [left, right] {
                var edgeLine = Path()
                edgeLine.move(to: CGPoint(x: edge, y: 0))
                edgeLine.addLine(to: CGPoint(x: edge, y: size.height))
                context.stroke(edgeLine, with: .color(.yellow.opacity(0.55)), lineWidth: 1)
                context.fill(Path(CGRect(x: edge - 1.5, y: 0, width: 3, height: 12)),
                             with: .color(.yellow.opacity(0.9)))
            }
            var line = Path()
            line.move(to: CGPoint(x: dial, y: 0))
            line.addLine(to: CGPoint(x: dial, y: size.height))
            context.stroke(line, with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    private var placeholder: some View {
        Text(placeholderText)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderText: String {
        switch model.waterfallState {
        case .off:
            String(localized: "localSDR.waterfall.idle", bundle: .module)
        case .connecting, .running:
            String(localized: "localSDR.waterfall.waiting", bundle: .module)
        case .failed(let error):
            String(localized: "localSDR.waterfall.failed \(error.localizedMessage)", bundle: .module)
        }
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            Button { model.zoom(by: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(ThemedButtonStyle())
                .disabled(!model.canZoomOut)
                .help(Text("localSDR.zoomOut", bundle: .module))
            Button { model.zoom(by: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(ThemedButtonStyle())
                .disabled(!model.canZoomIn)
                .help(Text("localSDR.zoomIn", bundle: .module))
            if let view = model.waterfallView {
                Text(verbatim: Self.spanText(store.geometry.spanHz(zoom: view.zoom)))
                    .font(.caption.monospacedDigit())
                    .themedSecondaryForeground()
            }
            Text(verbatim: "\(model.passband.rangeText(mode: model.mode)) · \(model.passband.width) Hz")
                .font(.caption.monospacedDigit())
                .themedSecondaryForeground()
                .padding(.leading, 12)
                .help(Text("localSDR.passband.readoutHelp", bundle: .module))
            Button(String(localized: "localSDR.passband.reset", bundle: .module), systemImage: "arrow.counterclockwise",
                   action: model.resetPassband)
                .labelStyle(.titleAndIcon)
                .buttonStyle(ThemedButtonStyle())
                .disabled(model.isPassbandDefault)
                .help(Text("localSDR.passband.resetHelp", bundle: .module))
                .fixedSize()
            Spacer()
            if case .failed(let error) = model.waterfallState, position.current != nil {
                Text(String(localized: "localSDR.waterfall.failed \(error.localizedMessage)", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Geometry

    /// The requested view when it matches the picture's zoom, else the
    /// picture's own position (a zoom in flight). nil without a picture.
    private var displayFrame: LocalSDRModel.WaterfallView? {
        guard let picture = position.current else { return model.waterfallView }
        if let view = model.waterfallView, view.zoom == picture.zoom { return view }
        return picture
    }

    private func x(hz: Double, frame: LocalSDRModel.WaterfallView, width: CGFloat) -> CGFloat {
        let geometry = store.geometry
        return CGFloat(geometry.column(hz: hz, start: frame.start, zoom: frame.zoom) / Double(geometry.fftSize)) * width
    }

    private func click(atX x: CGFloat, width: CGFloat) {
        guard let frame = displayFrame, width > 0 else { return }
        let geometry = store.geometry
        let column = Double(x / width) * Double(geometry.fftSize)
        model.tune(toWaterfallHz: geometry.hz(column: column, start: frame.start, zoom: frame.zoom))
    }

    private func hz(atX x: CGFloat, frame: LocalSDRModel.WaterfallView, width: CGFloat) -> Double {
        let geometry = store.geometry
        return geometry.hz(column: Double(x / width) * Double(geometry.fftSize), start: frame.start, zoom: frame.zoom)
    }

    /// What a press at `x` would hold: 5 pt (a finger: 14 pt) either side
    /// of an edge is that edge (less on the inside of a narrow band, so its
    /// middle stays reachable); the rest of the band is its middle.
    private func dragTarget(atX x: CGFloat, width: CGFloat) -> LocalSDRWaterfallDragTarget {
        guard position.current != nil, let frame = displayFrame, width > 0 else { return .pan }
        let band = model.passbandHz
        let a = self.x(hz: band.low, frame: frame, width: width)
        let b = self.x(hz: band.high, frame: frame, width: width)
        let low = min(a, b), high = max(a, b)
        #if os(macOS)
        let reach: CGFloat = 5
        #else
        let reach: CGFloat = 14
        #endif
        let outward = reach
        let inward = min(reach, (high - low) / 3)
        if x >= low + inward, x <= high - inward { return .middle }
        if x >= low - outward, x < low + inward { return .edge(.low) }
        if x > high - inward, x <= high + outward { return .edge(.high) }
        return .pan
    }

    private func drag(_ target: LocalSDRWaterfallDragTarget, dx: CGFloat, x: CGFloat, width: CGFloat) {
        guard let frame = displayFrame, width > 0 else { return }
        switch target {
        case .pan:
            pan(by: dx, width: width)
        case .edge(let edge):
            model.dragPassbandEdge(edge, toWaterfallHz: hz(atX: x, frame: frame, width: width))
        case .middle:
            let origin = tuneDragOrigin ?? model.frequencyHz
            if tuneDragOrigin == nil { tuneDragOrigin = origin }
            let span = store.geometry.spanHz(zoom: frame.zoom)
            model.tune(toWaterfallHz: Double(origin) + Double(dx / width) * span)
        }
    }

    private func pan(by dx: CGFloat, width: CGFloat) {
        guard let view = model.waterfallView, width > 0 else { return }
        let origin = dragOrigin ?? view.start
        if dragOrigin == nil { dragOrigin = origin }
        let geometry = store.geometry
        let units = Double(dx / width) * Double(geometry.spanUnits(zoom: view.zoom))
        model.pan(toStart: origin - Int(units.rounded()))
    }

    public static func spanText(_ hz: Double) -> String {
        hz >= 1_000_000
            ? "\(FrequencyFormat.mhz(hz, fractionDigits: hz >= 10_000_000 ? 0 : 1)) MHz"
            : "\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), hz / 1000)) kHz"
    }
}

#if os(macOS)
/// The waterfall image itself — the one thing that changes per row. A
/// layer-backed NSView that sets `layer.contents` straight from the
/// store's publisher, so a row is a Core Animation transaction and nothing
/// in SwiftUI re-evaluates or lays out (measured in a Debug build: with a
/// SwiftUI `Image` per row, hosting-view layout was most of the cost). The
/// image is offset from `frame` (what everything else is drawn in) to
/// where its rows really are, and filtered linearly: 1024 bins usually get
/// squeezed into fewer points, and nearest-neighbour would drop narrow
/// signals.
private struct LocalSDRWaterfallPicture: NSViewRepresentable {
    let store: LocalSDRWaterfallStore
    let frame: LocalSDRModel.WaterfallView

    func makeNSView(context: Context) -> PictureView {
        let view = PictureView()
        view.subscribe(to: store)
        view.frameInView = frame
        return view
    }

    func updateNSView(_ view: PictureView, context: Context) {
        view.frameInView = frame
    }

    final class PictureView: NSView {
        var frameInView: LocalSDRModel.WaterfallView? {
            didSet { if frameInView != oldValue { place() } }
        }
        private weak var store: LocalSDRWaterfallStore?
        private var subscription: AnyCancellable?
        private let imageLayer = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            imageLayer.contentsGravity = .resize
            imageLayer.minificationFilter = .linear
            imageLayer.magnificationFilter = .linear
            imageLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(imageLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func subscribe(to store: LocalSDRWaterfallStore) {
            self.store = store
            subscription = store.$picture.sink { [weak self] picture in
                // `sink` runs before the property is set: use the value.
                self?.show(picture)
            }
        }

        private var picture: LocalSDRWaterfallStore.Picture?

        private func show(_ picture: LocalSDRWaterfallStore.Picture?) {
            self.picture = picture
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = picture?.image
            placeLayer()
            CATransaction.commit()
        }

        private func place() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placeLayer()
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            place()
        }

        private func placeLayer() {
            guard let store, let picture, let frameInView else {
                imageLayer.frame = bounds
                return
            }
            let geometry = store.geometry
            let offsetColumns = picture.zoom == frameInView.zoom
                ? Double(picture.start - frameInView.start) / Double(geometry.unitsPerBin(zoom: frameInView.zoom))
                : 0
            imageLayer.frame = bounds.offsetBy(dx: CGFloat(offsetColumns / Double(geometry.fftSize)) * bounds.width,
                                               dy: 0)
        }
    }
}

#else
/// The iPad's waterfall image: the Mac's picture (see above) on a UIView's
/// layer, set straight from the store's publisher, so a row is a Core
/// Animation transaction and nothing in SwiftUI re-evaluates. Touches pass
/// through to `LocalSDRWaterfallTouch`.
private struct LocalSDRWaterfallPicture: UIViewRepresentable {
    let store: LocalSDRWaterfallStore
    let frame: LocalSDRModel.WaterfallView

    func makeUIView(context: Context) -> PictureView {
        let view = PictureView()
        view.subscribe(to: store)
        view.frameInView = frame
        return view
    }

    func updateUIView(_ view: PictureView, context: Context) {
        view.frameInView = frame
    }

    final class PictureView: UIView {
        var frameInView: LocalSDRModel.WaterfallView? {
            didSet { if frameInView != oldValue { place() } }
        }
        private weak var store: LocalSDRWaterfallStore?
        private var subscription: AnyCancellable?
        private var picture: LocalSDRWaterfallStore.Picture?
        private let imageLayer = CALayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .black
            layer.masksToBounds = true
            imageLayer.contentsGravity = .resize
            imageLayer.minificationFilter = .linear
            imageLayer.magnificationFilter = .linear
            imageLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer.addSublayer(imageLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func subscribe(to store: LocalSDRWaterfallStore) {
            self.store = store
            subscription = store.$picture.sink { [weak self] picture in
                self?.show(picture)
            }
        }

        private func show(_ picture: LocalSDRWaterfallStore.Picture?) {
            self.picture = picture
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = picture?.image
            placeLayer()
            CATransaction.commit()
        }

        private func place() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placeLayer()
            CATransaction.commit()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            place()
        }

        private func placeLayer() {
            guard let store, let picture, let frameInView else {
                imageLayer.frame = bounds
                return
            }
            let geometry = store.geometry
            let offsetColumns = picture.zoom == frameInView.zoom
                ? Double(picture.start - frameInView.start) / Double(geometry.unitsPerBin(zoom: frameInView.zoom))
                : 0
            imageLayer.frame = bounds.offsetBy(dx: CGFloat(offsetColumns / Double(geometry.fftSize)) * bounds.width,
                                               dy: 0)
        }
    }
}
#endif

/// Tick marks and MHz labels across the span: a 1/2/5 × 10ⁿ Hz spacing
/// giving labels at least ~80 pt apart, decimals to match it.
private struct LocalSDRFrequencyScale: View, Equatable {
    let geometry: KiwiWaterfallGeometry
    let start: Int
    let zoom: Int
    let width: CGFloat

    var body: some View {
        let span = geometry.spanHz(zoom: zoom)
        let leftHz = geometry.hz(column: 0, start: start, zoom: zoom)
        let spacing = Self.tickSpacing(spanHz: span, width: width)
        let digits = max(0, Int((-log10(spacing / 1_000_000)).rounded(.up)))
        let first = (leftHz / spacing).rounded(.up) * spacing
        let ticks = stride(from: first, through: leftHz + span, by: spacing).map { $0 }
        Canvas { context, size in
            for hz in ticks {
                let x = CGFloat((hz - leftHz) / span) * size.width
                var mark = Path()
                mark.move(to: CGPoint(x: x, y: 0))
                mark.addLine(to: CGPoint(x: x, y: 5))
                context.stroke(mark, with: .color(.secondary), lineWidth: 1)
                let label = Text(verbatim: FrequencyFormat.mhz(hz, fractionDigits: digits))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: x, y: 6), anchor: .top)
            }
        }
        .frame(width: width)
    }

    static func tickSpacing(spanHz: Double, width: CGFloat) -> Double {
        let labels = max(2, Double(width) / 80)
        let raw = spanHz / labels
        let power = pow(10, (log10(raw)).rounded(.down))
        for factor in [1.0, 2, 5, 10] where factor * power >= raw {
            return factor * power
        }
        return 10 * power
    }
}

/// The band bar over the waterfall, like the KiwiSDR page's: the bands in
/// view by name ("40m Amateur", "MW Broadcast") on the top line, and, once
/// an amateur band fills at least a third of the view
/// (`BandHints.showsPlan`), its US band plan on the second: CW/data,
/// phone, all-mode and CW-only sub-bands in their own colours, each
/// labelled with the lowest class allowed there (Technician only when
/// that's the license picked in Settings, else General), Extra-only parts
/// hatched; and on the third, the ARRL's voluntary plan inside them
/// (`ARRLBandPlan`: RTTY/data, packet, DX windows, QRP/SSTV/AM calling,
/// beacons) and the usual FT8/FT4/JS8/WSPR/PSK31 dial frequencies (pink).
/// A maritime band, zoomed in the same way, gets its GMDSS frequencies on
/// that line instead (`GMDSSFrequencies`: DSC, voice and NBDP distress in
/// red, NAVTEX and MSI in yellow). Labels sit in the visible part of their band, shortened or
/// left out when they don't fit.
private struct LocalSDRBandBar: View, Equatable {
    let geometry: KiwiWaterfallGeometry
    let start: Int
    let zoom: Int
    let width: CGFloat
    let showsTechnician: Bool

    static let rowHeight: CGFloat = 15
    static let height: CGFloat = rowHeight * 3 + 2

    var body: some View {
        let span = geometry.spanHz(zoom: zoom)
        let lowHz = geometry.hz(column: 0, start: start, zoom: zoom)
        let highHz = lowHz + span
        let hints = BandHints.hints(lowHz: lowHz, highHz: highHz)
        Canvas { context, size in
            func x(_ hz: Int) -> CGFloat { CGFloat((Double(hz) - lowHz) / span) * size.width }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            let planRow = CGRect(x: 0, y: Self.rowHeight + 1, width: size.width, height: Self.rowHeight)
            let markerRow = CGRect(x: 0, y: planRow.maxY + 1, width: size.width, height: Self.rowHeight)
            for hint in hints {
                let rect = CGRect(x: x(hint.lowerHz), y: 0, width: x(hint.upperHz) - x(hint.lowerHz),
                                  height: Self.rowHeight)
                Self.drawBand(hint, in: rect, width: size.width, context: &context)
                guard BandHints.showsPlan(for: hint, lowHz: lowHz, highHz: highHz) else { continue }
                guard let band = hint.band else {
                    // A maritime band: its GMDSS frequencies on the marker line.
                    Self.drawMarkers(GMDSSFrequencies.markers(in: hint), row: markerRow, x: x, context: &context)
                    continue
                }
                for segment in AmateurBandPlan.segments(for: band, showsTechnician: showsTechnician) {
                    let segmentRect = CGRect(x: x(segment.lowerHz), y: planRow.minY,
                                             width: x(segment.upperHz) - x(segment.lowerHz),
                                             height: planRow.height)
                    Self.drawSegment(segment, in: segmentRect, width: size.width, context: &context)
                }
                Self.drawMarkers(ARRLBandPlan.markers(for: band), row: markerRow, x: x, context: &context)
            }
        }
        .frame(width: width)
    }

    private static func color(for kind: BandHint.Kind) -> Color {
        switch kind {
        case .amateur: Color(red: 0.25, green: 0.65, blue: 0.35)
        case .broadcast: Color(red: 0.35, green: 0.5, blue: 0.75)
        case .aeronautical: Color(red: 0.75, green: 0.55, blue: 0.3)
        case .maritime: Color(red: 0.2, green: 0.6, blue: 0.6)
        case .utility: Color(white: 0.5)
        }
    }

    private static func color(for usage: AmateurBandPlanSegment.Usage) -> Color {
        switch usage {
        case .cwData, .cwOnly: Color(red: 0.3, green: 0.55, blue: 0.95)
        case .phone: Color(red: 0.95, green: 0.6, blue: 0.2)
        case .allModes: Color(red: 0.7, green: 0.45, blue: 0.9)
        case .channel: Color(red: 0.25, green: 0.75, blue: 0.75)
        }
    }

    private static func drawBand(_ hint: BandHint, in rect: CGRect, width: CGFloat,
                                 context: inout GraphicsContext) {
        let color = color(for: hint.kind)
        let shown = rect.insetBy(dx: 0.5, dy: 1)
        context.fill(Path(shown), with: .color(color.opacity(0.35)))
        context.stroke(Path(shown), with: .color(color.opacity(0.9)), lineWidth: 1)
        let candidates = switch hint.kind {
        case .amateur: [String(localized: "localSDR.bandBar.amateur \(hint.label)", bundle: .module), hint.label]
        case .broadcast: [String(localized: "localSDR.bandBar.broadcast \(hint.label)", bundle: .module), hint.label]
        case .aeronautical: [String(localized: "localSDR.bandBar.aeronautical \(hint.label)", bundle: .module),
                             String(localized: "localSDR.bandBar.aero", bundle: .module), hint.label]
        case .maritime: [String(localized: "localSDR.bandBar.maritime \(hint.label)", bundle: .module),
                         String(localized: "localSDR.bandBar.marine", bundle: .module), hint.label]
        case .utility: [hint.label]
        }
        drawLabel(candidates, in: rect, width: width, context: &context)
    }

    private static func drawSegment(_ segment: AmateurBandPlanSegment, in rect: CGRect, width: CGFloat,
                                    context: inout GraphicsContext) {
        let color = color(for: segment.usage)
        let shown = rect.insetBy(dx: 0.5, dy: 0.5)
        context.fill(Path(shown), with: .color(color.opacity(0.4)))
        if segment.lowestClass == .extra {
            // Extra only: hatched.
            var hatch = Path()
            var lineX = (shown.minX / 6).rounded(.down) * 6 - shown.height
            while lineX < shown.maxX {
                hatch.move(to: CGPoint(x: lineX, y: shown.maxY))
                hatch.addLine(to: CGPoint(x: lineX + shown.height, y: shown.minY))
                lineX += 6
            }
            context.drawLayer { layer in
                layer.clip(to: Path(shown))
                layer.stroke(hatch, with: .color(color.opacity(0.8)), lineWidth: 1)
            }
        }
        context.stroke(Path(shown), with: .color(color), lineWidth: 1)
        let usage = switch segment.usage {
        case .cwData: String(localized: "localSDR.bandBar.cwData", bundle: .module)
        case .phone: String(localized: "localSDR.bandBar.phone", bundle: .module)
        case .allModes: String(localized: "localSDR.bandBar.allModes", bundle: .module)
        case .cwOnly: "CW"
        case .channel: String(localized: "localSDR.bandBar.channel", bundle: .module)
        }
        // US class names, English in every language (as in Settings → License).
        let licence = switch segment.lowestClass {
        case .technician: "Technician"
        case .general: "General"
        case .advanced: "Advanced"
        case .extra: "Extra"
        }
        let both = String(localized: "localSDR.bandBar.segment \(usage) \(licence)", bundle: .module)
        let short = segment.lowestClass == .extra ? [both, licence, usage] : [both, usage]
        drawLabel(short, in: rect, width: width, context: &context)
    }

    private static func color(for kind: BandPlanMarker.Kind) -> Color {
        switch kind {
        case .data, .dataDX, .packet: Color(red: 0.45, green: 0.75, blue: 1)
        case .dxWindow, .qrpCW: Color(red: 0.4, green: 0.9, blue: 0.85)
        case .qrpSSB, .sstv, .amCalling, .am: Color(red: 1, green: 0.75, blue: 0.4)
        case .beacons, .ncdxfBeacons, .experimental: Color(red: 0.95, green: 0.9, blue: 0.4)
        case .satellite, .repeaterInputs, .repeaterOutputs, .fmSimplex: Color(red: 0.55, green: 0.9, blue: 0.5)
        case .ft8, .ft4, .js8, .wspr, .psk31: Color(red: 1, green: 0.5, blue: 0.85)
        case .dscDistress, .voiceDistress, .nbdpDistress: Color(red: 1, green: 0.35, blue: 0.3)
        case .navtex, .msi: Color(red: 0.95, green: 0.9, blue: 0.4)
        }
    }

    private static func label(for kind: BandPlanMarker.Kind) -> String {
        switch kind {
        case .data: "RTTY/Data"
        case .dataDX: "RTTY/Data DX"
        case .packet: String(localized: "localSDR.bandBar.arrl.packet", bundle: .module)
        case .dxWindow: String(localized: "localSDR.bandBar.arrl.dxWindow", bundle: .module)
        case .qrpCW: "QRP CW"
        case .qrpSSB: "QRP SSB"
        case .sstv: "SSTV"
        case .amCalling: String(localized: "localSDR.bandBar.arrl.amCalling", bundle: .module)
        case .am: "AM"
        case .beacons: String(localized: "localSDR.bandBar.arrl.beacons", bundle: .module)
        case .ncdxfBeacons: "NCDXF"
        case .experimental: String(localized: "localSDR.bandBar.arrl.experimental", bundle: .module)
        case .satellite: String(localized: "localSDR.bandBar.arrl.satellite", bundle: .module)
        case .repeaterInputs: String(localized: "localSDR.bandBar.arrl.repeaterIn", bundle: .module)
        case .repeaterOutputs: String(localized: "localSDR.bandBar.arrl.repeaterOut", bundle: .module)
        case .fmSimplex: String(localized: "localSDR.bandBar.arrl.fmSimplex", bundle: .module)
        case .ft8: "FT8"
        case .ft4: "FT4"
        case .js8: "JS8"
        case .wspr: "WSPR"
        case .psk31: "PSK31"
        case .dscDistress: "DSC"
        case .voiceDistress: String(localized: "localSDR.bandBar.gmdss.voice", bundle: .module)
        case .nbdpDistress: "NBDP"
        case .navtex: "NAVTEX"
        case .msi: "MSI"
        }
    }

    /// The ARRL line: ranges as outlined boxes labelled inside, single
    /// frequencies as a tick with its label in a dark tab beside it.
    /// Labels never overlap: each goes where it fits among those already
    /// placed (ranges first, then spots by `labelPriority` — FT8 before
    /// FT4 before the ARRL's spots before JS8/WSPR/PSK31), else the mark is
    /// drawn unlabelled.
    private static func drawMarkers(_ markers: [BandPlanMarker], row: CGRect, x: (Int) -> CGFloat,
                                    context: inout GraphicsContext) {
        var placed: [CGRect] = []
        /// Ticks of spots already labelled: no other label may cover them,
        /// or a label would sit beside the wrong tick.
        var labelledTicks: [CGFloat] = []
        @discardableResult
        func place(_ text: String, color: Color, candidates: [(CGFloat) -> CGRect?],
                   context: inout GraphicsContext, background: Bool) -> Bool {
            let resolved = context.resolve(Text(verbatim: text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(background ? color : .white))
            let width = resolved.measure(in: CGSize(width: .infinity, height: row.height)).width + 6
            for candidate in candidates {
                guard let rect = candidate(width), rect.minX >= 0, rect.maxX <= row.maxX,
                      !placed.contains(where: { $0.intersects(rect) }),
                      !labelledTicks.contains(where: { $0 >= rect.minX - 1 && $0 <= rect.maxX + 1 })
                else { continue }
                if background {
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.black.opacity(0.85)))
                }
                context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                placed.append(rect)
                return true
            }
            return false
        }
        for marker in markers where !marker.isSpot {
            let color = color(for: marker.kind)
            let rect = CGRect(x: x(marker.lowerHz), y: row.minY, width: x(marker.upperHz) - x(marker.lowerHz),
                              height: row.height).insetBy(dx: 0.5, dy: 0.5)
            context.fill(Path(rect), with: .color(color.opacity(0.25)))
            context.stroke(Path(rect), with: .color(color.opacity(0.9)), lineWidth: 1)
            let visible = rect.intersection(row)
            guard !visible.isNull else { continue }
            place(label(for: marker.kind), color: color, candidates: [{ width in
                width <= visible.width
                    ? CGRect(x: visible.midX - width / 2, y: row.minY, width: width, height: row.height) : nil
            }], context: &context, background: false)
        }
        // Every tick first, so a label's dark tab covers its neighbours'
        // ticks instead of being crossed by them (FT8/FT4/JS8 sit 2–5 kHz
        // apart).
        let spots = markers.filter { $0.isSpot && (row.minX...row.maxX).contains(x($0.lowerHz)) }
        for marker in spots {
            let tick = x(marker.lowerHz)
            var line = Path()
            line.move(to: CGPoint(x: tick, y: row.minY))
            line.addLine(to: CGPoint(x: tick, y: row.maxY))
            context.stroke(line, with: .color(color(for: marker.kind)), lineWidth: 1.5)
        }
        for marker in spots {
            let color = color(for: marker.kind)
            let tick = x(marker.lowerHz)
            let top = row.minY + 1, height = row.height - 2
            if place(label(for: marker.kind), color: color, candidates: [
                { CGRect(x: tick + 2, y: top, width: $0, height: height) },
                { CGRect(x: tick - 2 - $0, y: top, width: $0, height: height) },
            ], context: &context, background: true) {
                labelledTicks.append(tick)
            }
        }
    }

    /// The first of `candidates` that fits the visible part of `rect`,
    /// centred there; nothing if none does.
    private static func drawLabel(_ candidates: [String], in rect: CGRect, width: CGFloat,
                                  context: inout GraphicsContext) {
        let visible = rect.intersection(CGRect(x: 0, y: rect.minY, width: width, height: rect.height))
        guard !visible.isNull, visible.width > 12 else { return }
        for candidate in candidates {
            let text = context.resolve(Text(verbatim: candidate)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white))
            if text.measure(in: CGSize(width: .infinity, height: rect.height)).width + 6 <= visible.width {
                context.draw(text, at: CGPoint(x: visible.midX, y: visible.midY), anchor: .center)
                return
            }
        }
    }
}

/// What a press on the waterfall holds.
private enum LocalSDRWaterfallDragTarget: Equatable {
    case pan
    case edge(KiwiPassband.Edge)
    case middle

    #if os(macOS)
    var cursor: NSCursor {
        switch self {
        case .pan: .crosshair
        case .edge: .resizeLeftRight
        case .middle: .openHand
        }
    }

    var dragCursor: NSCursor {
        switch self {
        case .pan, .middle: .closedHand
        case .edge: .resizeLeftRight
        }
    }
    #endif
}

#if os(macOS)
/// Mouse handling the SwiftUI gestures can't do on macOS (scroll wheel,
/// a cursor that depends on where the passband is) or can't tell apart
/// cleanly (a click that may turn into a drag): a press that moves less
/// than 3 pt is a click, else a drag of whatever was under the press,
/// reporting the distance from the press and the mouse's position. Wheel:
/// one step per notch, or per 10 pt of trackpad scrolling.
private struct LocalSDRWaterfallMouse: NSViewRepresentable {
    let target: (CGFloat) -> LocalSDRWaterfallDragTarget
    let onClick: (CGFloat) -> Void
    let onDrag: (LocalSDRWaterfallDragTarget, CGFloat, CGFloat) -> Void
    let onDragEnd: () -> Void
    let onScroll: (Int) -> Void

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        update(view)
        return view
    }

    func updateNSView(_ view: MouseView, context: Context) { update(view) }

    private func update(_ view: MouseView) {
        view.target = target
        view.onClick = onClick
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onScroll = onScroll
    }

    final class MouseView: NSView {
        var target: (CGFloat) -> LocalSDRWaterfallDragTarget = { _ in .pan }
        var onClick: (CGFloat) -> Void = { _ in }
        var onDrag: (LocalSDRWaterfallDragTarget, CGFloat, CGFloat) -> Void = { _, _, _ in }
        var onDragEnd: () -> Void = {}
        var onScroll: (Int) -> Void = { _ in }

        private var pressX: CGFloat?
        private var pressTarget = LocalSDRWaterfallDragTarget.pan
        private var dragging = false
        private var scrollAccumulator: CGFloat = 0
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        private func updateCursor(_ event: NSEvent) {
            guard !dragging else { return }
            target(localX(event)).cursor.set()
        }

        override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
        override func mouseMoved(with event: NSEvent) { updateCursor(event) }

        private func localX(_ event: NSEvent) -> CGFloat {
            convert(event.locationInWindow, from: nil).x
        }

        override func mouseDown(with event: NSEvent) {
            // Only presses on the waterfall itself (a synthetic event can
            // arrive with a point outside it).
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
                pressX = nil
                return
            }
            let x = localX(event)
            pressX = x
            pressTarget = target(x)
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressX else { return }
            let x = localX(event)
            let dx = x - pressX
            if !dragging, abs(dx) < 3 { return }
            if !dragging { pressTarget.dragCursor.set() }
            dragging = true
            onDrag(pressTarget, dx, x)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                pressX = nil
                dragging = false
                updateCursor(event)
            }
            if dragging {
                onDragEnd()
            } else if pressX != nil {
                onClick(localX(event))
            }
        }

        override func scrollWheel(with event: NSEvent) {
            let delta = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                if event.phase == .began { scrollAccumulator = 0 }
                scrollAccumulator += delta
                let steps = Int(scrollAccumulator / 10)
                if steps != 0 {
                    scrollAccumulator -= CGFloat(steps) * 10
                    for _ in 0..<abs(steps) { onScroll(steps > 0 ? 1 : -1) }
                }
            } else if delta != 0 {
                onScroll(delta > 0 ? 1 : -1)
            }
        }
    }
}
#else
/// The iPad's touches: a tap tunes; a drag (past 6 pt) holds whatever was
/// under the finger — the passband's edge, its middle, or else the
/// waterfall itself (pan) — and reports the distance from the touch-down
/// and the finger's position, as the Mac's mouse does; a pinch zooms one
/// step per doubling (or halving).
private struct LocalSDRWaterfallTouch: View {
    let target: (CGFloat) -> LocalSDRWaterfallDragTarget
    let onTap: (CGFloat) -> Void
    let onDrag: (LocalSDRWaterfallDragTarget, CGFloat, CGFloat) -> Void
    let onDragEnd: () -> Void
    let onZoom: (Int) -> Void

    @State private var pressTarget: LocalSDRWaterfallDragTarget?
    @State private var dragging = false
    @State private var pinching = false
    @State private var pinchSteps = 0

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !pinching else { return }
                        let held = pressTarget ?? target(value.startLocation.x)
                        if pressTarget == nil { pressTarget = held }
                        let dx = value.translation.width
                        if !dragging, abs(dx) < 6 { return }
                        dragging = true
                        onDrag(held, dx, value.location.x)
                    }
                    .onEnded { value in
                        if dragging {
                            onDragEnd()
                        } else if !pinching {
                            onTap(value.location.x)
                        }
                        pressTarget = nil
                        dragging = false
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if !pinching {
                            pinching = true
                            // A pinch isn't a pan: undo nothing, just stop
                            // the drag that started with the first finger.
                            if dragging { onDragEnd() }
                            dragging = false
                        }
                        let steps = Int(log2(max(value.magnification, 0.01)).rounded())
                        if steps != pinchSteps {
                            onZoom(steps - pinchSteps)
                            pinchSteps = steps
                        }
                    }
                    .onEnded { _ in
                        pinching = false
                        pinchSteps = 0
                    }
            )
    }
}
#endif

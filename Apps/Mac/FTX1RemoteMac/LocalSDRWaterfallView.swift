import AppKit
import Combine
import FTX1Core
import SwiftUI

/// The Local SDR window's waterfall: the KiwiSDR's rows
/// (`LocalSDRWaterfallStore`), a frequency scale, the passband as a
/// translucent band with the dial line, zoom buttons, and the mouse —
/// click to tune, drag to pan, scroll wheel to tune in the mode's steps;
/// dragging the passband's edges sets its width, dragging its middle tunes.
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
struct LocalSDRWaterfallView: View {
    @ObservedObject var model: LocalSDRModel
    let store: LocalSDRWaterfallStore
    @ObservedObject private var position: LocalSDRWaterfallPosition

    init(model: LocalSDRModel, store: LocalSDRWaterfallStore) {
        self.model = model
        self.store = store
        position = store.position
    }

    private static let scaleHeight: CGFloat = 20

    /// The requested start when the drag began.
    @State private var dragOrigin: Int?
    /// The dial when a drag of the passband's middle began.
    @State private var tuneDragOrigin: Int?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let size = proxy.size
                let frame = displayFrame
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        Color.black
                        if position.current != nil, let frame {
                            LocalSDRWaterfallPicture(store: store, frame: frame)
                            passbandLayer(frame: frame, width: size.width)
                        } else {
                            placeholder
                        }
                        LocalSDRWaterfallMouse(
                            target: { x in dragTarget(atX: x, width: size.width) },
                            onClick: { x in click(atX: x, width: size.width) },
                            onDrag: { target, dx, x in drag(target, dx: dx, x: x, width: size.width) },
                            onDragEnd: {
                                dragOrigin = nil
                                tuneDragOrigin = nil
                            },
                            onScroll: model.scrollStep)
                    }
                    .frame(width: size.width, height: max(size.height - Self.scaleHeight, 0))
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
            .help("localSDR.waterfall.help")
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
            String(localized: "localSDR.waterfall.idle")
        case .connecting, .running:
            String(localized: "localSDR.waterfall.waiting")
        case .failed(let error):
            String(localized: "localSDR.waterfall.failed \(LocalSDRWindowView.message(for: error))")
        }
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            Button { model.zoom(by: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(ThemedButtonStyle())
                .disabled(!model.canZoomOut)
                .help("localSDR.zoomOut")
            Button { model.zoom(by: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(ThemedButtonStyle())
                .disabled(!model.canZoomIn)
                .help("localSDR.zoomIn")
            if let view = model.waterfallView {
                Text(verbatim: Self.spanText(store.geometry.spanHz(zoom: view.zoom)))
                    .font(.caption.monospacedDigit())
                    .themedSecondaryForeground()
            }
            Text(verbatim: "\(model.passband.rangeText(mode: model.mode)) · \(model.passband.width) Hz")
                .font(.caption.monospacedDigit())
                .themedSecondaryForeground()
                .padding(.leading, 12)
                .help("localSDR.passband.readoutHelp")
            Button("localSDR.passband.reset", systemImage: "arrow.counterclockwise", action: model.resetPassband)
                .labelStyle(.titleAndIcon)
                .buttonStyle(ThemedButtonStyle())
                .disabled(model.isPassbandDefault)
                .help("localSDR.passband.resetHelp")
                .fixedSize()
            Spacer()
            if case .failed(let error) = model.waterfallState, position.current != nil {
                Text(String(localized: "localSDR.waterfall.failed \(LocalSDRWindowView.message(for: error))"))
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

    /// What a press at `x` would hold: 5 pt either side of an edge is that
    /// edge (less on the inside of a narrow band, so its middle stays
    /// reachable); the rest of the band is its middle.
    private func dragTarget(atX x: CGFloat, width: CGFloat) -> LocalSDRWaterfallDragTarget {
        guard position.current != nil, let frame = displayFrame, width > 0 else { return .pan }
        let band = model.passbandHz
        let a = self.x(hz: band.low, frame: frame, width: width)
        let b = self.x(hz: band.high, frame: frame, width: width)
        let low = min(a, b), high = max(a, b)
        let outward: CGFloat = 5
        let inward = min(5, (high - low) / 3)
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

    static func spanText(_ hz: Double) -> String {
        hz >= 1_000_000
            ? "\(FrequencyFormat.mhz(hz, fractionDigits: hz >= 10_000_000 ? 0 : 1)) MHz"
            : "\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), hz / 1000)) kHz"
    }
}

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

/// What a press on the waterfall holds.
private enum LocalSDRWaterfallDragTarget: Equatable {
    case pan
    case edge(KiwiPassband.Edge)
    case middle

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
}

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

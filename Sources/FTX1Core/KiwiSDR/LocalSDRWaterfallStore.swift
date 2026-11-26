#if os(macOS)
import AppKit
#endif
import Combine
import CoreGraphics
import Foundation

/// The MyKiwiSDR waterfall picture (the Mac's window, the iPad's pane): KiwiSDR rows (~19 a second)
/// placed by their own header, kept apart from `LocalSDRModel` and observed
/// only by `LocalSDRWaterfallView` (the leaf-only rule `ScopeFrameStore`
/// set), so a row never re-renders the rest of the window.
///
/// Unlike the Kiwi's page, the picture survives retuning: a row at the
/// same position just goes on top; at the same zoom but moved (a pan), the
/// history shifts sideways by whole bins and only the exposed edge starts
/// blank; at another zoom the history is rescaled (`KiwiWaterfallPlacement.
/// columnMap` — one table lookup per pixel, once per zoom step, a few ms:
/// cheap enough, and keeping the history reads better than clearing it).
@MainActor
public final class LocalSDRWaterfallStore: ObservableObject {
    /// What's on screen: the image and the position of its newest row,
    /// published together so the scale and passband always match the
    /// picture under them.
    public struct Picture {
        public let image: CGImage
        public let start: Int
        public let zoom: Int
    }

    /// Every row (~19 a second): observed only by the image leaf.
    @Published public private(set) var picture: Picture?
    /// The newest row's position, published only when it changes (a pan
    /// or zoom), so the scale, passband and controls don't re-render per
    /// row. nil without a picture.
    public let position = LocalSDRWaterfallPosition()
    public private(set) var geometry = KiwiWaterfallGeometry()

    public static let historyRows = 300

    public init() {}

    private var cal = -13
    private var bitmap: PannableWaterfallBitmap?
    private var anchor: (xBin: Int, zoom: Int)?
    private var autoRange = KiwiWaterfallAutoRange()
    /// Wire byte → packed pixel, rebuilt when the auto-range moves.
    private var colors = [UInt32](repeating: WaterfallPalette.lut[0], count: 256)

    /// A new stream: its geometry and calibration. Clears the picture.
    public func configure(geometry: KiwiWaterfallGeometry, cal: Int) {
        self.geometry = geometry
        self.cal = cal
        bitmap = PannableWaterfallBitmap(width: geometry.fftSize, height: Self.historyRows)
        anchor = nil
        autoRange.reset()
        picture = nil
        position.set(nil)
    }

    public func reset() {
        bitmap = nil
        anchor = nil
        autoRange.reset()
        picture = nil
        position.set(nil)
    }

    public func add(_ row: KiwiWaterfallFrame) {
        guard let bitmap, row.bins.count == geometry.fftSize, row.zoom <= geometry.zoomMax else { return }
        let rowPosition = (xBin: row.xBin, zoom: row.zoom)
        switch KiwiWaterfallPlacement.place(row: rowPosition, anchor: anchor, geometry: geometry) {
        case .append:
            break
        case .shift(let bins):
            bitmap.shift(bins: bins)
        case .rezoom:
            if let anchor {
                bitmap.remap(KiwiWaterfallPlacement.columnMap(from: anchor, to: rowPosition, geometry: geometry))
            }
        }
        anchor = rowPosition
        if autoRange.add(row.bins, cal: cal) {
            let steps = autoRange.paletteSteps(cal: cal)
            colors = steps.map { WaterfallPalette.lut[Int($0)] }
        }
        bitmap.append(row.bins, colors: colors)
        if let image = bitmap.makeImage() {
            picture = Picture(image: image, start: row.xBin, zoom: row.zoom)
            position.set(LocalSDRModel.WaterfallView(start: row.xBin, zoom: row.zoom))
        }
    }

    /// The colour range in use, for the help text.
    public var rangeDBm: (floor: Double, ceiling: Double)? {
        autoRange.isSettled ? (autoRange.floorDBm, autoRange.ceilingDBm) : nil
    }
}

/// Where the newest waterfall row sits; changes only on a pan or zoom.
@MainActor
public final class LocalSDRWaterfallPosition: ObservableObject {
    @Published public private(set) var current: LocalSDRModel.WaterfallView?

    public func set(_ value: LocalSDRModel.WaterfallView?) {
        if current != value { current = value }
    }
}

/// A `width`×`height` RGBA picture, newest row at the top, that can also
/// move sideways. Per row: one `memmove` down plus one 256-entry table
/// lookup per pixel (the same costs as `WaterfallBitmap`, which the main
/// scope keeps for its Float rows); a pan is one short `memmove` per row.
/// Unchecked pointer loops only, so the Debug build Xcode runs stays cheap.
public final class PannableWaterfallBitmap {
    public let width: Int
    public let height: Int
    private let blank = WaterfallPalette.lut[0]
    private var pixels: [UInt32]
    private var scratch: [UInt32]
    /// The main screen's own space, so Core Animation draws the picture
    /// without a colour-matching pass per frame (measured in a Debug build:
    /// that pass was most of the waterfall's cost). The palette's values
    /// are then the screen's: a touch more saturated on a P3 display.
    #if os(macOS)
    private let colorSpace = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
    #else
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    #endif

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: WaterfallPalette.lut[0], count: width * height)
        scratch = [UInt32](repeating: 0, count: width)
    }

    /// Adds `bins` (one byte each, `width` of them) as the newest row.
    public func append(_ bins: Data, colors: [UInt32]) {
        let width = width
        let shifted = width * (height - 1)
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memmove(base + width, base, shifted * MemoryLayout<UInt32>.size)
            colors.withUnsafeBufferPointer { table in
                guard let lut = table.baseAddress else { return }
                bins.withUnsafeBytes { raw in
                    guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    var column = 0
                    while column < width {
                        base[column] = lut[Int(bytes[column])]
                        column += 1
                    }
                }
            }
        }
    }

    /// Moves every row `bins` columns left (positive: the view moved up in
    /// frequency) or right, blanking what comes into view.
    public func shift(bins: Int) {
        guard bins != 0 else { return }
        let width = width, height = height, blank = blank
        let distance = min(abs(bins), width)
        let kept = width - distance
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var row = 0
            while row < height {
                let line = base + row * width
                if kept > 0 {
                    if bins > 0 {
                        memmove(line, line + distance, kept * MemoryLayout<UInt32>.size)
                    } else {
                        memmove(line + distance, line, kept * MemoryLayout<UInt32>.size)
                    }
                }
                let exposed = bins > 0 ? line + kept : line
                var column = 0
                while column < distance {
                    exposed[column] = blank
                    column += 1
                }
                row += 1
            }
        }
    }

    /// Rebuilds every row through `map` (new column → old column, −1 =
    /// blank), for a zoom change.
    public func remap(_ map: [Int32]) {
        guard map.count == width else { return clear() }
        let width = width, height = height, blank = blank
        pixels.withUnsafeMutableBufferPointer { buffer in
            scratch.withUnsafeMutableBufferPointer { temp in
                map.withUnsafeBufferPointer { columns in
                    guard let base = buffer.baseAddress, let out = temp.baseAddress,
                          let source = columns.baseAddress else { return }
                    var row = 0
                    while row < height {
                        let line = base + row * width
                        var column = 0
                        while column < width {
                            let from = Int(source[column])
                            out[column] = from >= 0 ? line[from] : blank
                            column += 1
                        }
                        memcpy(line, out, width * MemoryLayout<UInt32>.size)
                        row += 1
                    }
                }
            }
        }
    }

    public func clear() {
        let blank = blank
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<buffer.count { base[i] = blank }
        }
    }

    /// A copy (the buffer changes again next row while this is on screen).
    public func makeImage() -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       // Opaque (the palette's alpha is always 255): spares
                       // Core Animation a premultiply pass per frame.
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

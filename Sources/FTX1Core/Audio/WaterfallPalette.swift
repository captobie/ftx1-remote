import Foundation

/// Fixed intensity -> color gradient (black, low signal, through blue/
/// cyan/green/yellow to red, strong signal) — literal RGB stops, matching
/// `SMeterView`'s convention of hardcoded colors rather than asset-catalog
/// or semantic ones. Consumers go through `lut`/`index(forIntensity:)`, a
/// 256-step quantization of the gradient built once; `color(forIntensity:)`
/// is the exact definition that table is built from (see the Mac's
/// `WaterfallBitmap` for why the per-pixel path no longer calls it
/// directly). Shared since the iPad's MyKiwiSDR pane uses it too.
public enum WaterfallPalette {
    /// 256 packed RGBA8888 pixels (R in the lowest byte, alpha 255), entry
    /// `i` being the gradient color at intensity `i / 255`.
    public static let lut: [UInt32] = (0..<256).map { step in
        let color = color(forIntensity: Float(step) / 255)
        return UInt32(color.r) | UInt32(color.g) << 8 | UInt32(color.b) << 16 | 0xFF00_0000
    }

    /// Clamps to 0...1 (so a NaN or out-of-range intensity can't index out
    /// of bounds) and rounds to the nearest of `lut`'s 256 steps.
    public static func index(forIntensity value: Float) -> Int {
        let clamped = max(0, min(1, value))
        return Int(clamped * 255 + 0.5)
    }

    private static let stops: [(threshold: Float, r: UInt8, g: UInt8, b: UInt8)] = [
        (0.00, 0, 0, 0),
        (0.25, 0, 0, 180),
        (0.50, 0, 180, 180),
        (0.75, 0, 220, 0),
        (0.90, 255, 220, 0),
        (1.00, 255, 40, 0),
    ]

    public static func color(forIntensity value: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        let clamped = max(0, min(1, value))
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for (a, b) in zip(stops, stops.dropFirst()) where clamped <= b.threshold {
            lower = a
            upper = b
            break
        }
        let span = upper.threshold - lower.threshold
        let t = span > 0 ? (clamped - lower.threshold) / span : 0
        func lerp(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(Float(a) + (Float(b) - Float(a)) * t)
        }
        return (lerp(lower.r, upper.r), lerp(lower.g, upper.g), lerp(lower.b, upper.b))
    }
}

import Foundation

/// A KiwiSDR passband: `low_cut`/`high_cut` in Hz relative to the carrier
/// (negative below it), as sent in "SET mod=… low_cut=… high_cut=… freq=…".
/// The rules for moving its edges are pure so they can be unit-tested; the
/// Local SDR window's waterfall calls them with where the mouse is.
///
/// Limits: the Kiwi's page allows ±(sample rate / 2) and a 4 Hz minimum,
/// and the server clamps to rate/2 − 1 (`rx_sound_cmd.cpp`, v1.902). Here
/// USB stays above the carrier and LSB below it, AM and FM keep the carrier
/// inside the passband, and the width stays at least `minimumWidthHz` (the
/// Kiwi's own narrowest CW preset).
///
/// CW is symmetric around the dial: the dial is the signal, which sits at
/// the passband's centre (`KiwiSDRMode.carrierHz`), so dragging one edge
/// moves both. The centre stays at the Kiwi's 500 Hz audio pitch until
/// half the width no longer fits below it, then rises so the passband
/// never crosses the carrier.
public struct KiwiPassband: Equatable, Sendable {
    public var low: Int
    public var high: Int

    public static let snapHz = 10
    public static let minimumWidthHz = 60
    public static let limitHz = 6000
    public static let cwPitchHz = 500

    public init(low: Int, high: Int) {
        self.low = low
        self.high = high
    }

    public init(defaultFor mode: KiwiSDRMode) {
        let band = mode.defaultPassband
        self.init(low: band.low, high: band.high)
    }

    public var width: Int { high - low }

    public enum Edge: Sendable {
        case low, high
    }

    /// Where each edge may go in `mode`, before the minimum width.
    private static func edgeRanges(_ mode: KiwiSDRMode) -> (low: ClosedRange<Int>, high: ClosedRange<Int>) {
        let halfMinimum = minimumWidthHz / 2
        switch mode {
        case .usb, .cw:
            return (0...(limitHz - minimumWidthHz), minimumWidthHz...limitHz)
        case .lsb:
            return (-limitHz...(-minimumWidthHz), (minimumWidthHz - limitHz)...0)
        case .am, .fm:
            return (-limitHz...(-halfMinimum), halfMinimum...limitHz)
        }
    }

    /// Whether this passband can be used in `mode` as it stands (a saved
    /// value is checked with this before being trusted).
    public func isValid(for mode: KiwiSDRMode) -> Bool {
        let ranges = Self.edgeRanges(mode)
        return ranges.low.contains(low) && ranges.high.contains(high) && width >= Self.minimumWidthHz
    }

    /// The passband after dragging `edge` to `offsetHz` from the dial,
    /// snapped to `snapHz`.
    public func dragging(_ edge: Edge, toOffsetHz offsetHz: Double, mode: KiwiSDRMode) -> KiwiPassband {
        let snapped = Int((offsetHz / Double(Self.snapHz)).rounded()) * Self.snapHz
        if mode == .cw {
            return .cw(halfWidth: edge == .low ? -snapped : snapped)
        }
        let ranges = Self.edgeRanges(mode)
        var result = self
        switch edge {
        case .low:
            result.low = min(max(snapped, ranges.low.lowerBound), min(ranges.low.upperBound, high - Self.minimumWidthHz))
        case .high:
            result.high = max(min(snapped, ranges.high.upperBound), max(ranges.high.lowerBound, low + Self.minimumWidthHz))
        }
        return result
    }

    /// A CW passband `halfWidth` either side of the signal (clamped to
    /// what fits).
    static func cw(halfWidth: Int) -> KiwiPassband {
        let half = min(max(halfWidth, minimumWidthHz / 2), limitHz / 2)
        let low = max(cwPitchHz - half, 0)
        return KiwiPassband(low: low, high: low + 2 * half)
    }

    /// "300–2700 Hz": LSB as positive audio offsets, AM/FM with signs.
    /// Unit-only, so not localized.
    public func rangeText(mode: KiwiSDRMode) -> String {
        switch mode {
        case .usb, .cw: "\(low)–\(high) Hz"
        case .lsb: "\(-high)–\(-low) Hz"
        case .am, .fm: "\(Self.signed(low))…\(Self.signed(high)) Hz"
        }
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}

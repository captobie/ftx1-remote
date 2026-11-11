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
    /// CW only, and only from the rig (`init?(rigFilterOf:)`): how far the
    /// passband's centre sits above the dial, the rig's IF SHIFT. Dragging
    /// clears it.
    public var cwShiftHz = 0

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

    /// The Kiwi passband matching MAIN's receive filter (see
    /// `FilterPassbandModel` for where width and SHIFT come from). nil
    /// when the filter fields hold SUB's values, the rig's mode has no Kiwi
    /// equivalent, or the width isn't known (not read yet, or the rig's
    /// "default" index 0). Not snapped: these are the rig's own values.
    ///
    /// SSB/DATA: the audio passband the rig's display model gives, mirrored
    /// below the carrier for LSB, kept on its sideband. CW: the width around
    /// the Kiwi's own pitch, moved by SHIFT with the dial still on the
    /// signal (the rig's KP pitch doesn't apply here). AM/FM: symmetric, as
    /// wide as the Kiwi can go (the rig's 16 kHz FM doesn't fit in its
    /// ±6 kHz); SHIFT doesn't apply.
    public init?(rigFilterOf state: RigState) {
        guard state.activeFilterSide == .main,
              let mode = KiwiSDRMode(rigMode: state.filterMode),
              let width = FilterPassbandModel.widthHz(state: state).effective, width > 0 else { return nil }
        let shift = FilterPassbandModel.shiftHz(state: state)
        switch mode {
        case .am, .fm:
            let half = min(width / 2, Self.limitHz)
            self.init(low: -half, high: half)
        case .cw:
            let half = min(width / 2, Self.limitHz / 2)
            let low = max(max(Self.cwPitchHz - half, 0) + shift, 0)
            self.init(low: low, high: min(low + 2 * half, Self.limitHz))
            cwShiftHz = shift
        case .usb, .lsb:
            let centre = Int(FilterPassbandModel.defaultCenterHz(for: state.filterMode, pitch: 0)) + shift
            let low = max(centre - width / 2, 0)
            let high = min(max(centre - width / 2 + width, low + 1), Self.limitHz)
            if mode == .usb {
                self.init(low: low, high: high)
            } else {
                self.init(low: -high, high: -low)
            }
        }
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

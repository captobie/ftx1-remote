import Foundation

/// Where a waterfall row goes relative to the picture already drawn: the
/// pure half of the Local SDR window's waterfall store (the pixels live in
/// the Mac target). Every row is placed by its own header — rows in flight
/// after a pan or zoom still carry the old position.
public enum KiwiWaterfallPlacement: Equatable, Sendable {
    /// Same position as the picture: just add the row.
    case append
    /// Same zoom, moved: shift the existing rows by this many bins first
    /// (positive = the view moved up in frequency, so history moves left),
    /// leaving the exposed edge blank.
    case shift(bins: Int)
    /// Different zoom: rebuild the history from `KiwiWaterfallPlacement.
    /// columnMap(…)`, or clear it.
    case rezoom

    /// How to place a row at `row` on a picture anchored at `anchor` (nil
    /// = empty picture, which appends).
    public static func place(row: (xBin: Int, zoom: Int), anchor: (xBin: Int, zoom: Int)?,
                             geometry: KiwiWaterfallGeometry) -> KiwiWaterfallPlacement {
        guard let anchor else { return .append }
        guard let bins = geometry.binsToShift(from: anchor, to: row) else { return .rezoom }
        return bins == 0 ? .append : .shift(bins: bins)
    }

    /// For each column of a row at `to`, the column of a row at `from`
    /// showing the same frequency (the one under the new column's centre),
    /// or −1 where `from` didn't cover it. Used to rescale the history on a
    /// zoom change: zooming in stretches each old bin over 2^dz columns,
    /// zooming out squeezes 2^dz old bins into one (the one at its centre)
    /// and leaves the newly covered sides blank.
    public static func columnMap(from: (xBin: Int, zoom: Int), to: (xBin: Int, zoom: Int),
                                 geometry: KiwiWaterfallGeometry) -> [Int32] {
        let count = geometry.fftSize
        let fromUnit = Double(geometry.unitsPerBin(zoom: from.zoom))
        let toUnit = Double(geometry.unitsPerBin(zoom: to.zoom))
        return (0..<count).map { column in
            let units = Double(to.xBin) + (Double(column) + 0.5) * toUnit
            let source = ((units - Double(from.xBin)) / fromUnit).rounded(.down)
            return source >= 0 && source < Double(count) ? Int32(source) : -1
        }
    }
}

extension KiwiWaterfallGeometry {
    /// A new left edge that keeps the passband [lowHz, highHz] visible at
    /// least `marginFraction` of the span from either edge, or nil if it
    /// already is (tuning inside the span never moves the waterfall).
    /// Moves just far enough when the passband is near or slightly past an
    /// edge, so stepping across the edge pans smoothly; centres on it when
    /// it's far away or wider than the span allows.
    public func startKeeping(lowHz: Double, highHz: Double, start: Int, zoom: Int,
                             marginFraction: Double = 0.1) -> Int? {
        let spanUnits = Double(spanUnits(zoom: zoom))
        let margin = spanUnits * marginFraction
        let low = xBin(hz: lowHz), high = xBin(hz: highHz)
        let left = Double(start), right = Double(start) + spanUnits
        if low >= left + margin, high <= right - margin { return nil }

        let proposed: Double
        let farAway = high < left - spanUnits / 2 || low > right + spanUnits / 2
        if farAway || high - low > spanUnits - 2 * margin {
            proposed = (low + high) / 2 - spanUnits / 2
        } else if low < left + margin {
            proposed = low - margin
        } else {
            proposed = high + margin - spanUnits
        }
        let clamped = clampStart(Int(proposed.rounded()), zoom: zoom)
        return clamped == start ? nil : clamped
    }
}

/// The waterfall's colour range from recent rows, modelled on the Kiwi
/// page's autoscale (`waterfall_add`: median − 10 dB to 95th percentile +
/// 30 dB, masked bins ≤ −190 dBm left out) but tightened at the bottom for
/// this app's palette, whose dark end is short: floor = median − 5 dB,
/// ceiling = 95th percentile + 25 dB and at least 40 dB above the floor.
/// With the Kiwi's −10 the noise came out bright blue on 40 m and weak
/// signals barely stood out (tried live, 2026-11-10). Measured every few rows from a 256-bucket histogram (no sorting)
/// and smoothed, so a burst doesn't flash the picture.
public struct KiwiWaterfallAutoRange: Sendable {
    public private(set) var floorDBm: Double = -120
    public private(set) var ceilingDBm: Double = -80
    /// Whether a measurement has been taken yet.
    public private(set) var isSettled = false

    private let rowsPerMeasurement: Int
    private let smoothing: Double
    private var rowsSinceMeasurement = 0

    /// `smoothing` is how far each measurement moves the range (1 = jump).
    public init(rowsPerMeasurement: Int = 5, smoothing: Double = 0.2) {
        self.rowsPerMeasurement = max(1, rowsPerMeasurement)
        self.smoothing = smoothing
    }

    /// Feeds one row; returns true when the range changed by ≥ 0.5 dB
    /// (time to rebuild a colour table).
    public mutating func add(_ bins: Data, cal: Int) -> Bool {
        rowsSinceMeasurement += 1
        guard !isSettled || rowsSinceMeasurement >= rowsPerMeasurement else { return false }
        rowsSinceMeasurement = 0
        guard let measured = Self.measure(bins, cal: cal) else { return false }
        let oldFloor = floorDBm, oldCeiling = ceilingDBm
        if isSettled {
            floorDBm += (measured.floor - floorDBm) * smoothing
            ceilingDBm += (measured.ceiling - ceilingDBm) * smoothing
        } else {
            floorDBm = measured.floor
            ceilingDBm = measured.ceiling
            isSettled = true
            return true
        }
        return abs(floorDBm - oldFloor) >= 0.5 || abs(ceilingDBm - oldCeiling) >= 0.5
    }

    public mutating func reset() {
        isSettled = false
        rowsSinceMeasurement = 0
    }

    /// One row's floor and ceiling, nil if every bin is masked.
    static func measure(_ bins: Data, cal: Int) -> (floor: Double, ceiling: Double)? {
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        // dBm = byte − 255 + cal ≤ −190 ⇔ byte ≤ 65 − cal.
        let masked = 65 - cal
        for byte in bins where Int(byte) > masked {
            histogram[Int(byte)] += 1
            total += 1
        }
        guard total > 0 else { return nil }
        func percentile(_ fraction: Double) -> Int {
            let target = Int(fraction * Double(total))
            var seen = 0
            for (byte, count) in histogram.enumerated() {
                seen += count
                if seen > target { return byte }
            }
            return 255
        }
        let noise = Double(KiwiWaterfallFrame.dBm(UInt8(percentile(0.5)), cal: cal))
        let signal = Double(KiwiWaterfallFrame.dBm(UInt8(percentile(0.95)), cal: cal))
        let floor = noise - 5
        let ceiling = max(signal + 25, floor + 40)
        return (floor, ceiling)
    }

    /// For each wire byte, the 0…255 palette step: the floor maps to 0,
    /// the ceiling to 255, clamped.
    public func paletteSteps(cal: Int) -> [UInt8] {
        let range = max(ceilingDBm - floorDBm, 1)
        return (0..<256).map { byte in
            let dBm = Double(KiwiWaterfallFrame.dBm(UInt8(byte), cal: cal))
            let t = (dBm - floorDBm) / range
            return UInt8(max(0, min(255, (t * 255).rounded())))
        }
    }
}

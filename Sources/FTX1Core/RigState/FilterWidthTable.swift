import Foundation

/// Transcription of the FTX-1 CAT manual's Table 5 (Bandwidth Chart): what
/// each raw "SH" WIDTH index (`RigState.filterWidthIndex`, 0-23) means in
/// Hz for a given operating mode. The same index reads as a *different*
/// bandwidth depending on the mode the rig is in — e.g. index 17 is 2700 Hz
/// in SSB but 2400 Hz in CW/DATA/RTTY — and only a handful of indices are
/// valid at all in AM/FM, so every lookup here is keyed by `RigMode`.
///
/// Shared (not Mac-only) for the same reason as `BandPlan`: the mapping is
/// platform-agnostic, and any client rendering `filterWidthIndex` needs it.
public enum FilterWidthTable {
    /// One row of a mode's column: the raw "SH" P3 index and its bandwidth.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let index: Int
        public let hz: Int
        public var id: Int { index }
    }

    /// The manual's LSB/USB column, indices 01-23.
    private static let ssbHz = [
        300, 400, 600, 850, 1100, 1200, 1500, 1650, 1800, 1950, 2100, 2250,
        2400, 2450, 2500, 2600, 2700, 2800, 2900, 3000, 3200, 3500, 4000,
    ]

    /// The manual's CW-L/CW-U / DATA-L/DATA-U / RTTY-L/RTTY-U / PSK column,
    /// indices 01-21.
    private static let cwDataHz = [
        50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 600, 800, 1200,
        1400, 1700, 2000, 2400, 3000, 3200, 3500, 4000,
    ]

    private static let ssbEntries = ssbHz.enumerated().map { Entry(index: $0.offset + 1, hz: $0.element) }
    private static let cwDataEntries = cwDataHz.enumerated().map { Entry(index: $0.offset + 1, hz: $0.element) }

    /// AM has two fixed widths, one per NARROW state: index 01 is AM-N's
    /// 6000 Hz, index 02 the plain AM 9000 Hz. Not user-adjustable here —
    /// the rig switches between them with its NARROW function, which this
    /// app doesn't wire yet — but readable so the current one can be shown.
    private static let amEntries = [Entry(index: 1, hz: 6000), Entry(index: 2, hz: 9000)]

    /// FM / DATA-FM likewise: index 02 is FM-N/DATA-FM-N's 9000 Hz, index
    /// 03 the plain 16000 Hz.
    private static let fmEntries = [Entry(index: 2, hz: 9000), Entry(index: 3, hz: 16000)]

    /// Every valid `(index, hz)` row for `mode`, ascending by index. Empty
    /// for modes the chart has no column for (C4FM, unknown).
    public static func entries(for mode: RigMode) -> [Entry] {
        switch mode {
        case .usb, .lsb: ssbEntries
        case .cw, .rtty, .dataUSB: cwDataEntries
        case .am: amEntries
        case .fm, .dataFM: fmEntries
        case .c4fm, .unknown: []
        }
    }

    /// Whether the operator can pick among several widths in `mode`. AM/FM
    /// are fixed-width (see `amEntries`/`fmEntries`), and C4FM/unknown have
    /// no width at all.
    public static func isAdjustable(mode: RigMode) -> Bool {
        switch mode {
        case .usb, .lsb, .cw, .rtty, .dataUSB: true
        case .am, .fm, .dataFM, .c4fm, .unknown: false
        }
    }

    public static func hz(forIndex index: Int, mode: RigMode) -> Int? {
        entries(for: mode).first { $0.index == index }?.hz
    }

    /// Display label for an index in `mode`: "2400 Hz" for a charted row,
    /// "Default" for index 0 (the manual's "default bandwidth for the
    /// selected mode" placeholder), and "—" for anything else — typically
    /// the window right after a mode change, when `filterWidthIndex` still
    /// holds the previous mode's index until the next slow-tier poll
    /// re-reads it.
    public static func label(forIndex index: Int?, mode: RigMode) -> String {
        guard let index else { return "—" }
        if index == 0 { return "Default" }
        guard let hz = hz(forIndex: index, mode: mode) else { return "—" }
        return "\(hz) Hz"
    }

    /// The next row narrower (or wider) than `index` in `mode`'s column, or
    /// nil at that end of the column, or when `index` isn't in it. Walks
    /// the entry list rather than doing raw ±1 since the AM/FM columns
    /// have gaps in their index numbering.
    public static func neighborIndex(of index: Int, mode: RigMode, narrower: Bool) -> Int? {
        let rows = entries(for: mode)
        guard let position = rows.firstIndex(where: { $0.index == index }) else { return nil }
        let target = narrower ? position - 1 : position + 1
        guard rows.indices.contains(target) else { return nil }
        return rows[target].index
    }
}

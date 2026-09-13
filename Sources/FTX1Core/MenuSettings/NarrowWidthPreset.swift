import Foundation

/// The per-mode NAR WIDTH menu preset — the bandwidth the rig actually
/// uses while NARROW ("N/W") is on in SSB/CW/RTTY/DATA. Hardware-observed
/// 2026-09-13: in those modes the raw "SH" WIDTH index does *not* change
/// when NARROW is switched on (it keeps reporting the wide setting), so a
/// display that wants to show the narrowed passband has to read this
/// Deep Settings item instead. AM/FM have no preset (their narrow widths
/// are the fixed second row of `FilterWidthTable`, and "SH" does follow
/// NARROW there).
///
/// Addresses and value lists come straight from `DeepSettingsCatalog`'s
/// "NAR WIDTH" items (RADIO SETTING → MODE SSB/DATA/RTTY, CW SETTING →
/// MODE CW), looked up by tab so there's a single source of truth for the
/// EX addressing.
public enum NarrowWidthPreset {
    /// The catalog item holding `mode`'s NAR WIDTH, nil for modes without one.
    public static func item(for mode: RigMode) -> DeepSettingItem? {
        let tab: String
        switch mode {
        case .usb, .lsb: tab = "MODE SSB"
        case .dataUSB: tab = "MODE DATA"
        case .rtty: tab = "MODE RTTY"
        case .cw: tab = "MODE CW"
        case .am, .fm, .dataFM, .c4fm, .unknown: return nil
        }
        return DeepSettingsCatalog.items.first { $0.label == "NAR WIDTH" && $0.tab == tab }
    }

    /// Hz for the raw P4 the "EX" read returns (a zero-padded index into
    /// the item's enumeration, e.g. "10"), nil if it isn't a listed case.
    public static func hz(forRawValue raw: String, mode: RigMode) -> Int? {
        guard let item = item(for: mode), let index = Int(raw),
              case .enumeration(let cases, _) = item.valueType,
              let match = cases.first(where: { $0.index == index }) else { return nil }
        // Labels are "1800 Hz"; take the leading number.
        return Int(match.label.split(separator: " ").first ?? "")
    }
}

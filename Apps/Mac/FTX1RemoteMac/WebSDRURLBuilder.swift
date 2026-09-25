import FTX1Core
import Foundation

/// URL and mode logic for classic WebSDRs (PA3FWM's software), the
/// counterpart of `KiwiSDRURLBuilder`.
///
/// Checked 2026-09-25 against a live server's own `websdr-base.js`
/// (websdr.ewi.utwente.nl:8901): the page reads `?tune=<kHz><mode>` in
/// `bodyonload` and hands it to `setfreqtune()` — the same function its
/// `postMessage("tune …")` interface uses, and the one
/// `SDRPageBridge.retuneInPlace` calls for every later retune (no reload).
/// The mode suffix goes through the page's `set_mode()`, case-insensitive
/// (USB, LSB, CW, AM, FM, plus narrow/sync variants); a frequency outside
/// every band the server has is silently ignored by the page.
nonisolated enum WebSDRURLBuilder {
    /// The page's `set_mode()` names, lowercased. nil = frequency only.
    static func modeToken(for mode: RigMode) -> String? {
        switch mode {
        case .usb, .dataUSB: "usb"
        case .lsb: "lsb"
        case .cw: "cw"
        case .am: "am"
        case .fm: "fm"
        case .rtty, .dataFM, .c4fm, .unknown: nil
        }
    }

    /// The page's `mode` global ("USB", "LSB", "CW", "AM", "AMSYNC", "FM")
    /// folded to a `modeToken(for:)` value.
    static func modeFamily(ofWebSDRMode webSDRMode: String) -> String? {
        switch webSDRMode.lowercased() {
        case "usb", "usbn": "usb"
        case "lsb", "lsbn": "lsb"
        case "cw", "cwn": "cw"
        case "am", "amn", "amsync": "am"
        case "fm", "fmn": "fm"
        default: nil
        }
    }

    /// What `?tune=` and `setfreqtune()` take: "7074.00usb", or "7074.00".
    static func tuneValue(frequencyHz: Int, modeToken token: String?) -> String {
        KiwiSDRURLBuilder.kHzString(frequencyHz) + (token ?? "")
    }

    /// `bands` nil (not known until the page has loaded once) skips the
    /// range check — the page just ignores a frequency it doesn't cover.
    static func retune(hostPort: String, frequencyHz: Int, mode: RigMode,
                       bands: [ClosedRange<Int>]?) -> KiwiSDRURLBuilder.Result {
        if hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noHost }
        guard let base = KiwiSDRURLBuilder.baseURL(from: hostPort) else { return .invalidHost }
        guard frequencyHz > 0 else { return .noFrequency }
        if let bands, !bands.contains(where: { $0.contains(frequencyHz) }) {
            return .outOfRange(frequencyHz: frequencyHz, bands: bands)
        }

        let token = modeToken(for: mode)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "tune", value: tuneValue(frequencyHz: frequencyHz, modeToken: token))]
        return .tune(components.url!, frequencyHz: frequencyHz, modeToken: token)
    }
}

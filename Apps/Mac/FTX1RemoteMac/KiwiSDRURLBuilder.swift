import FTX1Core
import Foundation

/// Pure URL logic behind the WebSDR window (`WebSDRFollowModel`): turns a
/// rig frequency/mode into a KiwiSDR retune URL, or a reason not to.
///
/// URL shape verified 2026-09-24 against a live KiwiSDR (firmware v1.578)
/// by reading its own `kiwisdr.min.js`, not old blog posts:
/// `/?f=<kHz><mode>[z<zoom>]` — the same shape the Kiwi's own "copy
/// frequency link" icon builds, parsed back by its
/// `parse_freq_pb_mode_zoom()`. Omitting the mode token makes the Kiwi fall
/// back to its stored `last_mode` (hardware-checked: `?f=7040.00` after a
/// `usb` session stayed `usb`), which is how an unmapped rig mode leaves
/// the Kiwi's mode unchanged. Zoom is deliberately never sent, so a zoom
/// the user set by hand in the Kiwi page survives retunes the same way.
enum KiwiSDRURLBuilder {
    /// KiwiSDR's receive range. Hard-coded for v1 — v1.1: read the actual
    /// range from the Kiwi's own `/status` endpoint, since some variants
    /// extend slightly past 30 MHz.
    static let maxFrequencyHz = 30_000_000

    enum Result: Equatable {
        case tune(URL, frequencyHz: Int, modeToken: String?)
        case noHost
        case invalidHost
        case noFrequency
        case outOfRange(frequencyHz: Int)
    }

    /// The KiwiSDR mode token for a rig mode, or nil to retune frequency
    /// only. Tokens are from the Kiwi's own `kiwi.modes_lc` list.
    static func modeToken(for mode: RigMode) -> String? {
        switch mode {
        case .usb: "usb"
        // DATA-U is plain USB demodulation on the rig, so USB on the Kiwi
        // makes FT8 etc. audible there too.
        case .dataUSB: "usb"
        case .lsb: "lsb"
        case .cw: "cw"
        case .am: "am"
        case .fm: "nbfm"
        // No sensible Kiwi equivalent (RTTY's mark/space sideband is
        // ambiguous; DATA-FM/C4FM are digital) — frequency only.
        case .rtty, .dataFM, .c4fm, .unknown: nil
        }
    }

    /// Normalizes what the user typed ("host:port", "http://host:port/",
    /// with or without a trailing path) to the Kiwi's root URL. Defaults to
    /// http — Kiwis serve plain http (the Mac target's ATS exception
    /// already allows it).
    static func baseURL(from hostPort: String) -> URL? {
        let trimmed = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty,
              components.scheme == "http" || components.scheme == "https"
        else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func retune(hostPort: String, frequencyHz: Int, mode: RigMode) -> Result {
        if hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noHost }
        guard let base = baseURL(from: hostPort) else { return .invalidHost }
        guard frequencyHz > 0 else { return .noFrequency }
        guard frequencyHz <= maxFrequencyHz else { return .outOfRange(frequencyHz: frequencyHz) }

        let token = modeToken(for: mode)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "f", value: kHzString(frequencyHz) + (token ?? ""))]
        return .tune(components.url!, frequencyHz: frequencyHz, modeToken: token)
    }

    /// Two decimals (10 Hz resolution), matching the Kiwi's own link format.
    static func kHzString(_ hz: Int) -> String {
        String(format: "%.2f", Double(hz) / 1000)
    }
}

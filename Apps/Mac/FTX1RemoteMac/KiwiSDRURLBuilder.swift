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
nonisolated enum KiwiSDRURLBuilder {
    /// KiwiSDR's standard receive range — the fallback for a host typed in
    /// by hand. A station picked from the directory brings its own ranges
    /// (`KiwiSDRStation.bands`), which can be wider (0–32 MHz) or entirely
    /// elsewhere (converter-fed Kiwis).
    static let maxFrequencyHz = 30_000_000
    static let defaultBands = [0...maxFrequencyHz]

    enum Result: Equatable {
        case tune(URL, frequencyHz: Int, modeToken: String?)
        case noHost
        case invalidHost
        case noFrequency
        case outOfRange(frequencyHz: Int, bands: [ClosedRange<Int>])
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

    /// The Kiwi mode as the token `modeToken(for:)` would send for it —
    /// folding the Kiwi's variants (narrow/wide/synchronous AM, narrow
    /// sideband, narrow FM) into the family the rig can match. nil for
    /// modes with no rig equivalent (IQ, DRM).
    static func modeFamily(ofKiwiMode kiwiMode: String) -> String? {
        switch kiwiMode.lowercased() {
        case "usb", "usn": "usb"
        case "lsb", "lsn": "lsb"
        case "cw", "cwn": "cw"
        case "am", "amn", "amw", "sam", "sau", "sal", "sas", "qam": "am"
        case "nbfm", "nnfm": "nbfm"
        default: nil
        }
    }

    /// The rig mode for a Kiwi mode, for click-to-tune, or nil to leave the
    /// rig's mode alone: when the Kiwi mode has no rig equivalent, when it's
    /// already what the rig's mode maps to (so DATA-U stays DATA-U under a
    /// Kiwi in USB), and when the rig's mode has no Kiwi equivalent (RTTY,
    /// DATA-FM, C4FM — following never set the Kiwi's mode from those, so
    /// its mode isn't a statement about what the rig should be in).
    static func rigMode(forKiwiMode kiwiMode: String, current: RigMode) -> RigMode? {
        guard let family = modeFamily(ofKiwiMode: kiwiMode),
              let currentToken = modeToken(for: current),
              family != currentToken
        else { return nil }
        switch family {
        case "usb": return .usb
        case "lsb": return .lsb
        case "cw": return .cw
        case "am": return .am
        case "nbfm": return .fm
        default: return nil
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

    static func retune(hostPort: String, frequencyHz: Int, mode: RigMode,
                       bands: [ClosedRange<Int>] = defaultBands) -> Result {
        if hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noHost }
        guard let base = baseURL(from: hostPort) else { return .invalidHost }
        guard frequencyHz > 0 else { return .noFrequency }
        guard bands.contains(where: { $0.contains(frequencyHz) }) else {
            return .outOfRange(frequencyHz: frequencyHz, bands: bands)
        }

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

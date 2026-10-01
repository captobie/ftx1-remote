import FTX1Core
import Foundation

/// URL and mode logic for OpenWebRX receivers, the counterpart of
/// `KiwiSDRURLBuilder`/`WebSDRURLBuilder`.
///
/// Checked 2026-10-01 against a live v1.2.2 server's own `receiver.js`
/// (the operator's RTL-SDR on a Pi, `jketterl/openwebrx:stable`):
/// - The page reads `#freq=<Hz>,mod=<modulation>` from its URL hash
///   (`DemodulatorPanel.parseHash`), but only applies it when the
///   frequency is inside the profile the SDR is *currently* on
///   (`validateHash`: within ±samp_rate/2 of `center_freq`). The profile is
///   shared server-side state, so a first load can land on any profile;
///   `WebSDRFollowModel.pageDidLoad` therefore always follows up with an
///   in-place retune (`SDRPageBridge.retuneInPlace`), which switches the
///   profile when needed.
/// - Every later retune is in place too, never a reload. The URL built
///   here is the retune's identity (`WebSDRFollowModel` dedups on it) and a
///   shareable link; the page itself is always loaded without the hash.
/// - Modulation names are the page's `Modes` list ("usb", "lsb", "cw",
///   "am", "nfm", "wfm", plus digital voice and `DIG` digimodes, which
///   report their underlying modulation).
nonisolated enum OpenWebRXURLBuilder {
    /// The page's modulation for a rig mode. nil = frequency only.
    static func modeToken(for mode: RigMode) -> String? {
        switch mode {
        case .usb, .dataUSB: "usb"
        case .lsb: "lsb"
        case .cw: "cw"
        case .am: "am"
        case .fm: "nfm"
        // C4FM has an OpenWebRX equivalent ("ysf"), but only with the
        // optional digiham decoder installed; frequency only, like the other
        // platforms, rather than a mode the page may refuse.
        case .rtty, .dataFM, .c4fm, .unknown: nil
        }
    }

    /// The page's current modulation folded to a `modeToken(for:)` value;
    /// nil when the rig has no equivalent (WFM, digital voice, DRM).
    static func modeFamily(ofOpenWebRXMode mode: String) -> String? {
        switch mode.lowercased() {
        case "usb": "usb"
        case "lsb": "lsb"
        case "cw": "cw"
        case "am": "am"
        case "nfm": "nfm"
        default: nil
        }
    }

    /// `bands` nil (not known until the page has loaded once) skips the
    /// range check — a retune outside every profile then just doesn't move
    /// the page.
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
        components.fragment = "freq=\(frequencyHz)" + (token.map { ",mod=\($0)" } ?? "")
        return .tune(components.url!, frequencyHz: frequencyHz, modeToken: token)
    }
}

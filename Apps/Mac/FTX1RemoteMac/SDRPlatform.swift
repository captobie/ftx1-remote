import FTX1Core
import Foundation

/// Which receiver software a WebSDR-window host runs: a KiwiSDR, or a
/// classic WebSDR (PA3FWM's software, the servers listed on websdr.org).
/// The two differ in how they're tuned (`?f=` + page reload vs. `?tune=` +
/// the page's own `setfreqtune()` in place), in their mode names, and in
/// the page functions `SDRPageBridge` calls.
///
/// Stored per station (`WebSDRFavorite.platform`). A host typed by hand has
/// no platform until its page has loaded once — it's loaded as a Kiwi
/// (`?f=`, which a WebSDR ignores), and `SDRPageBridge.detectPlatform()`
/// then records what it actually is.
nonisolated enum SDRPlatform: String, Codable, Sendable, CaseIterable {
    case kiwiSDR
    case webSDR

    var displayName: String {
        switch self {
        case .kiwiSDR: "KiwiSDR"
        case .webSDR: "WebSDR"
        }
    }

    /// The page's mode token for a rig mode, or nil to tune frequency only.
    func modeToken(for mode: RigMode) -> String? {
        switch self {
        case .kiwiSDR: KiwiSDRURLBuilder.modeToken(for: mode)
        case .webSDR: WebSDRURLBuilder.modeToken(for: mode)
        }
    }

    /// A mode as the page reports it, folded to the token `modeToken(for:)`
    /// would send for it; nil when the rig has no equivalent.
    func modeFamily(ofPageMode pageMode: String) -> String? {
        switch self {
        case .kiwiSDR: KiwiSDRURLBuilder.modeFamily(ofKiwiMode: pageMode)
        case .webSDR: WebSDRURLBuilder.modeFamily(ofWebSDRMode: pageMode)
        }
    }

    /// The rig mode for a page mode, for click-to-tune, or nil to leave the
    /// rig's mode alone: when the page mode has no rig equivalent, when it's
    /// already what the rig's mode maps to (so DATA-U stays DATA-U under a
    /// page in USB), and when the rig's mode has no page equivalent (RTTY,
    /// DATA-FM, C4FM — following never set the page's mode from those, so
    /// its mode isn't a statement about what the rig should be in).
    func rigMode(forPageMode pageMode: String, current: RigMode) -> RigMode? {
        guard let family = modeFamily(ofPageMode: pageMode),
              let currentToken = modeToken(for: current),
              family != currentToken
        else { return nil }
        return [RigMode.usb, .lsb, .cw, .am, .fm].first { modeToken(for: $0) == family }
    }

    /// `bands`: the station's receive ranges, or nil when unknown (a WebSDR
    /// not loaded yet), which skips the range check.
    func retune(hostPort: String, frequencyHz: Int, mode: RigMode,
                bands: [ClosedRange<Int>]?) -> KiwiSDRURLBuilder.Result {
        switch self {
        case .kiwiSDR:
            KiwiSDRURLBuilder.retune(hostPort: hostPort, frequencyHz: frequencyHz, mode: mode,
                                     bands: bands ?? KiwiSDRURLBuilder.defaultBands)
        case .webSDR:
            WebSDRURLBuilder.retune(hostPort: hostPort, frequencyHz: frequencyHz, mode: mode, bands: bands)
        }
    }
}

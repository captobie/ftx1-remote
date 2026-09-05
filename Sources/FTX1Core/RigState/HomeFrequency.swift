import Foundation

/// The FTX-1's five band groups with a dedicated one-touch "HOME" channel
/// (Advance Manual p.27, "Memory Operation on HOME Channel Memories") — HF
/// covers the whole 1.8-29.7MHz general-coverage range as one group, not
/// `BandPlan`'s individual ham-band entries, since that's how the rig's own
/// HOME feature groups them.
///
/// The CAT command set has no way to read or recall the rig's own HOME
/// channel at all — checked the alphabetical command list, Table 3, and the
/// memory-channel commands' (`MC`/`MR`/`MW`) own documented channel-number
/// encodings (Memory Channel/PMS/5MHz BAND/EMGCH), none of which mention a
/// HOME slot. So this is a from-scratch reimplementation in the app itself,
/// not a read-through of anything the rig exposes — `HomeFrequencySettings`
/// holds the user's per-band frequency (defaulting to the Advance Manual's
/// factory defaults), and the FM/C4FM menu page's HOME button (`MenuPageView`)
/// picks whichever band the current frequency falls in and sends a plain
/// `RigCommand.setFrequency` to it, entirely client-side.
public enum HomeBand: String, CaseIterable, Sendable {
    case hf, fiftyMHz, air, mhz144, mhz430

    public var displayName: String {
        switch self {
        case .hf: "HF"
        case .fiftyMHz: "50 MHz"
        case .air: "AIR"
        case .mhz144: "144 MHz"
        case .mhz430: "430 MHz"
        }
    }

    public var range: ClosedRange<Int> {
        switch self {
        case .hf: 1_800_000...29_700_000
        case .fiftyMHz: 50_000_000...54_000_000
        case .air: 108_000_000...137_000_000
        case .mhz144: 144_000_000...148_000_000
        case .mhz430: 420_000_000...450_000_000
        }
    }

    /// Factory-default HOME channel frequency for this band group, per the
    /// FTX-1 Advance Manual page 27 ("In the default setting, the Home
    /// channel frequencies of each band are set as follows").
    public var defaultFrequencyHz: Int {
        switch self {
        case .hf: 29_600_000
        case .fiftyMHz: 51_525_000
        case .air: 118_000_000
        case .mhz144: 146_520_000
        case .mhz430: 446_000_000
        }
    }

    /// Which HOME band group a frequency falls in, if any — a frequency
    /// between groups (e.g. 30-50MHz) has no HOME group, matching the real
    /// rig's five fixed groups rather than covering its entire tuning range.
    public static func band(containing hz: Int) -> HomeBand? {
        allCases.first { $0.range.contains(hz) }
    }
}

/// `UserDefaults`-backed per-band HOME frequency, same direct-`UserDefaults`
/// pattern as `AppearanceSettings` (not `@AppStorage`, so non-View code can
/// read it too) — each device keeps its own copy, never synced between app
/// targets. Only the Mac app's `SettingsView` exposes a way to edit these
/// today; mobile targets sharing `MenuPageView`'s HOME button (see
/// `HomeBand`) fall back to `HomeBand.defaultFrequencyHz` until/unless they
/// get their own settings screen for it.
public enum HomeFrequencySettings {
    public static func key(for band: HomeBand) -> String {
        "homeFrequency.\(band.rawValue)"
    }

    public static func frequencyHz(for band: HomeBand) -> Int {
        let stored = UserDefaults.standard.object(forKey: key(for: band)) as? Int
        return stored ?? band.defaultFrequencyHz
    }

    public static func setFrequencyHz(_ hz: Int, for band: HomeBand) {
        UserDefaults.standard.set(hz, forKey: key(for: band))
    }
}

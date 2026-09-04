import Foundation

/// Snapshot of the FTX-1's live state, as reported by rigctld.
/// This is the single shared model both the Mac hub and mobile clients
/// render against — the Mac derives it from rigctld polling/events,
/// mobile derives it from WebSocket state pushes.
public struct RigState: Codable, Equatable, Sendable {
    public var frequencyHz: Int
    public var mode: RigMode
    public var band: String?
    public var powerWatts: Double?
    public var swr: Double?
    public var ptt: Bool
    public var lastUpdated: Date
    /// The other VFO's frequency (whichever isn't currently active) — see
    /// `RigctldClient.getSecondaryFrequency()`.
    public var secondaryFrequencyHz: Int?
    /// The other VFO's mode — see `RigctldClient.getSecondaryMode()`. Often
    /// nil in practice: reading it isn't reliable on every rig/backend.
    public var secondaryMode: RigMode?
    /// The RFPOWER *setting* (0.0–1.0, relative), not the metered output —
    /// that's `powerWatts`.
    public var powerLevel: Double?
    /// CW break-in (the FTX-1's raw "BI" CAT command) — nil until the first
    /// successful read, same as the other optional fields above.
    public var breakIn: Bool?
    /// CW electronic keyer on/off (the FTX-1's raw "KR" CAT command).
    public var keyerEnabled: Bool?
    /// CW keyer speed in WPM, 4-60 (the FTX-1's raw "KS" CAT command).
    public var cwSpeedWpm: Int?
    /// CW sidetone/pitch in Hz, 300-1050 in 10Hz steps (the FTX-1's raw "KP"
    /// CAT command, which encodes this as 00-75 rather than Hz directly —
    /// see `CommandQueue`/`HubService` for the conversion).
    public var cwPitchHz: Int?
    /// CW (semi) break-in delay in milliseconds — one of `RigDelayCode.
    /// allValuesMs` (the FTX-1's raw "SD" CAT command, which encodes this as
    /// a non-linear 00-33 code rather than milliseconds directly — see
    /// `RigDelayCode`).
    public var bkDelayMs: Int?
    /// CW spot (sidetone-only zero-beat aid) on/off (the FTX-1's raw "CS"
    /// CAT command).
    public var cwSpot: Bool?
    /// Monitor (sidetone) level, 0-100 (the FTX-1's raw "ML" CAT command
    /// with its P1 sub-selector set to 1 — see `CommandQueue`/`HubService`).
    /// Separate from monitor on/off, which "ML" also carries under P1=0 but
    /// which this app doesn't expose — the physical MONI button handles
    /// that on the rig itself.
    public var moniLevel: Int?
    /// CW MESSAGE memory record/playback state (the FTX-1's raw "RI" CAT
    /// command's P3 field) — reflects whichever channel is currently
    /// recording or playing, not which channel that is (RI doesn't report
    /// that). The active channel itself is UI-local state in
    /// `MenuPageView`, not part of this snapshot — see
    /// `RigCommand.selectCWMessageChannel`.
    public var cwMessageStatus: CWMessageStatus?
    /// MOX (manual transmit, i.e. CAT-triggered TX independent of PTT/VOX)
    /// on/off (the FTX-1's raw "MX" CAT command).
    public var moxEnabled: Bool?
    /// RF attenuator on/off (the FTX-1's raw "RA" CAT command, whose P1 is
    /// documented as always "0" — not a band selector like "PA"'s P1 below).
    public var attEnabled: Bool?
    /// HF/50MHz preamp/IPO selector: 0 = IPO, 1 = AMP1, 2 = AMP2 (the FTX-1's
    /// raw "PA" CAT command with its P1 band-selector fixed to 0 for HF/50 —
    /// P1=1/2 address the separate VHF/UHF preamp toggles, which this app
    /// doesn't expose).
    public var preampMode: Int?
    /// Antenna tuner engaged on/off (the FTX-1's raw "AC" CAT command's P3;
    /// see `CommandQueue`'s `.setTuner` case for the P1/P2 addressing this
    /// app uses, and `RigctldClient.getTunerEnabled()` for how it's read).
    public var tunerEnabled: Bool?
    /// TFT display contrast, 0-20 (the FTX-1's raw "DA" CAT command's P2 —
    /// see `CommandQueue`'s `.setDisplayContrast` case and
    /// `RigctldClient.getDisplaySettings()`/`setDisplaySettings(...)` for
    /// why this needs read-modify-write rather than a simple `setRawInt`).
    public var displayContrast: Int?
    /// TFT display backlight brightness, 0-20 ("DA"'s P3 — see
    /// `displayContrast` above for the shared read-modify-write mechanism).
    public var displayDimmer: Int?
    /// Spectrum scope display level, -30.0 to +30.0 dB in 0.5dB steps (the
    /// FTX-1's raw "SS" CAT command's LEVEL sub-function, P2=4 — see
    /// `RigctldClient.getSpectrumScopeLevel()`/`setSpectrumScopeLevel(_:)`).
    public var displayLevel: Double?
    /// Spectrum scope peak-hold level, 0-4 (LV1-LV5) — "SS"'s PEAK
    /// sub-function, P2=1.
    public var displayPeak: Int?
    /// Spectrum scope marker on/off — "SS"'s MARKER sub-function, P2=2.
    public var displayMarker: Bool?
    /// Microphone gain, 0-100 (the FTX-1's raw "MG" CAT command).
    public var micGain: Int?
    /// AMC (Automatic Mic Compressor) output level, 1-100 (the FTX-1's raw
    /// "AO" CAT command).
    public var amcLevel: Int?
    /// VOX (voice-operated TX) on/off (the FTX-1's raw "VX" CAT command).
    public var voxEnabled: Bool?
    /// VOX gain, 0-100 (the FTX-1's raw "VG" CAT command).
    public var voxGain: Int?
    /// VOX delay in milliseconds — one of `RigDelayCode.allValuesMs` (the
    /// FTX-1's raw "VD" CAT command, which encodes this as the same
    /// non-linear 00-33 code as `bkDelayMs`'s "SD" — see `RigDelayCode`).
    public var voxDelayMs: Int?
    /// Received signal strength in dB relative to S9 (hamlib's "STRENGTH"
    /// level convention: S0 ≈ -54, S9 = 0, "+60" = +60). nil when there's
    /// no current reading — e.g. before the first poll, or while
    /// transmitting — so the meter needle can fall to rest rather than
    /// freeze on a stale value.
    public var smeterDb: Double?
    /// Auto notch (DNF) on/off (the FTX-1's raw "BC" CAT command, P1 fixed
    /// to MAIN-side).
    public var dnfEnabled: Bool?
    /// AGC mode (the FTX-1's raw "GT" CAT command, P1 fixed to MAIN-side):
    /// 0 OFF, 1 FAST, 2 MID, 3 SLOW, 4 AUTO — those five are the only values
    /// the Set side accepts. The Read side's Answer can also report 5
    /// (AUTO-MID) or 6 (AUTO-SLOW), sub-states AGC settles into while in
    /// AUTO mode rather than distinct settings a user chose — treat 4/5/6
    /// as all meaning "AUTO" for display (see `MenuPageView.agcLabel(_:)`),
    /// and collapse them before cycling to the next mode on a tap (see
    /// `MenuPageView.agcCollapsedMode(_:)`), same asymmetric P1/P3
    /// treatment as `RigctldClient.getTunerEnabled()`'s "AC" command.
    public var agcMode: Int?
    /// Parametric Microphone Equalizer on/off (the FTX-1's raw "PR" CAT
    /// command, P1 fixed to "1" — see `RigCommand.setMicEQ`). **The
    /// manual's documented P2 values (1: OFF, 2: ON) are confirmed simply
    /// wrong against real hardware** — a live probe read the rig's actual
    /// current P2 back as "0" (a value the manual doesn't even list), and
    /// toggling between "PR10;"/"PR11;", confirmed against the rig's own
    /// display after each write, showed the real encoding is plain 0/1 —
    /// same shape as every other boolean raw command here (`getRawBool`/
    /// `setRawBool`), not the special 1/2 case it was briefly coded as.
    public var micEQEnabled: Bool?
    /// Speech processor (compressor) level, 0-100 (the FTX-1's raw "PL"
    /// CAT command). 0 means "OFF" per the manual, same convention as
    /// `moniLevel`.
    public var procLevel: Int?
    /// Noise blanker level, 0-10 (the FTX-1's raw "NL" NOISE BLANKER LEVEL
    /// CAT command, P1 fixed to MAIN-side same as "RA0"/"BC0"). 0 means
    /// "OFF" per the manual, same convention as `moniLevel`/`procLevel`.
    public var nbLevel: Int?
    /// Digital noise reduction (DNR) level, 0-10 (the FTX-1's raw "RL"
    /// NOISE REDUCTION LEVEL CAT command, P1 fixed to MAIN-side). 0 means
    /// "OFF" per the manual, same convention as `nbLevel`.
    public var dnrLevel: Int?
    /// HF antenna connector selector: 0 = ANT1, 1 = ANT2. Unlike every other
    /// field here, this has no dedicated 2-letter CAT mnemonic — it's Table
    /// 3's "HF ANT SELECT" item (`DeepSettingsCatalog`'s OPERATION SETTING /
    /// OPTION / p3=4), read/written through the same generic "EX" passthrough
    /// (`RigctldClient.getMenuItem`/`RigCommand.setMenuItem`) Deep Settings
    /// uses — reused here just for this one item's get/set shape, not the
    /// on-demand `readMenuItem` mechanism `DeepSettingsView` needs (see
    /// `RigCommand.setAntSelect`).
    public var antSelect: Int?
    /// TXW on/off (the FTX-1's raw "TS" CAT command) — unlike most booleans
    /// here, "TS" has no MAIN/SUB P1 selector at all, just a bare 0/1.
    public var txwEnabled: Bool?
    /// Callsign of the station currently being received in C4FM, if any.
    /// Unlike every other field above, this has no CAT source at all — the
    /// FTX-1's CAT command set has no mnemonic for received C4FM digital
    /// data. Instead this is scraped from a WPSD (Pi-Star-family) hotspot's
    /// dashboard over the network (see `WPSDCallsignMonitor`), on the
    /// assumption the hotspot is relaying the same network traffic the rig
    /// is hearing over local RF. Only meaningful while `mode == .c4fm`; nil
    /// whenever WPSD lookup is disabled, no hotspot is configured, or no
    /// caller is currently active.
    public var c4fmCallsign: String?
    /// Name of the YSF reflector the WPSD hotspot is currently linked to, if
    /// any. Like `c4fmCallsign`, this has no CAT source — it's scraped from
    /// the same WPSD hotspot (see `WPSDCallsignMonitor`), but from a
    /// different page (`repeaterinfo.php`'s standing "YSF Status" link,
    /// rather than `caller_details_table.php`'s per-transmission caller
    /// row) since the linked reflector persists whether or not anyone is
    /// currently transmitting. Only meaningful while `mode == .c4fm`; nil
    /// whenever WPSD lookup is disabled, no hotspot is configured, or the
    /// hotspot isn't currently linked to a reflector.
    public var c4fmReflector: String?

    public init(
        frequencyHz: Int = 0,
        mode: RigMode = .usb,
        band: String? = nil,
        powerWatts: Double? = nil,
        swr: Double? = nil,
        ptt: Bool = false,
        lastUpdated: Date = Date(),
        secondaryFrequencyHz: Int? = nil,
        secondaryMode: RigMode? = nil,
        powerLevel: Double? = nil,
        breakIn: Bool? = nil,
        keyerEnabled: Bool? = nil,
        cwSpeedWpm: Int? = nil,
        cwPitchHz: Int? = nil,
        bkDelayMs: Int? = nil,
        cwSpot: Bool? = nil,
        moniLevel: Int? = nil,
        cwMessageStatus: CWMessageStatus? = nil,
        moxEnabled: Bool? = nil,
        attEnabled: Bool? = nil,
        preampMode: Int? = nil,
        tunerEnabled: Bool? = nil,
        displayContrast: Int? = nil,
        displayDimmer: Int? = nil,
        displayLevel: Double? = nil,
        displayPeak: Int? = nil,
        displayMarker: Bool? = nil,
        micGain: Int? = nil,
        amcLevel: Int? = nil,
        voxEnabled: Bool? = nil,
        voxGain: Int? = nil,
        voxDelayMs: Int? = nil,
        smeterDb: Double? = nil,
        dnfEnabled: Bool? = nil,
        agcMode: Int? = nil,
        micEQEnabled: Bool? = nil,
        procLevel: Int? = nil,
        nbLevel: Int? = nil,
        dnrLevel: Int? = nil,
        antSelect: Int? = nil,
        txwEnabled: Bool? = nil,
        c4fmCallsign: String? = nil,
        c4fmReflector: String? = nil
    ) {
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.band = band
        self.powerWatts = powerWatts
        self.swr = swr
        self.ptt = ptt
        self.lastUpdated = lastUpdated
        self.secondaryFrequencyHz = secondaryFrequencyHz
        self.secondaryMode = secondaryMode
        self.powerLevel = powerLevel
        self.breakIn = breakIn
        self.keyerEnabled = keyerEnabled
        self.cwSpeedWpm = cwSpeedWpm
        self.cwPitchHz = cwPitchHz
        self.bkDelayMs = bkDelayMs
        self.cwSpot = cwSpot
        self.moniLevel = moniLevel
        self.cwMessageStatus = cwMessageStatus
        self.moxEnabled = moxEnabled
        self.attEnabled = attEnabled
        self.preampMode = preampMode
        self.tunerEnabled = tunerEnabled
        self.displayContrast = displayContrast
        self.displayDimmer = displayDimmer
        self.displayLevel = displayLevel
        self.displayPeak = displayPeak
        self.displayMarker = displayMarker
        self.micGain = micGain
        self.amcLevel = amcLevel
        self.voxEnabled = voxEnabled
        self.voxGain = voxGain
        self.voxDelayMs = voxDelayMs
        self.smeterDb = smeterDb
        self.dnfEnabled = dnfEnabled
        self.agcMode = agcMode
        self.micEQEnabled = micEQEnabled
        self.procLevel = procLevel
        self.nbLevel = nbLevel
        self.dnrLevel = dnrLevel
        self.antSelect = antSelect
        self.txwEnabled = txwEnabled
        self.c4fmCallsign = c4fmCallsign
        self.c4fmReflector = c4fmReflector
    }
}

/// CW MESSAGE memory record/playback state, per the FTX-1's raw "RI" CAT
/// command's P3 field — see `RigState.cwMessageStatus`.
public enum CWMessageStatus: Int, Codable, Sendable {
    case stopped = 0
    case recording = 1
    case playing = 2
}

/// Shared by the FTX-1's raw "SD" (CW break-in delay, `bkDelayMs`) and "VD"
/// (VOX delay, `voxDelayMs`) CAT commands — neither encodes milliseconds
/// directly; both use the same 2-digit code 00-33 per the CAT Operation
/// Reference Manual: codes 00-05 are fixed odd values (30/50/100/150/200/
/// 250ms), then 06-33 step linearly in 100ms increments up to 3000ms.
/// "VD"'s own table in the manual prints its step note as "10 msec
/// multiples" rather than "100 msec steps" like "SD"'s — a manual typo,
/// confirmed against real hardware: VOX DELAY steps in 100ms increments
/// same as BK-DELAY, matching this shared table.
public enum RigDelayCode {
    /// Raw "SD"/"VD" code (0-33) -> milliseconds. `nil` for any code outside
    /// that range.
    public static func milliseconds(forCode code: Int) -> Int? {
        switch code {
        case 0: 30
        case 1: 50
        case 2: 100
        case 3: 150
        case 4: 200
        case 5: 250
        case 6...33: 300 + (code - 6) * 100
        default: nil
        }
    }

    /// Reverse of `milliseconds(forCode:)`. Every value in `allValuesMs`
    /// round-trips through this exactly.
    public static func code(forMilliseconds ms: Int) -> Int? {
        (0...33).first { milliseconds(forCode: $0) == ms }
    }

    /// All valid values in order, for driving a UI stepper/picker.
    public static let allValuesMs: [Int] = (0...33).compactMap(milliseconds(forCode:))
}

public enum RigMode: String, Codable, Sendable, CaseIterable, Hashable {
    case usb = "USB"
    case lsb = "LSB"
    case cw = "CW"
    case fm = "FM"
    case am = "AM"
    case rtty = "RTTY"
    /// hamlib's own name for this mode is "PKTUSB" — the raw value has to
    /// stay that for `RigMode(rawValue:)` to recognize it and for
    /// `CommandQueue`'s set-mode command to speak hamlib's vocabulary;
    /// `displayName` shows "DATA-U", the name the CAT manual and operators
    /// actually use for it.
    case dataUSB = "PKTUSB"
    /// Confirmed via real hardware and the CAT manual's OPERATING MODE
    /// (`MD`) table that hamlib's "FM-D" mode string is actually Yaesu's
    /// separate DATA-FM mode (raw code "A"), not C4FM — a prior mix-up
    /// (see git history) treated "FM-D" as this rig's hamlib name for
    /// C4FM and wired the C4FM UI button to set it, which put the radio
    /// in DATA-FM instead. `displayName` shows the CAT manual's own name
    /// for it.
    case dataFM = "FM-D"
    /// Yaesu's real C4FM digital voice mode (raw codes "H"/"I", C4FM-DN/
    /// C4FM-VW, per the CAT manual's `MD` table) — hamlib's generic set-
    /// mode verb has no bit for either variant on this rig's backend, so
    /// this raw value is never sent to or parsed from hamlib directly; it
    /// only identifies the mode within this app (Codable wire protocol,
    /// `RigMode(rawValue:)`). `CommandQueue` special-cases `.setMode` for
    /// this value to go through `RigctldClient.setActiveModeC4FM()`'s raw
    /// CAT passthrough instead of hamlib's "M" verb; reads go through the
    /// existing `isActiveModeC4FM()`/`isSecondaryModeC4FM()` fallback for
    /// the same reason.
    case c4fm = "C4FM"
    case unknown = "UNKNOWN"

    public var displayName: String {
        switch self {
        case .dataUSB: "DATA-U"
        case .dataFM: "DATA-FM"
        case .c4fm: "C4FM"
        default: rawValue
        }
    }
}

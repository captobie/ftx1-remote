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
    /// Filter width, encoded as a raw 0-23 index (the FTX-1's raw "SH"
    /// WIDTH CAT command, P1 fixed to MAIN-side, P2 fixed to "0") — **not**
    /// Hz directly. Per the CAT manual's Table 5 (Bandwidth Chart), the
    /// same index maps to a *different* Hz value depending on the current
    /// mode (e.g. index 17 is 2400 Hz for DATA-U/CW/RTTY-family modes but
    /// only some indices are valid at all for AM-N/FM, which mostly show
    /// "-"). This app doesn't decode the index to Hz for display — it's
    /// tracked only so `BandMemory` can remember/restore it per band, the
    /// same way it already does for `mode` (see `HubService.send(_:)`'s
    /// `.setBand` handling): switching to a mode-forcing general-coverage
    /// segment (e.g. NOAA WX's forced FM) and back was observed leaving the
    /// rig on whatever raw width index FM last used, which reads as a
    /// different, wrong Hz value once the original mode is restored.
    public var filterWidthIndex: Int?
    /// IF SHIFT in Hz, -1200...1200 in 20 Hz steps (the FTX-1's raw "IS"
    /// CAT command, P1 fixed to MAIN-side, P2 fixed to "0", then a sign
    /// character and a 4-digit magnitude — see `IFShift` for the value
    /// space and `RigctldClient.getIFShiftHz()` for why the generic
    /// `getRawInt` can't parse it). Positive slides the passband up.
    public var ifShiftHz: Int?
    /// Manual IF NOTCH on/off (the FTX-1's raw "BP" CAT command, P1 fixed
    /// to MAIN-side, P2=0 sub-function). Distinct from the auto notch/DNF
    /// (`dnfEnabled`, raw "BC"). The wire field is 3 digits (000/001), so
    /// it's read/written through `getRawInt`/`setRawInt(digits: 3)`, not
    /// `getRawBool` — see `IFNotch`.
    public var notchEnabled: Bool?
    /// Manual IF NOTCH frequency in Hz, 10-3200 in 10 Hz steps ("BP"'s
    /// P2=1 sub-function, carried on the wire as a 3-digit code of 10 Hz
    /// units — `IFNotch.code(forHz:)`/`hz(forCode:)`).
    public var notchHz: Int?
    /// CONTOUR on/off (the FTX-1's raw "CO" CAT command, P2=0). Every "CO"
    /// field is 4 digits, on/off included (0000/0001), so all four go
    /// through `getRawInt`/`setRawInt(digits: 4)` — see `IFContour`.
    public var contourEnabled: Bool?
    /// CONTOUR frequency in Hz, 10-3200 in 10 Hz steps ("CO" P2=1, carried
    /// as 4-digit Hz directly).
    public var contourHz: Int?
    /// APF (audio peak filter, CW only) on/off ("CO" P2=2).
    public var apfEnabled: Bool?
    /// APF offset from the CW pitch in Hz, −250…+250 in 10 Hz steps ("CO"
    /// P2=3, carried as a 4-digit code 0000-0050 — `IFContour.apfCode(
    /// forHz:)`/`apfHz(forCode:)`).
    public var apfHz: Int?
    /// NARROW ("N/W") on/off (the FTX-1's raw "NA" CAT command, P1 fixed
    /// to MAIN-side, plain single-digit boolean like "BC0"). Snaps the
    /// passband to the mode's preset narrow width — Deep Settings' NAR
    /// WIDTH for SSB/DATA/RTTY/CW, the fixed second row of
    /// `FilterWidthTable` for AM/FM — so `filterWidthIndex` changes with
    /// it; `HubService` re-reads "SH0" right after a NAR write so the
    /// Width readout follows without waiting for the slow tier.
    public var narrowEnabled: Bool?
    /// The current mode's NAR WIDTH menu preset in Hz — the bandwidth the
    /// rig uses while `narrowEnabled` in SSB/CW/RTTY/DATA, where the raw
    /// "SH" index keeps reporting the wide setting (see
    /// `NarrowWidthPreset`). Read through the "EX" passthrough in the slow
    /// tier; nil in modes without a preset (AM/FM/C4FM) or before the
    /// first read. Only the Filter Function Display uses it today.
    public var narrowWidthHz: Int?
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
    /// SPLIT on/off (the FTX-1's raw "ST" CAT command) — like "TS" above, a
    /// bare 0/1 with no MAIN/SUB P1 selector. Drives the TXRX/RX label
    /// `VFODisplayBox` shows next to MAIN, matching the rig's own display:
    /// `false` (or not yet read) shows "TXRX", `true` shows "RX" —
    /// confirmed against real hardware. SUB shows a static "RX" regardless
    /// of this field (see `VFODisplayBox`'s call sites) — confirmed split
    /// OFF; the exact real-hardware label(s) while split is ON are still
    /// being confirmed (the rig appears to show a TX/RX pair somewhere in
    /// that state, not yet pinned down whether that's MAIN-internal or
    /// spans MAIN/SUB — don't assume the current MAIN ternary above is
    /// final for the split-ON case).
    public var splitEnabled: Bool?
    /// Squelch type, 0-5 (OFF/ENC/TSQ/DCS/PR FREQ/REV TONE) — the FTX-1's raw
    /// "CT" CAT command, P1 fixed to "0" (MAIN-side). Same setting as Deep
    /// Settings' RADIO SETTING → MODE FM → SQL TYPE item, but reached here
    /// through its own dedicated mnemonic rather than the generic "EX"
    /// passthrough, same reasoning as `agcMode`/`dnfEnabled` above.
    public var squelchType: Int?
    /// Index into `RigCTCSSTone.allValuesHz` (0-49) — the FTX-1's raw "CN"
    /// CAT command's P2=0 (CTCSS) sub-function, P1 fixed to "0" (MAIN-side).
    /// Independent of `squelchType`: this is which tone is currently dialed
    /// in, not whether CTCSS is the active squelch type.
    public var ctcssToneIndex: Int?
    /// Index into `RigDCSCode.allValues` (0-103) — the FTX-1's raw "CN" CAT
    /// command's P2=1 (DCS) sub-function, same shape as `ctcssToneIndex`.
    public var dcsCodeIndex: Int?
    /// Repeater shift direction, 0-3 (Simplex/Plus Shift/Minus Shift/ARS) —
    /// the FTX-1's raw "OS" (OFFSET/REPEATER SHIFT) CAT command, P1 fixed to
    /// "0" (MAIN-side). The manual notes this command "can be activated only
    /// with an FM mode."
    public var repeaterShiftMode: Int?
    /// APRS beacon type, 0-2 (OFF/AUTO/SMART) — like `antSelect`, this has no
    /// dedicated 2-letter CAT mnemonic; it's Table 3's "BEACON TYPE" item
    /// (`DeepSettingsCatalog`'s APRS BEACON / BEACON SET. / p3=1), read/
    /// written through the same generic "EX" passthrough
    /// (`RigctldClient.getMenuItem`/`RigCommand.setMenuItem`) Deep Settings
    /// uses, reused here just for this one item's get/set shape (see
    /// `RigCommand.setAPRSBeaconType`).
    public var aprsBeaconType: Int?
    /// FM channel step, 0-5 (5/6.25/10/12.5/20/25 kHz) — same shape as
    /// `aprsBeaconType`: no dedicated mnemonic, it's Table 3's "FM CH STEP"
    /// item (`DeepSettingsCatalog`'s OPERATION SETTING / KEY/DIAL / p3=6),
    /// reused here through the generic "EX" passthrough (see
    /// `RigCommand.setFMChannelStep`).
    public var fmChannelStep: Int?
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
    /// Whether the active VFO is currently parked on the configured APRS
    /// frequency — `APRSSettings.isActive(atFrequencyHz:)` evaluated against
    /// `frequencyHz`, mirroring the same gate `HubService` uses to decide
    /// whether to actually run audio through the APRS decoder. Like
    /// `c4fmCallsign`/`c4fmReflector`, this has no CAT source; unlike them
    /// it isn't mode-restricted (APRS's audio gate is frequency-only, same
    /// as the decoder itself), so it can in principle be true outside FM,
    /// though that's not a real-world scenario.
    public var aprsActive: Bool
    /// Callsign of the most recently APRS-decoded station, if one was heard
    /// within the last 5 seconds — `HubService` clears this back to `nil`
    /// once 5 seconds have elapsed since the last decode (see its
    /// `aprsLastCallsignHeard` doc comment), rather than this field ever
    /// being cleared by a timer of its own. Only meaningful while
    /// `aprsActive`; nil whenever APRS decoding is disabled, off-frequency,
    /// or nothing's been decoded in the last 5 seconds.
    public var aprsLastCallsign: String?
    /// MAIN-side (VFO A) VFO-vs-memory mode, from the FTX-1's raw "VM" (VFO /
    /// MEMORY CHANNEL) CAT command's P2 field, P1 fixed to MAIN-side. See
    /// `VFOMemoryMode`.
    public var vfoMemoryMode: VFOMemoryMode?
    /// Currently-selected MAIN-side memory channel, 1-99 — the FTX-1's raw
    /// "MC" (MEMORY CHANNEL) CAT command's P2 field, P1 fixed to MAIN-side.
    /// Only meaningful while `vfoMemoryMode == .memory`; nil otherwise
    /// (including while in VFO mode, rather than holding onto a stale
    /// channel number from the last time memory mode was active).
    public var memoryChannel: Int?
    /// `memoryChannel`'s user-assigned TAG (name), if it has one — the
    /// FTX-1's raw "MT" CAT command. Same "nil rather than stale" contract
    /// as `memoryChannel`: only meaningful alongside a non-nil
    /// `memoryChannel`, and nil (not held over) once that's nil too.
    public var memoryChannelTag: String?
    /// Local app-level safety policy, not CAT-sourced — mirrors the Mac's
    /// `RigctldSettings.transmitEnabled` and is pushed to clients like every
    /// other field so a remote PTT/MOX/ANT TUNE control can reflect it. When
    /// `false`, `HubService.send(_:)` refuses every transmit-capable
    /// command (see its `isTransmitCapable(_:)`) regardless of which client
    /// or UI control sent it.
    public var transmitEnabled: Bool

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
        filterWidthIndex: Int? = nil,
        ifShiftHz: Int? = nil,
        notchEnabled: Bool? = nil,
        notchHz: Int? = nil,
        contourEnabled: Bool? = nil,
        contourHz: Int? = nil,
        apfEnabled: Bool? = nil,
        apfHz: Int? = nil,
        narrowEnabled: Bool? = nil,
        narrowWidthHz: Int? = nil,
        antSelect: Int? = nil,
        txwEnabled: Bool? = nil,
        splitEnabled: Bool? = nil,
        squelchType: Int? = nil,
        ctcssToneIndex: Int? = nil,
        dcsCodeIndex: Int? = nil,
        repeaterShiftMode: Int? = nil,
        aprsBeaconType: Int? = nil,
        fmChannelStep: Int? = nil,
        c4fmCallsign: String? = nil,
        c4fmReflector: String? = nil,
        aprsActive: Bool = false,
        aprsLastCallsign: String? = nil,
        vfoMemoryMode: VFOMemoryMode? = nil,
        memoryChannel: Int? = nil,
        memoryChannelTag: String? = nil,
        transmitEnabled: Bool = true
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
        self.filterWidthIndex = filterWidthIndex
        self.ifShiftHz = ifShiftHz
        self.notchEnabled = notchEnabled
        self.notchHz = notchHz
        self.contourEnabled = contourEnabled
        self.contourHz = contourHz
        self.apfEnabled = apfEnabled
        self.apfHz = apfHz
        self.narrowEnabled = narrowEnabled
        self.narrowWidthHz = narrowWidthHz
        self.antSelect = antSelect
        self.txwEnabled = txwEnabled
        self.splitEnabled = splitEnabled
        self.squelchType = squelchType
        self.ctcssToneIndex = ctcssToneIndex
        self.dcsCodeIndex = dcsCodeIndex
        self.repeaterShiftMode = repeaterShiftMode
        self.aprsBeaconType = aprsBeaconType
        self.fmChannelStep = fmChannelStep
        self.c4fmCallsign = c4fmCallsign
        self.c4fmReflector = c4fmReflector
        self.aprsActive = aprsActive
        self.aprsLastCallsign = aprsLastCallsign
        self.vfoMemoryMode = vfoMemoryMode
        self.memoryChannel = memoryChannel
        self.memoryChannelTag = memoryChannelTag
        self.transmitEnabled = transmitEnabled
    }
}

/// MAIN-side VFO-vs-memory mode, per the FTX-1's raw "VM" (VFO / MEMORY
/// CHANNEL) CAT command's P2 field — see `RigState.vfoMemoryMode`. The
/// manual documents 6 P2 values (00 VFO, 10 MT, 11 Memory, 20 PMS, 21
/// P-01L-P-50U, 51 5MHz Band Memory, 91 EMG); this app's UI only
/// distinguishes plain VFO vs. plain Memory, so every other value collapses
/// into `.other(rawP2:)` rather than being modeled as its own case.
///
/// Not to be confused with the CAT manual's *other*, unrelated "VM" table
/// entry ("MAIN-SIDE TO MEMORY CHANNEL", no parameters) — this type is
/// backed by the P1/P2-parameterized "VFO / MEMORY CHANNEL" entry only, read
/// via a plain `RigctldClient.getRawInt("VM0")` and set via `setRawInt("VM0",
/// ..., digits: 2)` (see `HubService.refreshFastTier()` and `CommandQueue`'s
/// `.setVFOMemoryMode` case) — P1 is fixed to MAIN-side and baked into the
/// "VM0" prefix, same fixed-sub-selector shape as "RA0"/"GT0"/"CT0", so no
/// bespoke method was needed.
public enum VFOMemoryMode: Equatable, Codable, Sendable {
    case vfo
    case memory
    case other(rawP2: Int)

    /// Maps the raw "VM" P2 value read from the rig to this type — same
    /// "raw CAT layer stays dumb, the app layer does the mapping" split as
    /// `CWMessageStatus.init(rawValue:)` (see `HubService.refreshFastTier()`).
    public init(rawP2: Int) {
        switch rawP2 {
        case 0: self = .vfo
        case 11: self = .memory
        default: self = .other(rawP2: rawP2)
        }
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

/// FTX-1's raw "CN" (CTCSS TONE FREQUENCY / DCS CODE) command's P2=0 sub-
/// function indexes into a fixed 50-tone table (the CAT manual's Table 1)
/// rather than encoding Hz directly — same non-linear-code shape as
/// `RigDelayCode`. Standard/industry-wide CTCSS tones, not specific to this
/// rig (see `RigState.ctcssToneIndex`).
public enum RigCTCSSTone {
    public static let allValuesHz: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5,
        94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3,
        131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9,
        171.3, 173.8, 177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
        203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1,
    ]

    public static func hertz(forIndex index: Int) -> Double? {
        allValuesHz.indices.contains(index) ? allValuesHz[index] : nil
    }
}

/// Same shape as `RigCTCSSTone`, for "CN"'s P2=1 (DCS) sub-function's fixed
/// 104-code table (the CAT manual's Table 2). Codes are stored as their
/// printed 3-digit strings, not parsed as numbers — they're opaque labels,
/// not arithmetic quantities (see `RigState.dcsCodeIndex`).
public enum RigDCSCode {
    public static let allValues: [String] = [
        "023", "025", "026", "031", "032", "036", "043", "047", "051", "053",
        "054", "065", "071", "072", "073", "074", "114", "115", "116", "122",
        "125", "131", "132", "134", "143", "145", "152", "155", "156", "162",
        "165", "172", "174", "205", "212", "223", "225", "226", "243", "244",
        "245", "246", "251", "252", "255", "261", "263", "265", "266", "271",
        "274", "306", "311", "315", "325", "331", "332", "343", "346", "351",
        "356", "364", "365", "371", "411", "412", "413", "423", "431", "432",
        "445", "446", "452", "454", "455", "462", "464", "465", "466", "503",
        "506", "516", "523", "526", "532", "546", "565", "606", "612", "624",
        "627", "631", "632", "654", "662", "664", "703", "712", "723", "731",
        "732", "734", "743", "754",
    ]

    public static func code(forIndex index: Int) -> String? {
        allValues.indices.contains(index) ? allValues[index] : nil
    }
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

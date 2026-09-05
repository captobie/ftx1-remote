import Foundation

/// Commands a client (iOS/iPadOS, or the Mac's own local UI) can send
/// to the Mac hub over the WebSocket connection.
///
/// Kept as an enum with associated values internally, but encodes/decodes
/// to the flat `{"cmd": ..., "value": ...}` shape from the protocol draft
/// so it stays simple to read on the wire and easy to extend later.
public enum RigCommand: Sendable, Equatable {
    case setFrequency(hz: Int)
    /// Writes VFO B's frequency — whichever of Main/Sub isn't currently
    /// active (see `RigState.secondaryFrequencyHz`). Maps to
    /// `RigctldClient.setSecondaryFrequency(_:)`, the set-side counterpart
    /// of `getSecondaryFrequency()`.
    case setSecondaryFrequency(hz: Int)
    /// Switches which of Main/Sub is the active VFO — momentary, like
    /// `.triggerZeroIn`, no associated value. Maps to
    /// `RigctldClient.swapActiveVFO()`.
    case swapActiveVFO
    case setMode(RigMode)
    case setPTT(Bool)
    case setBand(String)
    /// 0.0–1.0, relative RFPOWER setting (not watts) — see `RigState.powerLevel`.
    case setPowerLevel(Double)
    /// CW break-in on/off — see `RigState.breakIn`. Maps to the FTX-1's own
    /// raw "BI" CAT command in `CommandQueue` (per the CAT Operation
    /// Reference Manual), not a hamlib func — doesn't distinguish semi vs.
    /// full break-in, which is a separate menu item on the real rig.
    case setBreakIn(Bool)
    /// CW electronic keyer on/off — see `RigState.keyerEnabled`. Maps to
    /// the FTX-1's raw "KR" CAT command.
    case setKeyer(Bool)
    /// CW keyer speed, 4-60 WPM — see `RigState.cwSpeedWpm`. Maps to the
    /// FTX-1's raw "KS" CAT command.
    case setCWSpeed(wpm: Int)
    /// CW sidetone/pitch, 300-1050 Hz in 10Hz steps — see
    /// `RigState.cwPitchHz`. Maps to the FTX-1's raw "KP" CAT command.
    case setCWPitch(hz: Int)
    /// CW (semi) break-in delay in milliseconds — must be one of
    /// `RigDelayCode.allValuesMs`. See `RigState.bkDelayMs`. Maps to the
    /// FTX-1's raw "SD" CAT command.
    case setBreakInDelay(ms: Int)
    /// CW spot on/off — see `RigState.cwSpot`. Maps to the FTX-1's raw "CS"
    /// CAT command.
    case setCWSpot(Bool)
    /// Triggers the FTX-1's CW auto zero-in function on the Main VFO —
    /// momentary, not a stored setting, so unlike every other case there's
    /// no associated value to round-trip. Maps to the FTX-1's raw "ZI0"
    /// CAT command (per the CAT Operation Reference Manual, "ZI" takes a
    /// Main/Sub selector rather than an on/off state, and documents no
    /// reply).
    case triggerZeroIn
    /// Monitor (sidetone) level, 0-100 — see `RigState.moniLevel`. Maps to
    /// the FTX-1's raw "ML" CAT command with its P1 sub-selector set to 1
    /// (level, as opposed to P1=0 for on/off, which this app doesn't
    /// expose).
    case setMoniLevel(level: Int)
    /// Selects which CW MESSAGE memory channel (1-5) is "active" on the
    /// rig — doesn't itself start playback or recording. Maps to the
    /// FTX-1's raw "LM" CAT command with P1=0 (the message-select
    /// sub-mode, as opposed to P1=1 for `setCWMessageRecording`).
    case selectCWMessageChannel(Int)
    /// Starts/stops recording spoken CW audio into whichever channel
    /// `selectCWMessageChannel` last selected. Maps to the FTX-1's raw
    /// "LM" CAT command with P1=1 (the record sub-mode).
    case setCWMessageRecording(Bool)
    /// Starts playback of a CW MESSAGE channel (0 to stop, 1-5 to play
    /// that channel) — independent of whatever `selectCWMessageChannel`
    /// last selected. Maps to the FTX-1's raw "KY" CAT command with P1
    /// fixed to 1 (CW MESSAGE Memory, as opposed to 0 for CW TEXT Memory
    /// / typed keyer-memory content, which this app doesn't expose).
    case playCWMessage(channel: Int)
    /// MOX (manual transmit) on/off — see `RigState.moxEnabled`. Maps to the
    /// FTX-1's raw "MX" CAT command. Note this actually keys the
    /// transmitter, same as `setPTT`.
    case setMox(Bool)
    /// RF attenuator on/off — see `RigState.attEnabled`. Maps to the FTX-1's
    /// raw "RA" CAT command (P1 fixed to "0" per the manual).
    case setAtt(Bool)
    /// HF/50MHz preamp/IPO selector, 0-2 (IPO/AMP1/AMP2) — see
    /// `RigState.preampMode`. Maps to the FTX-1's raw "PA" CAT command with
    /// its band-selector P1 fixed to 0 (HF/50).
    case setPreamp(mode: Int)
    /// Antenna tuner engaged on/off — see `RigState.tunerEnabled`. Maps to
    /// the FTX-1's raw "AC" CAT command with P1/P2 fixed to 0/0 (internal
    /// tuner, Antenna-Tuner mode).
    case setTuner(Bool)
    /// Starts an antenna tuning cycle — momentary, not a stored setting
    /// (like `triggerZeroIn`, no associated value). Maps to the FTX-1's raw
    /// "AC" command with P3=3 ("Tuning Start"), same P1/P2 addressing as
    /// `setTuner` (P1=1 confirmed against this rig's real hardware, P2=0
    /// Antenna-Tuner mode).
    case triggerAntennaTune
    /// TFT display contrast, 0-20 — see `RigState.displayContrast`. Maps to
    /// the FTX-1's raw "DA" CAT command's P2 field (read-modify-write, since
    /// "DA" sets contrast/brightness/LED-brightness together — see
    /// `RigctldClient.setDisplaySettings(...)`).
    case setDisplayContrast(Int)
    /// TFT display backlight brightness ("dimmer"), 0-20 — see
    /// `RigState.displayDimmer`. Maps to the FTX-1's raw "DA" CAT command's
    /// P3 field, same read-modify-write mechanism as `setDisplayContrast`.
    case setDisplayDimmer(Int)
    /// Spectrum scope display level, -30.0 to +30.0 dB in 0.5dB steps — see
    /// `RigState.displayLevel`. Maps to the FTX-1's raw "SS" CAT command's
    /// LEVEL sub-function (P2=4).
    case setDisplayLevel(Double)
    /// Spectrum scope peak-hold level, 0-4 (LV1-LV5) — see
    /// `RigState.displayPeak`. Maps to "SS"'s PEAK sub-function (P2=1).
    case setDisplayPeak(Int)
    /// Spectrum scope marker on/off — see `RigState.displayMarker`. Maps to
    /// "SS"'s MARKER sub-function (P2=2).
    case setDisplayMarker(Bool)
    /// Microphone gain, 0-100 — see `RigState.micGain`. Maps to the FTX-1's
    /// raw "MG" CAT command.
    case setMicGain(Int)
    /// AMC (Automatic Mic Compressor) output level, 1-100 — see
    /// `RigState.amcLevel`. Maps to the FTX-1's raw "AO" CAT command.
    case setAMCLevel(Int)
    /// VOX (voice-operated TX) on/off — see `RigState.voxEnabled`. Maps to
    /// the FTX-1's raw "VX" CAT command.
    case setVox(Bool)
    /// VOX gain, 0-100 — see `RigState.voxGain`. Maps to the FTX-1's raw
    /// "VG" CAT command.
    case setVoxGain(Int)
    /// VOX delay in milliseconds — must be one of `RigDelayCode.
    /// allValuesMs`, same non-linear 00-33 code as `setBreakInDelay`. See
    /// `RigState.voxDelayMs`. Maps to the FTX-1's raw "VD" CAT command.
    case setVoxDelay(ms: Int)
    /// Auto notch (DNF, "Digital Notch Filter" on the rig's own button
    /// label) on/off — see `RigState.dnfEnabled`. Maps to the FTX-1's raw
    /// "BC" CAT command, P1 fixed to "0" (MAIN-side), same fixed-sub-
    /// selector shape as "RA0"/"ML1".
    case setDNF(Bool)
    /// AGC mode, 0-4 (OFF/FAST/MID/SLOW/AUTO) — see `RigState.agcMode`.
    /// Maps to the FTX-1's raw "GT" CAT command, P1 fixed to "0"
    /// (MAIN-side). Only 0-4 are valid to *set*; the Read side can answer
    /// with 5/6 too (AUTO-MID/AUTO-SLOW, sub-states of AUTO) — see
    /// `RigctldClient`'s "GT0" read and `RigState.agcMode`'s doc comment.
    case setAGC(mode: Int)
    /// Parametric Microphone Equalizer on/off — see `RigState.micEQEnabled`.
    /// Maps to the FTX-1's raw "PR" (SPEECH PROCESSOR) CAT command, P1 fixed
    /// to "1" (Parametric Microphone Equalizer, as opposed to P1=0, the
    /// separate Speech Processor master on/off this app doesn't expose).
    /// The manual documents its own P2 as 1: OFF, 2: ON, but that's
    /// confirmed simply wrong against real hardware — see
    /// `RigState.micEQEnabled`'s doc comment. Real P2 is plain 0/1, so this
    /// is a normal `setRawBool`/`getRawBool` case in `CommandQueue`/
    /// `HubService`, no special encoding needed after all.
    case setMicEQ(Bool)
    /// Speech processor (compressor) level, 0-100 — see `RigState.
    /// procLevel`. 0 reads/sets as "OFF" per the manual, same convention as
    /// `RigState.moniLevel`. Maps to the FTX-1's raw "PL" (SPEECH PROCESSOR
    /// LEVEL) CAT command.
    case setProcLevel(Int)
    /// Noise blanker level, 0-10 — see `RigState.nbLevel`. 0 reads/sets as
    /// "OFF" per the manual, same convention as `setProcLevel`. Maps to the
    /// FTX-1's raw "NL" (NOISE BLANKER LEVEL) CAT command, P1 fixed to "0"
    /// (MAIN-side).
    case setNBLevel(Int)
    /// Digital noise reduction (DNR) level, 0-10 — see `RigState.dnrLevel`.
    /// Maps to the FTX-1's raw "RL" (NOISE REDUCTION LEVEL) CAT command, P1
    /// fixed to "0" (MAIN-side), same shape as `setNBLevel`.
    case setDNRLevel(Int)
    /// HF antenna connector selector: 0 = ANT1, 1 = ANT2 — see
    /// `RigState.antSelect`. No dedicated mnemonic; goes through the same
    /// "EX" (MENU) passthrough as `.setMenuItem` below, addressed at Table
    /// 3's fixed p1=3/p2=7/p3=4 ("HF ANT SELECT").
    case setAntSelect(Int)
    /// TXW on/off — see `RigState.txwEnabled`. Maps to the FTX-1's raw "TS"
    /// CAT command, a bare boolean with no MAIN/SUB P1 selector.
    case setTXW(Bool)
    /// Squelch type, 0-5 (OFF/ENC/TSQ/DCS/PR FREQ/REV TONE) — see
    /// `RigState.squelchType`. Maps to the FTX-1's raw "CT" CAT command, P1
    /// fixed to "0" (MAIN-side).
    case setSquelchType(Int)
    /// Index into `RigCTCSSTone.allValuesHz` (0-49) — see
    /// `RigState.ctcssToneIndex`. Maps to the FTX-1's raw "CN" CAT command's
    /// P2=0 (CTCSS) sub-function, P1 fixed to "0" (MAIN-side).
    case setToneFreq(index: Int)
    /// Index into `RigDCSCode.allValues` (0-103) — see
    /// `RigState.dcsCodeIndex`. Maps to the FTX-1's raw "CN" CAT command's
    /// P2=1 (DCS) sub-function, same shape as `setToneFreq`.
    case setDCSCode(index: Int)
    /// Repeater shift direction, 0-3 (Simplex/Plus Shift/Minus Shift/ARS) —
    /// see `RigState.repeaterShiftMode`. Maps to the FTX-1's raw "OS"
    /// (OFFSET/REPEATER SHIFT) CAT command, P1 fixed to "0" (MAIN-side).
    case setRepeaterShift(mode: Int)
    /// APRS beacon type, 0-2 (OFF/AUTO/SMART) — see `RigState.aprsBeaconType`.
    /// No dedicated mnemonic; goes through the same "EX" (MENU) passthrough
    /// as `.setAntSelect`, addressed at Table 3's fixed p1=7/p2=1/p3=1
    /// ("BEACON TYPE").
    case setAPRSBeaconType(Int)
    /// Writes one item of the FTX-1's deep SET-mode settings (Radio/CW/
    /// Operation/Display/Extension/APRS Setting — see
    /// `DeepSettingsCatalog`), addressed by `p1`/`p2`/`p3` (category/tab/
    /// item) rather than a dedicated mnemonic. `rawValue` is already
    /// encoded to the item's expected CAT shape via
    /// `DeepSettingItem.encode(_:)` — this case is a generic passthrough,
    /// covering every item in the catalog with a single `RigCommand` case
    /// rather than one per item (there are ~300).
    case setMenuItem(p1: Int, p2: Int, p3: Int, rawValue: String)

    /// Wire payload for `.setMenuItem`, the one case here with more than a
    /// single associated value.
    private struct MenuItemPayload: Codable, Sendable, Equatable {
        let p1: Int
        let p2: Int
        let p3: Int
        let rawValue: String
    }

    private enum CodingKeys: String, CodingKey {
        case cmd
        case value
    }

    private enum CommandName: String, Codable {
        case setFreq = "set_freq"
        case setSecondaryFreq = "set_secondary_freq"
        case swapActiveVFO = "swap_active_vfo"
        case setMode = "set_mode"
        case ptt
        case setBand = "set_band"
        case setPower = "set_power"
        case setBreakIn = "set_break_in"
        case setKeyer = "set_keyer"
        case setCWSpeed = "set_cw_speed"
        case setCWPitch = "set_cw_pitch"
        case setBreakInDelay = "set_bk_delay"
        case setCWSpot = "set_cw_spot"
        case triggerZeroIn = "zero_in"
        case setMoniLevel = "set_moni_level"
        case selectCWMessageChannel = "select_cw_message_channel"
        case setCWMessageRecording = "set_cw_message_recording"
        case playCWMessage = "play_cw_message"
        case setMox = "set_mox"
        case setAtt = "set_att"
        case setPreamp = "set_preamp"
        case setTuner = "set_tuner"
        case triggerAntennaTune = "trigger_antenna_tune"
        case setDisplayContrast = "set_display_contrast"
        case setDisplayDimmer = "set_display_dimmer"
        case setDisplayLevel = "set_display_level"
        case setDisplayPeak = "set_display_peak"
        case setDisplayMarker = "set_display_marker"
        case setMicGain = "set_mic_gain"
        case setAMCLevel = "set_amc_level"
        case setVox = "set_vox"
        case setVoxGain = "set_vox_gain"
        case setVoxDelay = "set_vox_delay"
        case setDNF = "set_dnf"
        case setAGC = "set_agc"
        case setMicEQ = "set_mic_eq"
        case setProcLevel = "set_proc_level"
        case setNBLevel = "set_nb_level"
        case setDNRLevel = "set_dnr_level"
        case setAntSelect = "set_ant_select"
        case setTXW = "set_txw"
        case setSquelchType = "set_squelch_type"
        case setToneFreq = "set_tone_freq"
        case setDCSCode = "set_dcs_code"
        case setRepeaterShift = "set_repeater_shift"
        case setAPRSBeaconType = "set_aprs_beacon_type"
        case setMenuItem = "set_menu_item"
    }
}

extension RigCommand: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(CommandName.self, forKey: .cmd)
        switch name {
        case .setFreq:
            self = .setFrequency(hz: try container.decode(Int.self, forKey: .value))
        case .setSecondaryFreq:
            self = .setSecondaryFrequency(hz: try container.decode(Int.self, forKey: .value))
        case .swapActiveVFO:
            self = .swapActiveVFO
        case .setMode:
            self = .setMode(try container.decode(RigMode.self, forKey: .value))
        case .ptt:
            self = .setPTT(try container.decode(Bool.self, forKey: .value))
        case .setBand:
            self = .setBand(try container.decode(String.self, forKey: .value))
        case .setPower:
            self = .setPowerLevel(try container.decode(Double.self, forKey: .value))
        case .setBreakIn:
            self = .setBreakIn(try container.decode(Bool.self, forKey: .value))
        case .setKeyer:
            self = .setKeyer(try container.decode(Bool.self, forKey: .value))
        case .setCWSpeed:
            self = .setCWSpeed(wpm: try container.decode(Int.self, forKey: .value))
        case .setCWPitch:
            self = .setCWPitch(hz: try container.decode(Int.self, forKey: .value))
        case .setBreakInDelay:
            self = .setBreakInDelay(ms: try container.decode(Int.self, forKey: .value))
        case .setCWSpot:
            self = .setCWSpot(try container.decode(Bool.self, forKey: .value))
        case .triggerZeroIn:
            self = .triggerZeroIn
        case .setMoniLevel:
            self = .setMoniLevel(level: try container.decode(Int.self, forKey: .value))
        case .selectCWMessageChannel:
            self = .selectCWMessageChannel(try container.decode(Int.self, forKey: .value))
        case .setCWMessageRecording:
            self = .setCWMessageRecording(try container.decode(Bool.self, forKey: .value))
        case .playCWMessage:
            self = .playCWMessage(channel: try container.decode(Int.self, forKey: .value))
        case .setMox:
            self = .setMox(try container.decode(Bool.self, forKey: .value))
        case .setAtt:
            self = .setAtt(try container.decode(Bool.self, forKey: .value))
        case .setPreamp:
            self = .setPreamp(mode: try container.decode(Int.self, forKey: .value))
        case .setTuner:
            self = .setTuner(try container.decode(Bool.self, forKey: .value))
        case .triggerAntennaTune:
            self = .triggerAntennaTune
        case .setDisplayContrast:
            self = .setDisplayContrast(try container.decode(Int.self, forKey: .value))
        case .setDisplayDimmer:
            self = .setDisplayDimmer(try container.decode(Int.self, forKey: .value))
        case .setDisplayLevel:
            self = .setDisplayLevel(try container.decode(Double.self, forKey: .value))
        case .setDisplayPeak:
            self = .setDisplayPeak(try container.decode(Int.self, forKey: .value))
        case .setDisplayMarker:
            self = .setDisplayMarker(try container.decode(Bool.self, forKey: .value))
        case .setMicGain:
            self = .setMicGain(try container.decode(Int.self, forKey: .value))
        case .setAMCLevel:
            self = .setAMCLevel(try container.decode(Int.self, forKey: .value))
        case .setVox:
            self = .setVox(try container.decode(Bool.self, forKey: .value))
        case .setVoxGain:
            self = .setVoxGain(try container.decode(Int.self, forKey: .value))
        case .setVoxDelay:
            self = .setVoxDelay(ms: try container.decode(Int.self, forKey: .value))
        case .setDNF:
            self = .setDNF(try container.decode(Bool.self, forKey: .value))
        case .setAGC:
            self = .setAGC(mode: try container.decode(Int.self, forKey: .value))
        case .setMicEQ:
            self = .setMicEQ(try container.decode(Bool.self, forKey: .value))
        case .setProcLevel:
            self = .setProcLevel(try container.decode(Int.self, forKey: .value))
        case .setNBLevel:
            self = .setNBLevel(try container.decode(Int.self, forKey: .value))
        case .setDNRLevel:
            self = .setDNRLevel(try container.decode(Int.self, forKey: .value))
        case .setAntSelect:
            self = .setAntSelect(try container.decode(Int.self, forKey: .value))
        case .setTXW:
            self = .setTXW(try container.decode(Bool.self, forKey: .value))
        case .setSquelchType:
            self = .setSquelchType(try container.decode(Int.self, forKey: .value))
        case .setToneFreq:
            self = .setToneFreq(index: try container.decode(Int.self, forKey: .value))
        case .setDCSCode:
            self = .setDCSCode(index: try container.decode(Int.self, forKey: .value))
        case .setRepeaterShift:
            self = .setRepeaterShift(mode: try container.decode(Int.self, forKey: .value))
        case .setAPRSBeaconType:
            self = .setAPRSBeaconType(try container.decode(Int.self, forKey: .value))
        case .setMenuItem:
            let payload = try container.decode(MenuItemPayload.self, forKey: .value)
            self = .setMenuItem(p1: payload.p1, p2: payload.p2, p3: payload.p3, rawValue: payload.rawValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setFrequency(let hz):
            try container.encode(CommandName.setFreq, forKey: .cmd)
            try container.encode(hz, forKey: .value)
        case .setSecondaryFrequency(let hz):
            try container.encode(CommandName.setSecondaryFreq, forKey: .cmd)
            try container.encode(hz, forKey: .value)
        case .swapActiveVFO:
            try container.encode(CommandName.swapActiveVFO, forKey: .cmd)
        case .setMode(let mode):
            try container.encode(CommandName.setMode, forKey: .cmd)
            try container.encode(mode, forKey: .value)
        case .setPTT(let on):
            try container.encode(CommandName.ptt, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setBand(let band):
            try container.encode(CommandName.setBand, forKey: .cmd)
            try container.encode(band, forKey: .value)
        case .setPowerLevel(let level):
            try container.encode(CommandName.setPower, forKey: .cmd)
            try container.encode(level, forKey: .value)
        case .setBreakIn(let on):
            try container.encode(CommandName.setBreakIn, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setKeyer(let on):
            try container.encode(CommandName.setKeyer, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setCWSpeed(let wpm):
            try container.encode(CommandName.setCWSpeed, forKey: .cmd)
            try container.encode(wpm, forKey: .value)
        case .setCWPitch(let hz):
            try container.encode(CommandName.setCWPitch, forKey: .cmd)
            try container.encode(hz, forKey: .value)
        case .setBreakInDelay(let ms):
            try container.encode(CommandName.setBreakInDelay, forKey: .cmd)
            try container.encode(ms, forKey: .value)
        case .setCWSpot(let on):
            try container.encode(CommandName.setCWSpot, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .triggerZeroIn:
            try container.encode(CommandName.triggerZeroIn, forKey: .cmd)
        case .setMoniLevel(let level):
            try container.encode(CommandName.setMoniLevel, forKey: .cmd)
            try container.encode(level, forKey: .value)
        case .selectCWMessageChannel(let channel):
            try container.encode(CommandName.selectCWMessageChannel, forKey: .cmd)
            try container.encode(channel, forKey: .value)
        case .setCWMessageRecording(let on):
            try container.encode(CommandName.setCWMessageRecording, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .playCWMessage(let channel):
            try container.encode(CommandName.playCWMessage, forKey: .cmd)
            try container.encode(channel, forKey: .value)
        case .setMox(let on):
            try container.encode(CommandName.setMox, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setAtt(let on):
            try container.encode(CommandName.setAtt, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setPreamp(let mode):
            try container.encode(CommandName.setPreamp, forKey: .cmd)
            try container.encode(mode, forKey: .value)
        case .setTuner(let on):
            try container.encode(CommandName.setTuner, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .triggerAntennaTune:
            try container.encode(CommandName.triggerAntennaTune, forKey: .cmd)
        case .setDisplayContrast(let value):
            try container.encode(CommandName.setDisplayContrast, forKey: .cmd)
            try container.encode(value, forKey: .value)
        case .setDisplayDimmer(let value):
            try container.encode(CommandName.setDisplayDimmer, forKey: .cmd)
            try container.encode(value, forKey: .value)
        case .setDisplayLevel(let value):
            try container.encode(CommandName.setDisplayLevel, forKey: .cmd)
            try container.encode(value, forKey: .value)
        case .setDisplayPeak(let value):
            try container.encode(CommandName.setDisplayPeak, forKey: .cmd)
            try container.encode(value, forKey: .value)
        case .setDisplayMarker(let on):
            try container.encode(CommandName.setDisplayMarker, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setMicGain(let value):
            try container.encode(CommandName.setMicGain, forKey: .cmd)
            try container.encode(value, forKey: .value)
        case .setAMCLevel(let value):
            try container.encode(CommandName.setAMCLevel, forKey: .cmd)
            try container.encode(value, forKey: .value)
        case .setVox(let on):
            try container.encode(CommandName.setVox, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setVoxGain(let value):
            try container.encode(CommandName.setVoxGain, forKey: .cmd)
            try container.encode(value, forKey: .value)
        case .setVoxDelay(let ms):
            try container.encode(CommandName.setVoxDelay, forKey: .cmd)
            try container.encode(ms, forKey: .value)
        case .setDNF(let on):
            try container.encode(CommandName.setDNF, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setAGC(let mode):
            try container.encode(CommandName.setAGC, forKey: .cmd)
            try container.encode(mode, forKey: .value)
        case .setMicEQ(let on):
            try container.encode(CommandName.setMicEQ, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setProcLevel(let level):
            try container.encode(CommandName.setProcLevel, forKey: .cmd)
            try container.encode(level, forKey: .value)
        case .setNBLevel(let level):
            try container.encode(CommandName.setNBLevel, forKey: .cmd)
            try container.encode(level, forKey: .value)
        case .setDNRLevel(let level):
            try container.encode(CommandName.setDNRLevel, forKey: .cmd)
            try container.encode(level, forKey: .value)
        case .setAntSelect(let mode):
            try container.encode(CommandName.setAntSelect, forKey: .cmd)
            try container.encode(mode, forKey: .value)
        case .setTXW(let on):
            try container.encode(CommandName.setTXW, forKey: .cmd)
            try container.encode(on, forKey: .value)
        case .setSquelchType(let mode):
            try container.encode(CommandName.setSquelchType, forKey: .cmd)
            try container.encode(mode, forKey: .value)
        case .setToneFreq(let index):
            try container.encode(CommandName.setToneFreq, forKey: .cmd)
            try container.encode(index, forKey: .value)
        case .setDCSCode(let index):
            try container.encode(CommandName.setDCSCode, forKey: .cmd)
            try container.encode(index, forKey: .value)
        case .setRepeaterShift(let mode):
            try container.encode(CommandName.setRepeaterShift, forKey: .cmd)
            try container.encode(mode, forKey: .value)
        case .setAPRSBeaconType(let mode):
            try container.encode(CommandName.setAPRSBeaconType, forKey: .cmd)
            try container.encode(mode, forKey: .value)
        case .setMenuItem(let p1, let p2, let p3, let rawValue):
            try container.encode(CommandName.setMenuItem, forKey: .cmd)
            try container.encode(MenuItemPayload(p1: p1, p2: p2, p3: p3, rawValue: rawValue), forKey: .value)
        }
    }
}

/// Server -> client push. Sent by the Mac hub whenever rigctld reports
/// a change, or as a full snapshot right after a client connects.
public struct RigStatePush: Codable, Sendable, Equatable {
    public let type: String  // "state" — reserved for future push types (e.g. "log", "error")
    public let state: RigState

    public init(state: RigState) {
        self.type = "state"
        self.state = state
    }
}

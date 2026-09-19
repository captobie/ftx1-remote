import Foundation

/// Serializes RigCommands into rigctld calls, one at a time.
///
/// rigctld handles one request/response cycle at a time over its TCP
/// connection — this queue exists so that, e.g., a fast VFO drag on the
/// Mac UI or a burst of commands from a mobile client can't interleave
/// or race against each other. Runs only on the Mac hub.
public actor CommandQueue {
    private let rigctld: RigctldClient
    private var isProcessing = false
    private var pending: [(command: RigCommand, filterSide: FilterSide?)] = []
    /// The receiver the filter commands (`SH`/`IS`/`BP`/`CO`/`NA`) address,
    /// updated when a `.setFilterSide` is applied. Held here rather than
    /// passed per command so the filter commands stay wire-compatible, and
    /// safe because this queue is strictly FIFO: a switch followed
    /// immediately by a control change is always applied in that order.
    private var filterSide: FilterSide = .main
    /// A one-command override of `filterSide`, set while a command enqueued
    /// with an explicit side is being applied (see `enqueue(_:filterSide:)`).
    private var filterSideOverride: FilterSide?

    /// The receiver the command being applied addresses: its explicit
    /// override if it had one, otherwise the queue's selected side.
    private var targetSide: FilterSide { filterSideOverride ?? filterSide }

    /// Called after each command completes, with the freshest rig state
    /// (however the caller chooses to derive it — e.g. by re-querying
    /// rigctld or applying the command optimistically). Wiring this up
    /// to a broadcast-to-WebSocket-clients step happens at the app layer.
    /// The second argument is the receiver the command was applied to (the
    /// filter commands address a side; for everything else it's just the
    /// queue's current selection and can be ignored) — the app layer uses
    /// it so an explicitly-MAIN command can't overwrite the selected
    /// side's optimistic filter values.
    public var onCommandApplied: (@Sendable (RigCommand, FilterSide) -> Void)?

    public init(rigctld: RigctldClient) {
        self.rigctld = rigctld
    }

    public func setOnCommandApplied(_ handler: @escaping @Sendable (RigCommand, FilterSide) -> Void) {
        onCommandApplied = handler
    }

    /// `filterSide` pins one filter command to a receiver regardless of the
    /// queue's selected side — e.g. the band-memory width replay after a
    /// band change, which always retunes MAIN even while SUB is selected.
    /// nil (the default) uses the selected side.
    public func enqueue(_ command: RigCommand, filterSide: FilterSide? = nil) {
        pending.append((command, filterSide))
        if !isProcessing {
            Task { await drain() }
        }
    }

    private func drain() async {
        isProcessing = true
        while !pending.isEmpty {
            let (command, override) = pending.removeFirst()
            filterSideOverride = override
            do {
                try await apply(command)
                onCommandApplied?(command, targetSide)
                filterSideOverride = nil
            } catch {
                filterSideOverride = nil
                // TODO: surface command failures to the app layer (e.g. via
                // a dedicated error callback) rather than dropping silently.
            }
        }
        isProcessing = false
    }

    /// rigctld runs with `-o` (see `RigctldProcessController`), which
    /// requires every set command to name an explicit VFO rather than
    /// defaulting to the active one — "currVFO" is rigctld's keyword for
    /// that default, kept here to match `RigctldClient`'s get-side calls.
    private static let currentVFOArg = "currVFO"

    private func apply(_ command: RigCommand) async throws {
        switch command {
        case .setFrequency(let hz):
            _ = try await rigctld.send("F \(Self.currentVFOArg) \(hz)")
        case .setSecondaryFrequency(let hz):
            try await rigctld.setSecondaryFrequency(hz)
        case .swapActiveVFO:
            try await rigctld.swapActiveVFO()
        case .setMode(let mode):
            // Real C4FM has no hamlib-vocabulary raw value to send through
            // the generic "M" verb here — see RigMode.c4fm/RigMode.dataFM
            // and RigctldClient.setActiveModeC4FM() for why.
            if mode == .c4fm {
                try await rigctld.setActiveModeC4FM()
            } else {
                // Passband "-1" is hamlib's RIG_PASSBAND_NOCHANGE: newcat's
                // set_mode sends "MD" and returns without touching the
                // width. The previous "0" (RIG_PASSBAND_NORMAL) made hamlib
                // follow the mode change with an explicit width set to its
                // own idea of "normal" for that mode — the first entry in
                // the backend's filter list, which for CW/RTTY/DATA modes
                // is 500 Hz. Hardware-observed 2026-09-13: FM → DATA-U came
                // back at 500 Hz instead of the 2400 Hz the operator had
                // been using, because hamlib overwrote the rig's own
                // per-mode last-used width. With -1 the rig restores its
                // own remembered width, matching the front panel.
                _ = try await rigctld.send("M \(Self.currentVFOArg) \(mode.rawValue) -1")
            }
        case .setPTT(let on):
            _ = try await rigctld.send("T \(Self.currentVFOArg) \(on ? 1 : 0)")
        case .setBand(let band):
            // rigctld has no "set band" verb, so this is normally translated
            // into a .setFrequency by HubService (see its send(_:)) before
            // it ever reaches this queue — this case only exists because
            // RigCommand's switch must stay exhaustive. If it does arrive
            // here unresolved, there's no meaningful rigctld call to make.
            _ = band
        case .setPowerLevel(let level):
            _ = try await rigctld.send("L \(Self.currentVFOArg) RFPOWER \(String(format: "%.3f", level))")
        case .setBreakIn(let on):
            try await rigctld.setRawBool("BI", on)
        case .setKeyer(let on):
            try await rigctld.setRawBool("KR", on)
        case .setCWSpeed(let wpm):
            try await rigctld.setRawInt("KS", wpm, digits: 3)
        case .setCWPitch(let hz):
            // The FTX-1's "KP" CAT command encodes pitch as steps of 10Hz
            // above a 300Hz floor (00-75), not Hz directly — see the CAT
            // Operation Reference Manual and RigState.cwPitchHz.
            try await rigctld.setRawInt("KP", (hz - 300) / 10, digits: 2)
        case .setBreakInDelay(let ms):
            // The FTX-1's "SD" CAT command encodes delay as a non-linear
            // 00-33 code, not milliseconds directly — see RigDelayCode.
            guard let code = RigDelayCode.code(forMilliseconds: ms) else { return }
            try await rigctld.setRawInt("SD", code, digits: 2)
        case .setCWSpot(let on):
            try await rigctld.setRawBool("CS", on)
        case .triggerZeroIn:
            // "ZI" takes a Main/Sub selector (0/1), not an on/off state,
            // and documents no reply — always targets Main, matching every
            // other raw menu command's single-VFO-focus assumption.
            try await rigctld.sendRawFireAndForget("ZI0")
        case .setMoniLevel(let level):
            // "ML" carries both MONI on/off and MONI level under the same
            // mnemonic, distinguished by a P1 sub-selector baked into the
            // command text itself ("ML0..." for on/off, "ML1..." for
            // level) — see RigState.moniLevel.
            try await rigctld.setRawInt("ML1", level, digits: 3)
        case .selectCWMessageChannel(let channel):
            // "LM" (LOAD MESSAGE) packs channel-select and record start/
            // stop under one mnemonic via a P1 sub-selector, just like "ML"
            // does for MONI on/off vs level — P1=0 is the message-select
            // branch, whose P2 is which channel (1-5) becomes "active" for
            // setCWMessageRecording and the rig's own MESSAGE button.
            try await rigctld.setRawInt("LM0", channel, digits: 1)
        case .setCWMessageRecording(let on):
            // P1=1 is "LM"'s record branch — starts/stops recording into
            // whichever channel selectCWMessageChannel last selected.
            try await rigctld.setRawBool("LM1", on)
        case .playCWMessage(let channel):
            // "KY" (CW KEYING MEMORY PLAY) P1 fixed to 1 (CW MESSAGE
            // Memory, as opposed to 0 for CW TEXT Memory, which this app
            // doesn't expose) — P2 is 0 to stop or 1-5 to start playing
            // that channel.
            try await rigctld.setRawInt("KY1", channel, digits: 1)
        case .setMox(let on):
            try await rigctld.setRawBool("MX", on)
        case .setAtt(let on):
            // "RA"'s P1 is documented as always "0" (not a band selector,
            // unlike "PA"'s below) — baked into the mnemonic like "ML1"/
            // "LM0" above.
            try await rigctld.setRawBool("RA0", on)
        case .setPreamp(let mode):
            // "PA" P1 selects HF/50 vs VHF vs UHF; fixed to 0 (HF/50) here —
            // see RigState.preampMode. P2 is then a 3-way IPO/AMP1/AMP2
            // selector, not a boolean, so this uses setRawInt like moniLevel.
            try await rigctld.setRawInt("PA0", mode, digits: 1)
        case .setTuner(let on):
            // "AC" (ANTENNA TUNER CONTROL) takes three params (P1: internal/
            // external tuner, P2: Antenna-Tuner-mode vs ATAS, P3: on/off).
            // The manual labels P1=0 "Internal Antenna Tuner (FTX-1
            // optima)" — but on this user's real FTX-1 Optima (which does
            // have the internal tuner), P1=0 silently did nothing, while
            // P1=1 ("External Antenna Tuner") is what actually works.
            // Confirmed against real hardware, not merely inferred from the
            // manual text — don't "fix" this back to P1=0 without
            // retesting. P2 fixed to 0 (Antenna-Tuner mode, not ATAS,
            // matching this rig's TUNER SELECT="OPTION" rather than
            // "ATAS"). Baked into the mnemonic like "RA0"/"ML1"/"LM0"
            // above. Its Read command has no params at all though, so the
            // get side can't reuse this same "AC10" prefix — see
            // RigctldClient.getTunerEnabled().
            try await rigctld.setRawBool("AC10", on)
        case .triggerAntennaTune:
            // Same "AC" command as .setTuner, P3=3 ("Tuning Start") instead
            // of an on/off value — momentary, like .triggerZeroIn above, so
            // fire-and-forget rather than setRawBool/setRawInt.
            try await rigctld.sendRawFireAndForget("AC103")
        case .setDisplayContrast(let value):
            // "DA" sets contrast/brightness/LED-brightness together in one
            // command — read the current triple first so the other two
            // fields aren't clobbered back to whatever this fallback
            // defaults to. Matches the physical MENU button's own behavior
            // (adjusting one item leaves the others alone).
            let current = try? await rigctld.getDisplaySettings()
            try await rigctld.setDisplaySettings(
                contrast: value,
                brightness: current?.brightness ?? 10,
                ledBrightness: current?.ledBrightness ?? 10
            )
        case .setDisplayDimmer(let value):
            let current = try? await rigctld.getDisplaySettings()
            try await rigctld.setDisplaySettings(
                contrast: current?.contrast ?? 10,
                brightness: value,
                ledBrightness: current?.ledBrightness ?? 10
            )
        case .setDisplayLevel(let dB):
            try await rigctld.setSpectrumScopeLevel(dB)
        case .setDisplayPeak(let level):
            // "SS"'s PEAK sub-function packs P3 (the value) ahead of P4-P7,
            // which the manual documents as always "0" — see
            // RigctldClient.setRawPackedDigit(_:_:trailingZeros:).
            try await rigctld.setRawPackedDigit("SS01", level, trailingZeros: 4)
        case .setDisplayMarker(let on):
            try await rigctld.setRawPackedDigit("SS02", on ? 1 : 0, trailingZeros: 4)
        case .setMicGain(let value):
            try await rigctld.setRawInt("MG", value, digits: 3)
        case .setAMCLevel(let value):
            try await rigctld.setRawInt("AO", value, digits: 3)
        case .setVox(let on):
            try await rigctld.setRawBool("VX", on)
        case .setVoxGain(let value):
            try await rigctld.setRawInt("VG", value, digits: 3)
        case .setVoxDelay(let ms):
            // Same non-linear 00-33 code as "SD" (see .setBreakInDelay) —
            // see RigDelayCode's doc comment for the manual's inconsistent
            // step-size note between the two commands.
            guard let code = RigDelayCode.code(forMilliseconds: ms) else { return }
            try await rigctld.setRawInt("VD", code, digits: 2)
        case .setDNF(let on):
            // "BC"'s P1 is fixed to "0" (MAIN-side), baked into the
            // mnemonic like "RA0"/"ML1"/"PA0" above.
            try await rigctld.setRawBool("BC0", on)
        case .setAGC(let mode):
            // "GT"'s P1 is fixed to "0" (MAIN-side); P2 is the 0-4
            // OFF/FAST/MID/SLOW/AUTO selector, not a boolean, so this uses
            // setRawInt like .setPreamp.
            try await rigctld.setRawInt("GT0", mode, digits: 1)
        case .setMicEQ(let on):
            // "PR"'s P1 is fixed to "1" (Parametric Microphone Equalizer,
            // not the separate Speech Processor master on/off at P1=0). The
            // manual documents its own P2 as 1: OFF, 2: ON — confirmed
            // against real hardware to be flat wrong, not just backwards: a
            // live nc probe read the real rig's current P2 back as "0", a
            // value the manual doesn't even list as valid, and toggling
            // between "PR10;"/"PR11;" (confirmed against the rig's own
            // display after each write) showed plain 0/1 is the real
            // encoding — same boolean shape as "BI"/"KR"/"CS"/"MX" etc.
            // Plain setRawBool now, not the special-cased setRawInt this
            // used briefly while chasing the wrong "backwards 1/2" theory.
            try await rigctld.setRawBool("PR1", on)
        case .setProcLevel(let level):
            try await rigctld.setRawInt("PL", level, digits: 3)
        case .setNBLevel(let level):
            // "NL"'s P1 is fixed to "0" (MAIN-side), same shape as "RA0"/
            // "BC0" above.
            try await rigctld.setRawInt("NL0", level, digits: 3)
        case .setDNRLevel(let level):
            // "RL"'s P1 is fixed to "0" (MAIN-side), same shape as "NL0"
            // above but a 2-digit field rather than 3.
            try await rigctld.setRawInt("RL0", level, digits: 2)
        case .setFilterWidth(let index):
            // "SH"'s P1 is the selected filter side (`filterSide`: "0" MAIN,
            // "1" SUB); P2 is fixed to "0", baked into the prefix
            // alongside P1 rather than sent
            // separately — since P3 (the value we're actually setting) is
            // always 0-23, zero-padding it to the combined P2+P3 field
            // width (3 digits) always reproduces P2="0" as the leading
            // digit for free, same trick `getRawInt`'s prefix-stripping
            // parse relies on for the read side below.
            try await rigctld.setRawInt("SH\(targetSide.p1)", index, digits: 3)
        case .setFilterSide(let side):
            // No CAT traffic: just retargets the filter commands below (and
            // the hub's filter reads) at the other receiver.
            filterSide = side
        case .setIFShift(let hz):
            // "IS" carries a sign character before its 4-digit magnitude,
            // which setRawInt's plain zero-padding can't produce — a
            // dedicated helper handles the "IS<side>0±dddd" shape. Snapped here
            // (not just in the UI) so a remote client can't send a value
            // off the 20 Hz grid or outside ±1200.
            try await rigctld.setIFShiftHz(IFShift.snapped(hz), side: targetSide)
        case .setNotch(let on):
            // "BP"'s on/off sub-function (P2=0, baked into the "BP<side>0"
            // prefix after the selected side's P1) is a 3-digit 000/001 field per
            // the manual, not the single-digit boolean setRawBool writes
            // ("BP001" wouldn't match the documented width) — so it goes
            // through setRawInt with the field width, same as its
            // frequency sibling below.
            try await rigctld.setRawInt("BP\(targetSide.p1)0", on ? 1 : 0, digits: 3)
        case .setNotchFrequency(let hz):
            // "BP"'s frequency sub-function (P2=1) takes a 3-digit code of
            // 10 Hz units (001-320), not Hz. Snapped here too so a remote
            // client can't send an off-grid or out-of-range value.
            try await rigctld.setRawInt("BP\(targetSide.p1)1", IFNotch.code(forHz: hz), digits: 3)
        case .setContour(let on):
            // "CO"'s four sub-functions (P2 baked into the "CO<side>x" prefix)
            // are all 4-digit fields, on/off included (0000/0001) — same
            // multi-digit-boolean shape as "BP" above, so setRawInt with
            // the field width rather than setRawBool.
            try await rigctld.setRawInt("CO\(targetSide.p1)0", on ? 1 : 0, digits: 4)
        case .setContourFrequency(let hz):
            // "CO01" carries Hz directly as 4 digits (0010-3200).
            try await rigctld.setRawInt("CO\(targetSide.p1)1", IFContour.snappedContourHz(hz), digits: 4)
        case .setAPF(let on):
            try await rigctld.setRawInt("CO\(targetSide.p1)2", on ? 1 : 0, digits: 4)
        case .setAPFOffset(let hz):
            // "CO03" is a 4-digit code 0000-0050 for −250…+250 Hz, not Hz.
            try await rigctld.setRawInt("CO\(targetSide.p1)3", IFContour.apfCode(forHz: hz), digits: 4)
        case .setNarrow(let on):
            // "NA"'s P1 is the selected filter side; P2 is a plain
            // single-digit boolean, same shape as "BC0" — no multi-digit
            // field here, unlike "BP"/"CO" above.
            try await rigctld.setRawBool("NA\(targetSide.p1)", on)
        case .setAntSelect(let mode):
            // No dedicated mnemonic for this one — it's Table 3's "HF ANT
            // SELECT" (OPERATION SETTING / OPTION / p3=4), a single digit
            // (0/1) with no zero-padding needed. Reuses the generic "EX"
            // passthrough `.setMenuItem` uses under the hood, just for this
            // one fixed address rather than an arbitrary Deep Settings item.
            try await rigctld.setMenuItem(p1: 3, p2: 7, p3: 4, rawValue: "\(mode)")
        case .setTXW(let on):
            // "TS" has no MAIN/SUB P1 selector at all — a bare boolean like
            // "MX"/"VX", not baked into a fixed-P1 mnemonic like most of the
            // toggles above.
            try await rigctld.setRawBool("TS", on)
        case .setSquelchType(let mode):
            // "CT"'s P1 is fixed to "0" (MAIN-side); P2 is the 0-5
            // OFF/ENC/TSQ/DCS/PR FREQ/REV TONE selector, so this uses
            // setRawInt like .setAGC.
            try await rigctld.setRawInt("CT0", mode, digits: 1)
        case .setToneFreq(let index):
            // "CN"'s P1 is fixed to "0" (MAIN-side), P2 fixed to "0"
            // (CTCSS sub-function); P3 is the 3-digit index into
            // RigCTCSSTone.allValuesHz, not the Hz value itself.
            try await rigctld.setRawInt("CN00", index, digits: 3)
        case .setDCSCode(let index):
            // Same "CN" command as .setToneFreq, P2 fixed to "1" (DCS
            // sub-function) instead of "0"; P3 is the 3-digit index into
            // RigDCSCode.allValues.
            try await rigctld.setRawInt("CN01", index, digits: 3)
        case .setRepeaterShift(let mode):
            // "OS"'s P1 is fixed to "0" (MAIN-side); P2 is the 0-3
            // Simplex/Plus/Minus/ARS selector, so this uses setRawInt like
            // .setSquelchType.
            try await rigctld.setRawInt("OS0", mode, digits: 1)
        case .setAPRSBeaconType(let mode):
            // No dedicated mnemonic — it's Table 3's "BEACON TYPE" (APRS
            // BEACON / BEACON SET. / p3=1), a single digit (0-2) with no
            // zero-padding needed. Reuses the generic "EX" passthrough
            // `.setMenuItem` uses under the hood, same as `.setAntSelect`.
            try await rigctld.setMenuItem(p1: 7, p2: 1, p3: 1, rawValue: "\(mode)")
        case .setFMChannelStep(let step):
            // No dedicated mnemonic — it's Table 3's "FM CH STEP" (OPERATION
            // SETTING / KEY/DIAL / p3=6), same generic "EX" passthrough
            // reasoning as `.setAPRSBeaconType`.
            try await rigctld.setMenuItem(p1: 3, p2: 6, p3: 6, rawValue: "\(step)")
        case .setMenuItem(let p1, let p2, let p3, let rawValue):
            try await rigctld.setMenuItem(p1: p1, p2: p2, p3: p3, rawValue: rawValue)
        case .setVFOMemoryMode(let memory):
            // "VM"'s P1 is fixed to "0" (MAIN-side), baked into the mnemonic
            // like "RA0"/"GT0" above; P2 is 00=VFO or 11=Memory (see
            // RigState.VFOMemoryMode) — a plain fixed-width int, so this
            // reuses setRawInt directly rather than a bespoke method.
            //
            // Confirmed via live `nc` probing against real hardware (not
            // documented anywhere in the manual): switching to Memory mode
            // via a bare "VM011" silently fails unless a memory channel is
            // already "selected" — "MC0" (which channel the rig is
            // currently tracking) is readable at any time, even while in
            // VFO mode, but the mode switch only takes effect if "MC0" is
            // (re-)written immediately beforehand, even back to the exact
            // value it already held. Switching to VFO mode has no such
            // precondition. Re-assert whatever channel is currently
            // tracked (defaulting to channel 1 if none has ever been
            // selected) right before the mode switch to satisfy this.
            //
            // Switching back to VFO has its own wrinkle, handled one layer
            // up in `HubService.send(_:)` rather than here: "VM000" alone
            // flips the mode flag but — driven from this app, though not
            // from the front panel — leaves the Main-side frequency/mode
            // parked on the memory channel's values. The hub follows this
            // command with explicit `.setFrequency`/`.setMode` of the last
            // VFO state it saw; see `HubService.lastVFOState`.
            if memory {
                let currentChannel = (try? await rigctld.getRawInt("MC0")) ?? 1
                try await rigctld.setRawInt("MC0", currentChannel, digits: 5)
            }
            try await rigctld.setRawInt("VM0", memory ? 11 : 0, digits: 2)
        case .setMemoryChannel(let channel):
            // "MC"'s P1 is fixed to "0" (MAIN-side); P2 is the 5-digit
            // channel number.
            try await rigctld.setRawInt("MC0", channel, digits: 5)
        case .stepMemoryChannel(let up):
            // "CH" (CHANNEL UP/DOWN) documents no MAIN/SUB P1 selector at
            // all, unlike every other raw command here — unverified against
            // real hardware which side this actually affects (see
            // RigCommand.stepMemoryChannel's doc comment). Momentary, like
            // .triggerZeroIn/.triggerAntennaTune above, so fire-and-forget.
            // If hardware testing shows this targets the wrong side, replace
            // this with a read-modify-write via "MC0" instead (read the
            // current channel, clamp ±1, setRawInt("MC0", ..., digits: 5)).
            try await rigctld.sendRawFireAndForget(up ? "CH0" : "CH1")
        }
    }
}

import SwiftUI

/// Which of the FTX-1's three physical menu pages (accessed via a long-press
/// of the rig's MENU button, cycling 1/3 → 2/3 → 3/3) a button belongs to.
/// Grouped by mode family rather than by number, matching how the radio
/// itself organizes them.
enum MenuPage: String, CaseIterable, Identifiable {
    case ssb = "SSB"
    case cw = "CW"
    case fm = "FM/C4FM"

    var id: String { rawValue }

    /// The page's position among the rig's three physical menu pages, as
    /// shown on its own display (e.g. "PAGE 1/3").
    var pageNumber: Int {
        switch self {
        case .ssb: 1
        case .cw: 2
        case .fm: 3
        }
    }

    /// The previous/next page in the rig's own cycle (1/3 → 2/3 → 3/3 →
    /// wraps back to 1/3), used by each page's shared left/right nav
    /// buttons (item 22 / item 28).
    var previous: MenuPage {
        let cases = Self.allCases
        let index = cases.firstIndex(of: self)!
        return cases[(index - 1 + cases.count) % cases.count]
    }

    var next: MenuPage {
        let cases = Self.allCases
        let index = cases.firstIndex(of: self)!
        return cases[(index + 1) % cases.count]
    }
}

/// Matches the rig's own page size — each physical menu page holds up to 28
/// items. File-scope rather than a stored `static let` on `MenuPageView`
/// itself — Swift doesn't allow stored static properties on generic types.
private let menuPageItemsPerPage = 28
private let menuPageColumns = 7

/// CW page item numbers with no corresponding rig function — confirmed
/// against the real MENU display, not just "not yet wired." Rendered as
/// invisible (not just unlabeled) placeholders so they don't get mistaken
/// for still-pending work, while keeping the grid's row alignment intact.
private let menuPageHiddenCWItems: Set<Int> = [3, 4, 5, 6, 7, 15, 16, 17, 18, 23, 24, 25, 26, 27]

/// FM/C4FM page item numbers with no corresponding rig function — confirmed
/// against the real MENU display, same reasoning as `menuPageHiddenCWItems`.
private let menuPageHiddenFMItems: Set<Int> = [4, 5, 16, 17]

/// Grid of buttons mirroring one of the FTX-1's three menu pages. Layout
/// only for now — each button is a numbered placeholder; actual per-item
/// functions (which menu number maps to which CAT command) land once the
/// layout itself is confirmed against the real rig.
///
/// Generic over `RigController` so it can be embedded against either the
/// Mac's `HubService` (talks to rigctld directly) or a mobile client's
/// `RigClientViewModel` (talks over WebSocket) without duplicating this
/// file — see `RigController`.
public struct MenuPageView<Controller: RigController>: View {
    @EnvironmentObject private var hub: Controller
    /// Opens the `aprs-stations`/`aprs-messages` `Window` scenes S.LIST/
    /// M.LIST use (see `aprsListButton`) — a standard cross-platform
    /// SwiftUI environment action. Only the Mac app declares those window
    /// IDs; calling it on mobile would be a no-op anyway, but that never
    /// happens in practice since `hub.supportsAPRSDecoding` gates the
    /// button itself first.
    @Environment(\.openWindow) private var openWindow
    @State private var selectedPage: MenuPage = .ssb
    /// Read via `@AppStorage`, not `AppearanceSettings.buttonValueColor`
    /// directly — a plain `UserDefaults` read gives SwiftUI nothing to
    /// track, so this view wouldn't re-render when the setting changes in
    /// `SettingsView`'s Appearance tab. `@AppStorage` ties the read to the
    /// same key and invalidates this view on change.
    @AppStorage(AppearanceSettings.buttonValueColorKey) private var buttonValueColorRawValue = ButtonValueColor.orange.rawValue
    @State private var showingCWSpeedPopover = false
    @State private var showingCWPitchPopover = false
    @State private var showingBKDelayPopover = false
    @State private var showingMoniLevelPopover = false
    @State private var showingDisplayContrastPopover = false
    @State private var showingDisplayDimmerPopover = false
    @State private var showingDisplayLevelPopover = false
    @State private var showingRFPowerPopover = false
    @State private var isDraggingRFPower = false
    @State private var localRFPowerLevel: Double = 0
    @State private var showingMicGainPopover = false
    @State private var showingAMCLevelPopover = false
    @State private var showingVoxGainPopover = false
    @State private var showingVoxDelayPopover = false
    @State private var showingProcLevelPopover = false
    @State private var showingNBLevelPopover = false
    @State private var showingDNRLevelPopover = false
    @State private var showingToneFreqPopover = false
    @State private var showingDCSPopover = false
    @State private var activeDeepSettings: ActiveDeepSettings?

    /// Identifies which Deep Settings screen (see `DeepSettingsView`) is
    /// presented as a sheet — FM/C4FM page buttons 23-28, the rig's own
    /// page-3 bottom row (Radio/CW/Operation/Display/Extension/APRS
    /// Setting). `title` doubles as the id since these six are fixed and
    /// distinct.
    private struct ActiveDeepSettings: Identifiable {
        let title: String
        let p1s: [Int]
        var id: String { title }
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Menu page", selection: $selectedPage) {
                ForEach(MenuPage.allCases) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: menuPageColumns),
                spacing: 6
            ) {
                ForEach(1...menuPageItemsPerPage, id: \.self) { item in
                    menuButton(for: item)
                }
            }
        }
        .sheet(item: $activeDeepSettings) { destination in
            hub.deepSettingsDestination(title: destination.title, p1s: destination.p1s)
        }
    }

    /// Button 1 on every page is the rig's own page-select button (pressing
    /// it on the real MENU display cycles 1/3 → 2/3 → 3/3), so it gets a
    /// two-line "PAGE n/3" / mode-name label instead of a plain number.
    /// Buttons 22 and 28 are left/right nav to the previous/next page in
    /// that cycle, shared by whichever pages don't repurpose the slot:
    /// SSB has its own RF POWER at 22 (`RigCommand.setPowerLevel`, popover
    /// `Slider` rather than a `Stepper` — see `rfPowerButton`), so nav-left
    /// only shows on CW/FM; FM/C4FM has its own APRS SETTING at 28, so
    /// nav-right only shows on SSB/CW.
    /// SSB button 2 is spectrum scope display level (`RigCommand.
    /// setDisplayLevel`, popover `Stepper`, -30.0 to +30.0 dB), button 3 is
    /// peak-hold level (`RigCommand.setDisplayPeak`, single-tap cycling
    /// LV1-LV5 like IPO/AMP), button 4 is the marker on/off (`RigCommand.
    /// setDisplayMarker`, single-tap toggle) — all three share the FTX-1's
    /// raw "SS" (SPECTRUM SCOPE) CAT command, addressed at different P2
    /// sub-functions.
    /// SSB button 6 is TFT display contrast (`RigCommand.
    /// setDisplayContrast`), button 7 is TFT backlight dimmer
    /// (`RigCommand.setDisplayDimmer`) — both popover `Stepper`s like CW
    /// SPEED/PITCH, sharing the FTX-1's raw "DA" command (see
    /// `RigctldClient.getDisplaySettings()`). Button 5, D-COLOR, has no
    /// known CAT command (checked the full manual, including the numbered
    /// `EX` menu chart) — shown visible-but-disabled via
    /// `disabledPlaceholderButton` rather than a plain numbered placeholder,
    /// so its real label is on the grid even though it's not wired yet.
    /// SSB button 8 is MOX (`RigCommand.setMox`), button 9 is the RF
    /// attenuator (`RigCommand.setAtt`), button 10 is the HF/50 preamp/IPO
    /// selector (`RigCommand.setPreamp`, cycling IPO/AMP1/AMP2 per tap),
    /// button 11 is auto notch/DNF (`RigCommand.setDNF`, single-tap toggle
    /// like MOX/ATT, raw "BC" command with fixed MAIN-side P1), button 12
    /// is AGC (`RigCommand.setAGC`, single-tap-cycles-to-next like IPO/AMP,
    /// raw "GT" command — its Set side only accepts P2 0-4 (OFF/FAST/MID/
    /// SLOW/AUTO), but its Read side's Answer can report P3 up to 6
    /// (AUTO-MID/AUTO-SLOW, sub-states AGC settles into while in AUTO), so
    /// the displayed label and the tap-to-cycle logic both collapse 4-6 to
    /// plain "AUTO" — see `agcLabel(_:)`/`agcCollapsedMode(_:)`). Button 13
    /// is MIC EQ (`RigCommand.setMicEQ`, single-tap toggle like MOX/ATT,
    /// raw "PR" command with fixed P1=1 for the Parametric Microphone
    /// Equalizer — its own P2 is 1/2 for OFF/ON rather than the usual 0/1,
    /// decoded/encoded in `HubService`/`CommandQueue`, not exposed as a
    /// quirk to this view), button 14 is PROC LEVEL (`RigCommand.
    /// setProcLevel`, popover `Stepper` like MIC GAIN, 0-100, raw "PL"
    /// command — 0 reads "OFF" per the manual, same convention as MONI
    /// LEVEL, see `procLevelLabel(_:)`). Button 15
    /// is antenna tuning (`RigCommand.triggerAntennaTune`,
    /// single-tap momentary action like CW page's ZIN), button 16 is the
    /// antenna tuner on/off (`RigCommand.setTuner`, single-tap toggle like
    /// MOX/ATT). Button 17 has no rig function on this page — confirmed
    /// against the real MENU display, same reasoning as `hiddenCWItems`
    /// below — and renders invisibly via `hiddenButtonPlaceholder`. Button
    /// 18 is NB (`RigCommand.setNBLevel`, popover `Stepper` like MONI LEVEL/
    /// PROC LEVEL, 0-10, raw "NL" NOISE BLANKER LEVEL command with fixed
    /// MAIN-side P1 — 0 reads "OFF" per the manual, same convention as those
    /// two, see `nbLevelLabel(_:)`), button 19 is DNR (`RigCommand.
    /// setDNRLevel`, same popover-`Stepper` treatment, raw "RL" NOISE
    /// REDUCTION LEVEL command, also fixed-P1/0-10/0-is-OFF, see
    /// `dnrLevelLabel(_:)`). Button 20 is ANT (`RigCommand.setAntSelect`,
    /// single-tap toggle like IPO/AMP rather than a popover, cycling ANT1/
    /// ANT2) — unlike every other numbered-grid button, this has no
    /// dedicated 2-letter mnemonic at all; it's Table 3's "HF ANT SELECT"
    /// item (`DeepSettingsCatalog`'s OPERATION SETTING / OPTION / p3=4),
    /// reusing the generic "EX" `RigCommand.setMenuItem`/`RigctldClient.
    /// getMenuItem` passthrough Deep Settings uses, just for this one fixed
    /// address rather than the on-demand per-item read `DeepSettingsView`
    /// needs — `HubService`'s regular poll loop reads it like every other
    /// field here, so this doesn't need the wire-protocol request/response
    /// addition that gates Deep Settings on mobile (see the Architecture
    /// note in CLAUDE.md). Button 21 is TXW (`RigCommand.setTXW`, raw "TS"
    /// command — unlike most booleans here, "TS" has no MAIN/SUB P1
    /// selector at all, just a bare digit) — hardware-confirmed working,
    /// but visible-but-disabled via `disabledTXWButton` since the user
    /// doesn't know what it does or use it, same deprioritized treatment as
    /// CW MESSAGE/PLAY/RECORD below. NB/DNR/ANT are hardware-confirmed
    /// working too.
    /// Button 23 is mic gain (`RigCommand.setMicGain`, popover `Stepper` like CW
    /// SPEED/PITCH, mapping to the FTX-1's raw "MG" command, 0-100), button
    /// 24 is AMC level (`RigCommand.setAMCLevel`, same popover-`Stepper`
    /// treatment, raw "AO" command, 1-100) — AMC (Automatic Mic Compressor)
    /// is this rig's speech-compression output level. Button 25 is VOX
    /// on/off (`RigCommand.setVox`, single-tap toggle like MOX/ATT, raw "VX"
    /// command), button 26 is VOX gain (`RigCommand.setVoxGain`, popover
    /// `Stepper` like MIC GAIN, raw "VG" command, 0-100), button 27 is VOX
    /// delay (`RigCommand.setVoxDelay`, popover `Stepper` like BK-DELAY,
    /// stepping through `RigDelayCode`'s 0-33 code range rather than
    /// milliseconds directly, raw "VD" command — confirmed against real
    /// hardware to share BK-DELAY's 100ms-step encoding despite the
    /// manual's inconsistent step-size note, see `RigDelayCode`).
    /// CW button 2 is monitor level (`RigCommand.setMoniLevel`), button 8
    /// is the electronic keyer (`RigCommand.setKeyer`), button 9 is
    /// break-in (`RigCommand.setBreakIn`), button 10 is keyer speed
    /// (`RigCommand.setCWSpeed`), button 11 is CW pitch
    /// (`RigCommand.setCWPitch`), button 12 is break-in delay
    /// (`RigCommand.setBreakInDelay`), button 13 is zero-in
    /// (`RigCommand.triggerZeroIn`), button 14 is CW spot
    /// (`RigCommand.setCWSpot`). Buttons 19-21 (MESSAGE/PLAY/RECORD, the CW
    /// MESSAGE memory) are visible-but-disabled — see
    /// `disabledCWMessageButton`. `hiddenCWItems` (3-7, 15-18, 23-27) have
    /// no rig function at all on this page and render invisibly — see
    /// `hiddenButtonPlaceholder`. FM/C4FM buttons 8-10 (DG-ID TX, DG-ID RX,
    /// HRI MODE) are visible-but-disabled like SSB's D-COLOR/TXW — unlike
    /// every other menu item wired so far, these have **no CAT command
    /// documented anywhere**: not the alphabetical command list, not
    /// Table 3's MENU chart (RADIO SETTING's DIGITAL tab only has DIGITAL
    /// POPUP/LOCATION SERVICE/STANDBY BEEP/DP-ID LIST/RADIO ID), not even
    /// Yaesu's separate FTX-1 WIRES-X Edition manual (which describes these
    /// as touchscreen/FUNC-knob-only settings), and hamlib's own Yaesu
    /// backend source has no DGID/HRI token either. Same "manual can be
    /// missing whole features" gap already confirmed for RADIO SETTING's
    /// WIRES-X tab (see `DeepSettingsCatalog.swift`) — DG-ID/HRI MODE are
    /// WIRES-X-adjacent settings, not just unread by this app yet. FM/C4FM
    /// items 4, 5, 16, and 17 have no rig function at all on this page,
    /// confirmed against the real MENU display — `menuPageHiddenFMItems`,
    /// same treatment as `menuPageHiddenCWItems`. FM/C4FM button 2 is DTMF
    /// (`dtmfButton`) — a placeholder like S.LIST/M.LIST/BCN-TX (opens an
    /// on-rig entry screen this app can't drive over CAT, and would be
    /// TX-triggering to guess at), but styled as a single centered word via
    /// `singleWordButton` rather than `disabledPlaceholderButtonEqualSize`'s
    /// two-word pair, since the real button only shows one word. Button 3 is
    /// T-CALL (1750Hz tone-burst repeater access, per the user) — a normal
    /// `disabledPlaceholderButton` (name+"—" pair) since it's a real on/off
    /// toggle on the rig's own display, just with no CAT command anywhere
    /// for it (checked the alphabetical list, Table 3, and hamlib source).
    /// FM/C4FM button 6 is RPT
    /// SHIFT (`RigCommand.setRepeaterShift`, single-tap-cycles-to-next like
    /// IPO/AMP/AGC over 4 values, raw "OS" CAT command with fixed MAIN-side
    /// P1). Button 7, REV (repeater reverse), is visible-but-disabled like
    /// DG-ID TX/RX/HRI MODE above — same "nothing documented anywhere"
    /// result: no mnemonic in the alphabetical command list, no Table 3
    /// entry, no hamlib token. Buttons 11/12, APRS S.LIST/M.LIST
    /// (`aprsListButton`, since "APRS"/"S.LIST"-"M.LIST" is a two-word
    /// label pair like the Deep Settings buttons, not a name/value pair) —
    /// on-rig, these are pure on-screen UI with no CAT command in principle
    /// that could back them remotely: the CAT command set has no mnemonic
    /// for received APRS packet *content* at all (the same gap
    /// `RigState.c4fmCallsign`'s doc comment describes for received C4FM
    /// digital voice data), and there's no CAT mechanism to remotely select
    /// which screen the rig's own display shows either — confirmed by
    /// checking the full alphabetical command list and Table 3 for any
    /// "select display page" style command, finding none. Rather than stay
    /// permanently disabled like BCN-TX below, this app works around the
    /// gap the same way it does for `c4fmCallsign` — decoding APRS off
    /// audio directly instead of depending on CAT — so these buttons are
    /// live wherever `hub.supportsAPRSDecoding` is true (currently just the
    /// Mac, since decoding needs `AudioCaptureEngine`'s audio input) and
    /// open a dedicated window (`aprsListButton`'s `openWindow` call, see
    /// its doc comment) rather than a sheet, so a station/message list can
    /// be left open alongside the main window while operating. Button 13 is
    /// BEACON (`RigCommand.
    /// setAPRSBeaconType`, single-tap-cycles-to-next like RPT SHIFT/SQL TYPE
    /// over 3 values, no dedicated mnemonic — routed through the generic
    /// "EX" passthrough at Table 3's fixed p1=7/p2=1/p3=1 like
    /// `.setAntSelect`); button 14, BCN-TX, is visible-but-disabled — no CAT
    /// path exists for a momentary action with no Table 3 entry and no
    /// mnemonic (see `aprsBeaconTypeLabel`'s doc comment for why this one
    /// couldn't even be live-probed). Button 15 is CH STEP (`RigCommand.
    /// setFMChannelStep`, single-tap-cycles-to-next like BEACON over 6
    /// values, no dedicated mnemonic — routed through the generic "EX"
    /// passthrough at Table 3's fixed p1=3/p2=6/p3=6 ("FM CH STEP") like
    /// `.setAPRSBeaconType`); button 21 is HOME (`homeButton`) — unlike
    /// every other undocumented button on this page, this one has a real
    /// client-side implementation despite having no CAT command at all: the
    /// FTX-1's rig-internal HOME channels (Advance Manual p.27, one
    /// frequency per band group — see `HomeBand`) aren't readable/settable
    /// over CAT in any way, so this app keeps its own copy
    /// (`HomeFrequencySettings`, editable in the Mac Settings sheet's "Home
    /// Freq" tab) and just sends a plain `RigCommand.setFrequency` for
    /// whichever band group the current frequency falls in — no new wire
    /// protocol needed. Button 18 is SQL
    /// TYPE (`RigCommand.setSquelchType`, single-tap-cycles-to-next like
    /// IPO/AMP/AGC over 6 values, raw "CT" CAT command with fixed MAIN-side
    /// P1), button 19 is TONE FREQ (`RigCommand.setToneFreq`, popover
    /// `Stepper` over `RigCTCSSTone`'s 50-tone table, raw "CN" command's
    /// P2=0/CTCSS sub-function), button 20 is DCS (`RigCommand.setDCSCode`,
    /// same popover-`Stepper`-over-a-lookup-table treatment as TONE FREQ,
    /// raw "CN" command's P2=1/DCS sub-function over `RigDCSCode`'s 104-code
    /// table) — these three are the same settings as Deep Settings' RADIO
    /// SETTING → MODE FM tab's SQL TYPE/TONE FREQ/DCS CODE items, reached
    /// here via their own dedicated mnemonics rather than the generic "EX"
    /// passthrough, per this project's "check for a dedicated mnemonic
    /// first" convention. Everything else is still a numbered placeholder
    /// pending real per-item functions.
    @ViewBuilder
    private func menuButton(for item: Int) -> some View {
        if item == 1 {
            menuButtonShell {
                // Not yet wired — mirrors the rig's own page-select button.
            } label: {
                twoLineLabel(top: "PAGE \(selectedPage.pageNumber)/3", bottom: selectedPage.rawValue)
            }
        } else if selectedPage == .ssb, item == 22 {
            rfPowerButton
        } else if selectedPage != .ssb, item == 22 {
            menuButtonShell {
                selectedPage = selectedPage.previous
            } label: {
                twoLineLabel(top: "◀", bottom: selectedPage.previous.rawValue)
            }
        } else if selectedPage != .fm, item == 28 {
            menuButtonShell {
                selectedPage = selectedPage.next
            } label: {
                twoLineLabel(top: "▶", bottom: selectedPage.next.rawValue)
            }
        } else if selectedPage == .ssb, item == 2 {
            displayLevelButton
        } else if selectedPage == .ssb, item == 3 {
            displayPeakButton
        } else if selectedPage == .ssb, item == 4 {
            menuButtonShell {
                hub.send(.setDisplayMarker(!(hub.rigState.displayMarker ?? false)))
            } label: {
                twoLineLabel(top: "D-MARKER", bottom: (hub.rigState.displayMarker ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .ssb, item == 5 {
            disabledPlaceholderButton(top: "D-COLOR")
        } else if selectedPage == .ssb, item == 6 {
            displayContrastButton
        } else if selectedPage == .ssb, item == 7 {
            displayDimmerButton
        } else if selectedPage == .ssb, item == 8 {
            menuButtonShell(disabled: !hub.rigState.transmitEnabled) {
                hub.send(.setMox(!(hub.rigState.moxEnabled ?? false)))
            } label: {
                twoLineLabel(top: "MOX", bottom: (hub.rigState.moxEnabled ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .ssb, item == 9 {
            menuButtonShell {
                hub.send(.setAtt(!(hub.rigState.attEnabled ?? false)))
            } label: {
                twoLineLabel(top: "ATT", bottom: (hub.rigState.attEnabled ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .ssb, item == 10 {
            menuButtonShell {
                hub.send(.setPreamp(mode: ((hub.rigState.preampMode ?? 0) + 1) % 3))
            } label: {
                twoLineLabel(top: "IPO/AMP", bottom: Self.preampLabel(hub.rigState.preampMode))
            }
        } else if selectedPage == .ssb, item == 11 {
            menuButtonShell {
                hub.send(.setDNF(!(hub.rigState.dnfEnabled ?? false)))
            } label: {
                twoLineLabel(top: "DNF", bottom: (hub.rigState.dnfEnabled ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .ssb, item == 12 {
            menuButtonShell {
                hub.send(.setAGC(mode: (Self.agcCollapsedMode(hub.rigState.agcMode) + 1) % 5))
            } label: {
                twoLineLabel(top: "AGC", bottom: Self.agcLabel(hub.rigState.agcMode))
            }
        } else if selectedPage == .ssb, item == 13 {
            menuButtonShell {
                hub.send(.setMicEQ(!(hub.rigState.micEQEnabled ?? false)))
            } label: {
                twoLineLabel(top: "MIC EQ", bottom: (hub.rigState.micEQEnabled ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .ssb, item == 14 {
            procLevelButton
        } else if selectedPage == .ssb, item == 15 {
            menuButtonShell(disabled: !hub.rigState.transmitEnabled) {
                hub.send(.triggerAntennaTune)
            } label: {
                twoLineLabel(top: "ANT TUNE", bottom: "PUSH")
            }
        } else if selectedPage == .ssb, item == 16 {
            menuButtonShell {
                hub.send(.setTuner(!(hub.rigState.tunerEnabled ?? false)))
            } label: {
                twoLineLabel(top: "TUNER", bottom: (hub.rigState.tunerEnabled ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .ssb, item == 17 {
            hiddenButtonPlaceholder(for: item)
        } else if selectedPage == .ssb, item == 18 {
            nbLevelButton
        } else if selectedPage == .ssb, item == 19 {
            dnrLevelButton
        } else if selectedPage == .ssb, item == 20 {
            menuButtonShell {
                hub.send(.setAntSelect(((hub.rigState.antSelect ?? 0) + 1) % 2))
            } label: {
                twoLineLabel(top: "ANT", bottom: Self.antSelectLabel(hub.rigState.antSelect))
            }
        } else if selectedPage == .ssb, item == 21 {
            disabledTXWButton
        } else if selectedPage == .ssb, item == 23 {
            micGainButton
        } else if selectedPage == .ssb, item == 24 {
            amcLevelButton
        } else if selectedPage == .ssb, item == 25 {
            voxButton
        } else if selectedPage == .ssb, item == 26 {
            voxGainButton
        } else if selectedPage == .ssb, item == 27 {
            voxDelayButton
        } else if selectedPage == .cw, item == 2 {
            moniLevelButton
        } else if selectedPage == .cw, item == 8 {
            menuButtonShell {
                hub.send(.setKeyer(!(hub.rigState.keyerEnabled ?? false)))
            } label: {
                twoLineLabel(top: "KEYER", bottom: (hub.rigState.keyerEnabled ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .cw, item == 9 {
            menuButtonShell {
                hub.send(.setBreakIn(!(hub.rigState.breakIn ?? false)))
            } label: {
                twoLineLabel(top: "BK-IN", bottom: (hub.rigState.breakIn ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .cw, item == 10 {
            cwSpeedButton
        } else if selectedPage == .cw, item == 11 {
            cwPitchButton
        } else if selectedPage == .cw, item == 12 {
            bkDelayButton
        } else if selectedPage == .cw, item == 13 {
            menuButtonShell {
                hub.send(.triggerZeroIn)
            } label: {
                twoLineLabel(top: "ZIN", bottom: "PUSH")
            }
        } else if selectedPage == .cw, item == 14 {
            menuButtonShell {
                hub.send(.setCWSpot(!(hub.rigState.cwSpot ?? false)))
            } label: {
                twoLineLabel(top: "CW SPOT", bottom: (hub.rigState.cwSpot ?? false) ? "ON" : "OFF")
            }
        } else if selectedPage == .cw, item == 19 {
            disabledCWMessageButton(top: "MESSAGE")
        } else if selectedPage == .cw, item == 20 {
            disabledCWMessageButton(top: "PLAY")
        } else if selectedPage == .cw, item == 21 {
            disabledCWMessageButton(top: "RECORD")
        } else if selectedPage == .cw, menuPageHiddenCWItems.contains(item) {
            hiddenButtonPlaceholder(for: item)
        } else if selectedPage == .fm, menuPageHiddenFMItems.contains(item) {
            hiddenButtonPlaceholder(for: item)
        } else if selectedPage == .fm, item == 8 {
            disabledPlaceholderButton(top: "DG-ID TX")
        } else if selectedPage == .fm, item == 9 {
            disabledPlaceholderButton(top: "DG-ID RX")
        } else if selectedPage == .fm, item == 10 {
            disabledPlaceholderButton(top: "HRI MODE")
        } else if selectedPage == .fm, item == 2 {
            dtmfButton
        } else if selectedPage == .fm, item == 3 {
            disabledPlaceholderButton(top: "T-CALL")
        } else if selectedPage == .fm, item == 6 {
            menuButtonShell {
                hub.send(.setRepeaterShift(mode: ((hub.rigState.repeaterShiftMode ?? 0) + 1) % 4))
            } label: {
                twoLineLabel(top: "RPT SHIFT", bottom: Self.repeaterShiftLabel(hub.rigState.repeaterShiftMode))
            }
        } else if selectedPage == .fm, item == 7 {
            disabledPlaceholderButton(top: "REV")
        } else if selectedPage == .fm, item == 11 {
            aprsListButton(bottom: "S.LIST", windowID: "aprs-stations")
        } else if selectedPage == .fm, item == 12 {
            aprsListButton(bottom: "M.LIST", windowID: "aprs-messages")
        } else if selectedPage == .fm, item == 13 {
            menuButtonShell {
                hub.send(.setAPRSBeaconType(((hub.rigState.aprsBeaconType ?? 0) + 1) % 3))
            } label: {
                twoLineLabel(top: "BEACON", bottom: Self.aprsBeaconTypeLabel(hub.rigState.aprsBeaconType))
            }
        } else if selectedPage == .fm, item == 14 {
            disabledPlaceholderButton(top: "BCN-TX")
        } else if selectedPage == .fm, item == 15 {
            menuButtonShell {
                hub.send(.setFMChannelStep(((hub.rigState.fmChannelStep ?? 0) + 1) % 6))
            } label: {
                twoLineLabel(top: "CH STEP", bottom: Self.fmChannelStepLabel(hub.rigState.fmChannelStep))
            }
        } else if selectedPage == .fm, item == 21 {
            homeButton
        } else if selectedPage == .fm, item == 18 {
            menuButtonShell {
                hub.send(.setSquelchType(((hub.rigState.squelchType ?? 0) + 1) % 6))
            } label: {
                twoLineLabel(top: "SQL TYPE", bottom: Self.sqlTypeLabel(hub.rigState.squelchType))
            }
        } else if selectedPage == .fm, item == 19 {
            toneFreqButton
        } else if selectedPage == .fm, item == 20 {
            dcsCodeButton
        } else if selectedPage == .fm, item == 23 {
            deepSettingsButton(top: "RADIO", bottom: "SETTING", title: "RADIO SETTING", p1s: [1])
        } else if selectedPage == .fm, item == 24 {
            deepSettingsButton(top: "CW", bottom: "SETTING", title: "CW SETTING", p1s: [2])
        } else if selectedPage == .fm, item == 25 {
            deepSettingsButton(top: "OPERATION", bottom: "SETTING", title: "OPERATION SETTING", p1s: [3])
        } else if selectedPage == .fm, item == 26 {
            deepSettingsButton(top: "DISPLAY", bottom: "SETTING", title: "DISPLAY SETTING", p1s: [4])
        } else if selectedPage == .fm, item == 27 {
            deepSettingsButton(top: "EXTENSION", bottom: "SETTING", title: "EXTENSION SETTING", p1s: [5])
        } else if selectedPage == .fm, item == 28 {
            // The physical APRS SETTING button spans three Table 3
            // categories (APRS Setting/Beacon/Filter, p1 6-8) on one screen.
            deepSettingsButton(top: "APRS", bottom: "SETTING", title: "APRS SETTING", p1s: [6, 7, 8])
        } else {
            menuButtonShell {
                // Not yet wired to a CAT command — layout only.
            } label: {
                Text("\(item)")
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    /// FM/C4FM page bottom-row buttons (23-28) all open the same generic
    /// Deep Settings destination, just addressed at a different Table 3
    /// category — unlike every other button on this grid, none of these
    /// needs its own `@State` popover flag, since they all share
    /// `activeDeepSettings`. Only meaningful when `hub.supportsDeepSettings`
    /// (currently the Mac's `HubService` only — see `RigController`); other
    /// controllers get a disabled placeholder instead of a sheet that would
    /// open to a screen of blank rows.
    @ViewBuilder
    private func deepSettingsButton(top: String, bottom: String, title: String, p1s: [Int]) -> some View {
        if hub.supportsDeepSettings {
            menuButtonShell {
                activeDeepSettings = ActiveDeepSettings(title: title, p1s: p1s)
            } label: {
                twoLineLabelEqualSize(top: top, bottom: bottom)
            }
        } else {
            menuButtonShell {
                // Deliberately a no-op — see doc comment above.
            } label: {
                twoLineLabelEqualSize(top: top, bottom: "SOON")
                    .foregroundStyle(.secondary)
            }
            .disabled(true)
        }
    }

    /// CW SPEED and CW PITCH are numeric (4-60 WPM / 300-1050 Hz), not
    /// on/off, so a single tap can't just flip a value the way KEYER/BK-IN
    /// do — tapping opens a small popover with a `Stepper` instead, matching
    /// the rig's own MENU behavior of "select the item, then dial in a
    /// value." Falls back to a sensible mid-range default while
    /// `rigState`'s value is still nil (before the first successful poll).
    private var cwSpeedButton: some View {
        menuButtonShell {
            showingCWSpeedPopover = true
        } label: {
            twoLineLabel(top: "CW SPEED", bottom: hub.rigState.cwSpeedWpm.map { "\($0) WPM" } ?? "—")
        }
        .popover(isPresented: $showingCWSpeedPopover) {
            Stepper(
                "\(hub.rigState.cwSpeedWpm ?? 20) WPM",
                value: Binding(
                    get: { hub.rigState.cwSpeedWpm ?? 20 },
                    set: { hub.send(.setCWSpeed(wpm: $0)) }
                ),
                in: 4...60
            )
            .padding()
            .frame(width: 180)
        }
    }

    private var cwPitchButton: some View {
        menuButtonShell {
            showingCWPitchPopover = true
        } label: {
            twoLineLabel(top: "CW PITCH", bottom: hub.rigState.cwPitchHz.map { "\($0) Hz" } ?? "—")
        }
        .popover(isPresented: $showingCWPitchPopover) {
            Stepper(
                "\(hub.rigState.cwPitchHz ?? 700) Hz",
                value: Binding(
                    get: { hub.rigState.cwPitchHz ?? 700 },
                    set: { hub.send(.setCWPitch(hz: $0)) }
                ),
                in: 300...1050,
                step: 10
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// Like CW SPEED/PITCH, BK-DELAY is numeric rather than on/off, so it
    /// gets the same tap-to-open-a-popover-`Stepper` treatment. Unlike
    /// those two, its raw "SD" values aren't evenly spaced (see
    /// `RigDelayCode`), so the stepper steps through `RigDelayCode`'s 0-33
    /// code range rather than milliseconds directly, converting to/from
    /// ms only at the `RigCommand` boundary.
    private var bkDelayButton: some View {
        menuButtonShell {
            showingBKDelayPopover = true
        } label: {
            twoLineLabel(top: "BK-DELAY", bottom: hub.rigState.bkDelayMs.map { "\($0) ms" } ?? "—")
        }
        .popover(isPresented: $showingBKDelayPopover) {
            let currentCode = RigDelayCode.code(forMilliseconds: hub.rigState.bkDelayMs ?? 300) ?? 6
            Stepper(
                "\(RigDelayCode.milliseconds(forCode: currentCode) ?? 300) ms",
                value: Binding(
                    get: { currentCode },
                    set: { code in
                        if let ms = RigDelayCode.milliseconds(forCode: code) {
                            hub.send(.setBreakInDelay(ms: ms))
                        }
                    }
                ),
                in: 0...(RigDelayCode.allValuesMs.count - 1)
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// Numeric like CW SPEED/PITCH/BK-DELAY, so it gets the same popover
    /// `Stepper`. This only ever sets the raw "ML" command's *level*
    /// sub-value (P1=1) — see `RigState.moniLevel` — not the separate
    /// on/off sub-value the same mnemonic carries under P1=0: on the real
    /// rig, a level readback of 0 already means MONI is off, so that's
    /// shown as "OFF" here rather than exposing a second button/command
    /// for what's functionally the same on/off state.
    private var moniLevelButton: some View {
        menuButtonShell {
            showingMoniLevelPopover = true
        } label: {
            twoLineLabel(top: "MONI LEVEL", bottom: Self.moniLevelLabel(hub.rigState.moniLevel))
        }
        .popover(isPresented: $showingMoniLevelPopover) {
            Stepper(
                Self.moniLevelLabel(hub.rigState.moniLevel ?? 50),
                value: Binding(
                    get: { hub.rigState.moniLevel ?? 50 },
                    set: { hub.send(.setMoniLevel(level: $0)) }
                ),
                in: 0...100
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// SSB button 6, D-CONTRAST. Numeric like CW SPEED/PITCH/BK-DELAY/MONI
    /// LEVEL, so it gets the same tap-to-open-a-popover-`Stepper` treatment —
    /// maps to the FTX-1's raw "DA" CAT command's P2 field, which (unlike
    /// every other numeric button here) is packed alongside two other
    /// independently-adjustable fields in one Set command, so
    /// `RigCommand.setDisplayContrast`/`CommandQueue` read the current
    /// triple before writing so DIMMER's value isn't clobbered — see
    /// `RigctldClient.getDisplaySettings()`/`setDisplaySettings(...)`.
    private var displayContrastButton: some View {
        menuButtonShell {
            showingDisplayContrastPopover = true
        } label: {
            twoLineLabel(top: "D-CONTRAST", bottom: hub.rigState.displayContrast.map { "\($0)" } ?? "—")
        }
        .popover(isPresented: $showingDisplayContrastPopover) {
            Stepper(
                "\(hub.rigState.displayContrast ?? 10)",
                value: Binding(
                    get: { hub.rigState.displayContrast ?? 10 },
                    set: { hub.send(.setDisplayContrast($0)) }
                ),
                in: 0...20
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// SSB button 7, DIMMER (TFT backlight brightness) — same "DA" command
    /// as `displayContrastButton` above, its P3 field.
    private var displayDimmerButton: some View {
        menuButtonShell {
            showingDisplayDimmerPopover = true
        } label: {
            twoLineLabel(top: "DIMMER", bottom: hub.rigState.displayDimmer.map { "\($0)" } ?? "—")
        }
        .popover(isPresented: $showingDisplayDimmerPopover) {
            Stepper(
                "\(hub.rigState.displayDimmer ?? 10)",
                value: Binding(
                    get: { hub.rigState.displayDimmer ?? 10 },
                    set: { hub.send(.setDisplayDimmer($0)) }
                ),
                in: 0...20
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// SSB button 2, D-LEVEL (spectrum scope display level, -30.0 to +30.0
    /// dB in 0.5dB steps) — popover `Stepper` like CW SPEED/PITCH, but with
    /// a `Double` step since this value isn't integer WPM/Hz. Maps to the
    /// FTX-1's raw "SS" CAT command's LEVEL sub-function (P2=4) — unlike
    /// D-CONTRAST/DIMMER's "DA", "SS" only needs read-then-write for the one
    /// sub-function being changed, not a shared packed triple, since its
    /// Read command lets you address just that sub-function (`RigctldClient.
    /// getSpectrumScopeLevel()`/`setSpectrumScopeLevel(_:)`).
    private var displayLevelButton: some View {
        menuButtonShell {
            showingDisplayLevelPopover = true
        } label: {
            twoLineLabel(top: "D-LEVEL", bottom: Self.displayLevelLabel(hub.rigState.displayLevel))
        }
        .popover(isPresented: $showingDisplayLevelPopover) {
            Stepper(
                Self.displayLevelLabel(hub.rigState.displayLevel ?? 0),
                value: Binding(
                    get: { hub.rigState.displayLevel ?? 0 },
                    set: { hub.send(.setDisplayLevel($0)) }
                ),
                in: -30...30,
                step: 0.5
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// SSB button 22, RF POWER (0-100% output power, relative to whatever
    /// per-band MAX POWER ceiling applies — a separate setting, under Deep
    /// Settings' OPERATION SETTING category, not this button). This is the
    /// one popover control that uses a `Slider` rather than a `Stepper`
    /// like every other numeric button here (CW SPEED/PITCH, BK-DELAY,
    /// MONI LEVEL, D-CONTRAST/DIMMER/LEVEL) — it's the same continuous
    /// hamlib `RFPOWER` level this popover replaces from its previous home
    /// as a standalone slider in the Mac app's `ContentView`, and dragging
    /// through 100 discrete 1%-`Stepper` taps would be impractical where a
    /// drag gesture works naturally. Commits via `hub.send(.setPowerLevel)`
    /// only on drag release (`onEditingChanged`'s `editing == false`), not
    /// continuously, to avoid flooding rigctld with a command per pixel of
    /// drag — `isDraggingRFPower`/`localRFPowerLevel` mirror the same
    /// smooth-during-drag technique `ContentView`'s slider used.
    private var rfPowerButton: some View {
        menuButtonShell {
            showingRFPowerPopover = true
        } label: {
            twoLineLabel(top: "RF POWER", bottom: Self.rfPowerLabel(hub.rigState.powerLevel))
        }
        .popover(isPresented: $showingRFPowerPopover) {
            VStack(spacing: 8) {
                Text(Self.rfPowerLabel(displayedRFPowerLevel))
                Slider(
                    value: Binding(
                        get: { displayedRFPowerLevel },
                        set: { localRFPowerLevel = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            localRFPowerLevel = hub.rigState.powerLevel ?? 0
                            isDraggingRFPower = true
                        } else {
                            isDraggingRFPower = false
                            hub.send(.setPowerLevel(localRFPowerLevel))
                        }
                    }
                )
            }
            .padding()
            .frame(width: 180)
        }
    }

    /// SSB button 23, MIC GAIN — numeric like CW SPEED/PITCH/BK-DELAY/MONI
    /// LEVEL, so it gets the same tap-to-open-a-popover-`Stepper` treatment.
    /// Maps to the FTX-1's raw "MG" CAT command, a plain 0-100 value with no
    /// P2 sub-function (unlike D-CONTRAST/DIMMER's packed "DA").
    private var micGainButton: some View {
        menuButtonShell {
            showingMicGainPopover = true
        } label: {
            twoLineLabel(top: "MIC GAIN", bottom: hub.rigState.micGain.map { "\($0)" } ?? "—")
        }
        .popover(isPresented: $showingMicGainPopover) {
            Stepper(
                "\(hub.rigState.micGain ?? 50)",
                value: Binding(
                    get: { hub.rigState.micGain ?? 50 },
                    set: { hub.send(.setMicGain($0)) }
                ),
                in: 0...100
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// SSB button 24, AMC LEVEL (Automatic Mic Compressor output level) —
    /// same popover-`Stepper` treatment as `micGainButton`, mapping to the
    /// FTX-1's raw "AO" CAT command. Its documented range is 1-100 (not
    /// 0-100 like MIC GAIN).
    private var amcLevelButton: some View {
        menuButtonShell {
            showingAMCLevelPopover = true
        } label: {
            twoLineLabel(top: "AMC LEVEL", bottom: hub.rigState.amcLevel.map { "\($0)" } ?? "—")
        }
        .popover(isPresented: $showingAMCLevelPopover) {
            Stepper(
                "\(hub.rigState.amcLevel ?? 50)",
                value: Binding(
                    get: { hub.rigState.amcLevel ?? 50 },
                    set: { hub.send(.setAMCLevel($0)) }
                ),
                in: 1...100
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// SSB button 14, PROC LEVEL — numeric like MIC GAIN/AMC LEVEL, same
    /// popover `Stepper` treatment, mapping to the FTX-1's raw "PL" CAT
    /// command (0-100, 3 digits). 0 reads as "OFF" per the manual — same
    /// convention as `moniLevelButton`'s MONI LEVEL — via `procLevelLabel(_:)`.
    private var procLevelButton: some View {
        menuButtonShell {
            showingProcLevelPopover = true
        } label: {
            twoLineLabel(top: "PROC LEVEL", bottom: Self.procLevelLabel(hub.rigState.procLevel))
        }
        .popover(isPresented: $showingProcLevelPopover) {
            Stepper(
                Self.procLevelLabel(hub.rigState.procLevel ?? 50),
                value: Binding(
                    get: { hub.rigState.procLevel ?? 50 },
                    set: { hub.send(.setProcLevel($0)) }
                ),
                in: 0...100
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// 0 reads as "OFF" (see `procLevelButton`); `nil` (no poll yet) as "—".
    private static func procLevelLabel(_ level: Int?) -> String {
        guard let level else { return "—" }
        return level == 0 ? "OFF" : "\(level)"
    }

    /// SSB button 18, NB — numeric like MONI LEVEL/PROC LEVEL, same popover
    /// `Stepper` treatment, mapping to the FTX-1's raw "NL" (NOISE BLANKER
    /// LEVEL) CAT command, 0-10.
    private var nbLevelButton: some View {
        menuButtonShell {
            showingNBLevelPopover = true
        } label: {
            twoLineLabel(top: "NB", bottom: Self.nbLevelLabel(hub.rigState.nbLevel))
        }
        .popover(isPresented: $showingNBLevelPopover) {
            Stepper(
                Self.nbLevelLabel(hub.rigState.nbLevel ?? 5),
                value: Binding(
                    get: { hub.rigState.nbLevel ?? 5 },
                    set: { hub.send(.setNBLevel($0)) }
                ),
                in: 0...10
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// 0 reads as "OFF" (see `nbLevelButton`); `nil` (no poll yet) as "—".
    private static func nbLevelLabel(_ level: Int?) -> String {
        guard let level else { return "—" }
        return level == 0 ? "OFF" : "\(level)"
    }

    /// SSB button 19, DNR — numeric like NB, same popover `Stepper`
    /// treatment, mapping to the FTX-1's raw "RL" (NOISE REDUCTION LEVEL)
    /// CAT command, 0-10.
    private var dnrLevelButton: some View {
        menuButtonShell {
            showingDNRLevelPopover = true
        } label: {
            twoLineLabel(top: "DNR", bottom: Self.dnrLevelLabel(hub.rigState.dnrLevel))
        }
        .popover(isPresented: $showingDNRLevelPopover) {
            Stepper(
                Self.dnrLevelLabel(hub.rigState.dnrLevel ?? 5),
                value: Binding(
                    get: { hub.rigState.dnrLevel ?? 5 },
                    set: { hub.send(.setDNRLevel($0)) }
                ),
                in: 0...10
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// 0 reads as "OFF" (see `dnrLevelButton`); `nil` (no poll yet) as "—".
    private static func dnrLevelLabel(_ level: Int?) -> String {
        guard let level else { return "—" }
        return level == 0 ? "OFF" : "\(level)"
    }

    /// FM/C4FM button 6, RPT SHIFT — small fixed choice set (4 values), same
    /// single-tap-cycles-to-next treatment as `sqlTypeLabel` below. Maps to
    /// the FTX-1's raw "OS" (OFFSET/REPEATER SHIFT) CAT command, P1 fixed to
    /// "0" (MAIN-side). The manual documents its own P2 order as 0:Simplex/
    /// 1:Plus Shift/2:Minus Shift/3:ARS — used as-is here rather than Table
    /// 3's differently-worded "0: - 1: SIMPLEX 2: + 3: ARS" cell for the same
    /// setting, since "OS"'s own dedicated command page is the clearer,
    /// more authoritative source for its own P2 encoding.
    private static func repeaterShiftLabel(_ mode: Int?) -> String {
        switch mode {
        case 0: "SIMPLEX"
        case 1: "+"
        case 2: "-"
        case 3: "ARS"
        default: "—"
        }
    }

    /// FM/C4FM button 13, BEACON (auto beacon TX on/off, per the user) —
    /// small fixed choice set (3 values), same single-tap-cycles-to-next
    /// treatment as `repeaterShiftLabel`/`sqlTypeLabel`. Like ANT SELECT, no
    /// dedicated mnemonic exists for this — it's Table 3's "BEACON TYPE"
    /// item (APRS BEACON / BEACON SET. / p3=1), reached through the generic
    /// "EX" passthrough (see `RigCommand.setAPRSBeaconType`). Button 14,
    /// BCN-TX (a momentary "send beacon now" action, per the user), is
    /// visible-but-disabled — momentary actions never appear in Table 3 at
    /// all, there's no dedicated mnemonic either, and unlike a normal
    /// setting there's no way to observe a physical button's effect over
    /// CAT to reverse-engineer it (pressing a button on the rig's own head
    /// unit doesn't emit any outbound CAT traffic) — live-probing this would
    /// mean blind-guessing raw commands against a real transmitter with zero
    /// documented starting point, which wasn't worth the risk.
    private static func aprsBeaconTypeLabel(_ mode: Int?) -> String {
        switch mode {
        case 0: "OFF"
        case 1: "AUTO"
        case 2: "SMART"
        default: "—"
        }
    }

    /// FM/C4FM button 15, CH STEP — small fixed choice set (6 values), same
    /// single-tap-cycles-to-next treatment as `aprsBeaconTypeLabel`. Like
    /// BEACON/ANT SELECT, no dedicated mnemonic exists — it's Table 3's "FM
    /// CH STEP" item (OPERATION SETTING / KEY/DIAL / p3=6), reached through
    /// the generic "EX" passthrough (see `RigCommand.setFMChannelStep`).
    /// Button 21, HOME, has no mnemonic/Table 3 entry either, but unlike
    /// REV/DG-ID/HRI MODE this one gets a real (client-side) implementation
    /// — see `homeButton`'s doc comment.
    private static func fmChannelStepLabel(_ step: Int?) -> String {
        switch step {
        case 0: "5 kHz"
        case 1: "6.25 kHz"
        case 2: "10 kHz"
        case 3: "12.5 kHz"
        case 4: "20 kHz"
        case 5: "25 kHz"
        default: "—"
        }
    }

    /// FM/C4FM button 21, HOME — momentary action like `ZIN`/`ANT TUNE`, but
    /// entirely client-side: the rig has no CAT command to read or recall its
    /// own HOME channels at all (see `HomeBand`'s doc comment), so tapping
    /// this looks up which of the five band groups the *current* frequency
    /// falls in and jumps straight to that group's configured
    /// `HomeFrequencySettings` value via a plain `RigCommand.setFrequency` —
    /// no rig-side HOME feature is actually being invoked, this just
    /// reproduces its effect locally. A no-op if the current frequency isn't
    /// in any of the five groups (e.g. 30-50MHz, between HF and 50MHz).
    private var homeButton: some View {
        singleWordButton("HOME") {
            if let band = HomeBand.band(containing: hub.rigState.frequencyHz) {
                hub.send(.setFrequency(hz: HomeFrequencySettings.frequencyHz(for: band)))
            }
        }
    }

    /// FM/C4FM button 2, DTMF — on the real rig this opens a DTMF code entry/
    /// memory-selection screen (see the Advance Manual's "DTMF Operation"
    /// section), not a settable value; the app has no way to drive that
    /// screen remotely (same "no CAT path to a rig-side UI screen" reasoning
    /// as APRS S.LIST/M.LIST), and transmitting a DTMF code is TX-triggering
    /// like BCN-TX, so it isn't worth blind-probing either. Per the user,
    /// this button shows only "DTMF" on the real rig (no separate value), so
    /// it gets `singleWordButton`'s treatment like HOME rather than
    /// `disabledPlaceholderButton`'s name+"—" pair — a placeholder, but one
    /// that still matches the single-word buttons' look since that's what
    /// the physical button actually looks like.
    private var dtmfButton: some View {
        singleWordButton("DTMF")
    }

    /// A single centered word at the same size as every other button's
    /// bottom (value) line, in plain white — for buttons whose real label is
    /// just one word with no separate name/value pair (`HOME`, `DTMF`),
    /// unlike `twoLineLabel`'s name-on-top/value-on-bottom buttons or
    /// `twoLineLabelEqualSize`'s two-word pairs. `action` defaults to a
    /// no-op for placeholder uses like `dtmfButton`. A hidden real
    /// `twoLineLabel` underneath reserves this button's exact size (so it
    /// still matches every neighboring two-line button's) with the visible
    /// word overlaid and centered via `ZStack`'s default centering — a plain
    /// `VStack` with just a blank hidden top line matches the height but
    /// leaves the word sitting low rather than centered (confirmed while
    /// sizing the HOME button).
    private func singleWordButton(_ word: String, action: @escaping () -> Void = {}) -> some View {
        menuButtonShell(action: action) {
            ZStack {
                twoLineLabel(top: " ", bottom: " ").hidden()
                Text(word)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
    }

    /// FM/C4FM button 18, SQL TYPE — small fixed choice set (6 values), so
    /// single-tap-cycles-to-next like IPO/AMP/AGC rather than a popover
    /// `Stepper`. Maps to the FTX-1's raw "CT" CAT command, P1 fixed to "0"
    /// (MAIN-side).
    private static func sqlTypeLabel(_ mode: Int?) -> String {
        switch mode {
        case 0: "OFF"
        case 1: "ENC"
        case 2: "TSQ"
        case 3: "DCS"
        case 4: "PR FREQ"
        case 5: "REV TONE"
        default: "—"
        }
    }

    /// FM/C4FM button 19, TONE FREQ — steps through `RigCTCSSTone.
    /// allValuesHz`'s 50-tone table by index (the FTX-1's raw "CN" CAT
    /// command's P2=0/CTCSS sub-function stores an index, not Hz directly),
    /// same index-binding-displays-real-value pattern as `bkDelayButton`/
    /// `voxDelayButton`'s `RigDelayCode`. Defaults to index 12 (100.0 Hz, a
    /// common repeater tone) while unread.
    private var toneFreqButton: some View {
        menuButtonShell {
            showingToneFreqPopover = true
        } label: {
            twoLineLabel(top: "TONE FREQ", bottom: Self.toneFreqLabel(hub.rigState.ctcssToneIndex))
        }
        .popover(isPresented: $showingToneFreqPopover) {
            Stepper(
                Self.toneFreqLabel(hub.rigState.ctcssToneIndex ?? 12),
                value: Binding(
                    get: { hub.rigState.ctcssToneIndex ?? 12 },
                    set: { hub.send(.setToneFreq(index: $0)) }
                ),
                in: 0...(RigCTCSSTone.allValuesHz.count - 1)
            )
            .padding()
            .frame(width: 180)
        }
    }

    private static func toneFreqLabel(_ index: Int?) -> String {
        guard let index, let hz = RigCTCSSTone.hertz(forIndex: index) else { return "—" }
        return "\(hz) Hz"
    }

    /// FM/C4FM button 20, DCS — same index-stepping treatment as
    /// `toneFreqButton`, over `RigDCSCode.allValues`'s 104-code table (the
    /// FTX-1's raw "CN" command's P2=1/DCS sub-function). Defaults to index 0
    /// (code 023) while unread.
    private var dcsCodeButton: some View {
        menuButtonShell {
            showingDCSPopover = true
        } label: {
            twoLineLabel(top: "DCS", bottom: Self.dcsCodeLabel(hub.rigState.dcsCodeIndex))
        }
        .popover(isPresented: $showingDCSPopover) {
            Stepper(
                Self.dcsCodeLabel(hub.rigState.dcsCodeIndex ?? 0),
                value: Binding(
                    get: { hub.rigState.dcsCodeIndex ?? 0 },
                    set: { hub.send(.setDCSCode(index: $0)) }
                ),
                in: 0...(RigDCSCode.allValues.count - 1)
            )
            .padding()
            .frame(width: 180)
        }
    }

    private static func dcsCodeLabel(_ index: Int?) -> String {
        guard let index, let code = RigDCSCode.code(forIndex: index) else { return "—" }
        return code
    }

    /// SSB button 20, ANT — cycles ANT1/ANT2 on each tap like IPO/AMP,
    /// matching a physical MENU button's own behavior for a small fixed
    /// choice set. See `RigState.antSelect`'s doc comment for why this one
    /// button goes through the generic "EX" passthrough rather than a
    /// dedicated mnemonic.
    private static func antSelectLabel(_ mode: Int?) -> String {
        switch mode {
        case 0: "ANT1"
        case 1: "ANT2"
        default: "—"
        }
    }

    /// SSB button 25, VOX — on/off like MOX/ATT/BK-IN/KEYER, so a single tap
    /// just flips it rather than opening a popover. Maps to the FTX-1's raw
    /// "VX" CAT command.
    private var voxButton: some View {
        menuButtonShell {
            hub.send(.setVox(!(hub.rigState.voxEnabled ?? false)))
        } label: {
            twoLineLabel(top: "VOX", bottom: (hub.rigState.voxEnabled ?? false) ? "ON" : "OFF")
        }
    }

    /// SSB button 26, VOX GAIN — numeric like MIC GAIN, same popover
    /// `Stepper` treatment. Maps to the FTX-1's raw "VG" CAT command, a
    /// plain 0-100 value with no P2 sub-function.
    private var voxGainButton: some View {
        menuButtonShell {
            showingVoxGainPopover = true
        } label: {
            twoLineLabel(top: "VOX GAIN", bottom: hub.rigState.voxGain.map { "\($0)" } ?? "—")
        }
        .popover(isPresented: $showingVoxGainPopover) {
            Stepper(
                "\(hub.rigState.voxGain ?? 50)",
                value: Binding(
                    get: { hub.rigState.voxGain ?? 50 },
                    set: { hub.send(.setVoxGain($0)) }
                ),
                in: 0...100
            )
            .padding()
            .frame(width: 180)
        }
    }

    /// SSB button 27, VOX DELAY — numeric like BK-DELAY, same popover
    /// `Stepper` treatment stepping through `RigDelayCode`'s 0-33 code range
    /// rather than milliseconds directly. Maps to the FTX-1's raw "VD" CAT
    /// command, which shares its non-linear encoding with BK-DELAY's "SD" —
    /// see `RigDelayCode`'s doc comment for a manual inconsistency in "VD"'s
    /// step-size note that's still unconfirmed against real hardware.
    private var voxDelayButton: some View {
        menuButtonShell {
            showingVoxDelayPopover = true
        } label: {
            twoLineLabel(top: "VOX DELAY", bottom: hub.rigState.voxDelayMs.map { "\($0) ms" } ?? "—")
        }
        .popover(isPresented: $showingVoxDelayPopover) {
            let currentCode = RigDelayCode.code(forMilliseconds: hub.rigState.voxDelayMs ?? 300) ?? 6
            Stepper(
                "\(RigDelayCode.milliseconds(forCode: currentCode) ?? 300) ms",
                value: Binding(
                    get: { currentCode },
                    set: { code in
                        if let ms = RigDelayCode.milliseconds(forCode: code) {
                            hub.send(.setVoxDelay(ms: ms))
                        }
                    }
                ),
                in: 0...(RigDelayCode.allValuesMs.count - 1)
            )
            .padding()
            .frame(width: 180)
        }
    }

    private var displayedRFPowerLevel: Double {
        isDraggingRFPower ? localRFPowerLevel : (hub.rigState.powerLevel ?? 0)
    }

    private static func rfPowerLabel(_ level: Double?) -> String {
        guard let level else { return "—" }
        return "\(Int((level * 100).rounded()))W"
    }

    private static func displayLevelLabel(_ dB: Double?) -> String {
        guard let dB else { return "—" }
        return String(format: "%+.1f dB", dB)
    }

    /// SSB button 3, D-PEAK (spectrum scope peak-hold level, LV1-LV5) —
    /// single-tap-cycles-to-next like IPO/AMP (button 10) rather than a
    /// popover `Stepper`, matching a physical MENU button's own behavior for
    /// a small fixed choice set. Maps to "SS"'s PEAK sub-function (P2=1).
    private var displayPeakButton: some View {
        menuButtonShell {
            hub.send(.setDisplayPeak(((hub.rigState.displayPeak ?? 0) + 1) % 5))
        } label: {
            twoLineLabel(top: "D-PEAK", bottom: Self.displayPeakLabel(hub.rigState.displayPeak))
        }
    }

    private static func displayPeakLabel(_ level: Int?) -> String {
        guard let level else { return "—" }
        return "LV\(level + 1)"
    }

    /// 0 reads as "OFF" (see `moniLevelButton`); `nil` (no poll yet) as "—".
    private static func moniLevelLabel(_ level: Int?) -> String {
        guard let level else { return "—" }
        return level == 0 ? "OFF" : "\(level)"
    }

    /// IPO/AMP (button 10, SSB page) cycles 0/1/2 on each tap rather than
    /// opening a popover, matching a physical MENU button's own behavior for
    /// a small fixed set of choices (unlike CW SPEED/PITCH/BK-DELAY/MONI
    /// LEVEL's wide numeric ranges, which need a Stepper).
    private static func preampLabel(_ mode: Int?) -> String {
        switch mode {
        case 0: "IPO"
        case 1: "AMP1"
        case 2: "AMP2"
        default: "—"
        }
    }

    /// SSB button 12, AGC — displays raw "GT0"'s reported mode (0-6, see
    /// `RigState.agcMode`), collapsing the three AUTO sub-states (4-6) to
    /// one "AUTO" label since the rig itself doesn't distinguish them as
    /// separate user-facing settings.
    private static func agcLabel(_ mode: Int?) -> String {
        switch mode {
        case 0: "OFF"
        case 1: "FAST"
        case 2: "MID"
        case 3: "SLOW"
        case 4, 5, 6: "AUTO"
        default: "—"
        }
    }

    /// Collapses `RigState.agcMode`'s 0-6 range down to the 0-4 range the
    /// "GT" command's Set side actually accepts, so tapping AGC while it's
    /// reading back an AUTO sub-state (5/6) still cycles OFF -> FAST -> MID
    /// -> SLOW -> AUTO -> OFF like every other value, rather than wrapping
    /// at the wrong point.
    private static func agcCollapsedMode(_ mode: Int?) -> Int {
        switch mode {
        case 5, 6: 4
        case let m? where (0...4).contains(m): m
        default: 0
        }
    }

    /// MESSAGE/PLAY/RECORD (CW MESSAGE memory, buttons 19-21) are wired to
    /// real CAT commands — `RigCommand.selectCWMessageChannel`/
    /// `.playCWMessage`/`.setCWMessageRecording`, still implemented in
    /// `CommandQueue` — but behaved unreliably against the real rig and
    /// this is low-priority, so they're deprioritized rather than debugged
    /// further right now. Left visible-but-disabled (rather than removed
    /// or reverted to a plain numbered placeholder) so the commands and
    /// `RigState.cwMessageStatus` plumbing are ready to reconnect once
    /// this gets revisited.
    private func disabledCWMessageButton(top: String) -> some View {
        disabledPlaceholderButton(top: top)
    }

    /// SSB button 21, TXW. Wired end-to-end (`RigCommand.setTXW`, raw "TS"
    /// CAT command) and confirmed it *works* against real hardware — but
    /// the user doesn't know what TXW actually does or use it, so rather
    /// than surface a live toggle for a function that's a mystery in
    /// practice, this is deprioritized the same way CW MESSAGE/PLAY/RECORD
    /// are above: visible-but-disabled, plumbing left in place
    /// (`RigState.txwEnabled`, `CommandQueue`, `HubService`'s optimistic-
    /// apply + poll) so it's ready to reconnect if a future need for it
    /// turns up.
    private var disabledTXWButton: some View {
        disabledPlaceholderButton(top: "TXW")
    }

    /// Visible-but-disabled placeholder for a button whose rig label is
    /// known but which isn't wired to a CAT command yet (either because none
    /// exists, like SSB's D-COLOR, or because it's deprioritized, like CW
    /// MESSAGE/PLAY/RECORD and TXW above) — shows the real name instead of a
    /// plain numbered placeholder, without implying it's tappable.
    private func disabledPlaceholderButton(top: String) -> some View {
        menuButtonShell {
            // Deliberately a no-op — see callers' doc comments above.
        } label: {
            twoLineLabel(top: top, bottom: "—", colorizeValue: false)
                .foregroundStyle(.secondary)
        }
        .disabled(true)
    }

    /// FM/C4FM's APRS S.LIST/M.LIST (see `menuButton(for:)`'s doc comment
    /// for why these have no CAT path at all). Live wherever
    /// `hub.supportsAPRSDecoding` is true — opens a dedicated `Window`
    /// scene (`windowID`, declared only in the Mac app target) rather than
    /// a sheet, since a station/message list is meant to stay open
    /// alongside the main window while operating, not block it. Falls back
    /// to the same disabled placeholder every other CAT-less button on
    /// this page uses when unsupported (mobile clients today).
    @ViewBuilder
    private func aprsListButton(bottom: String, windowID: String) -> some View {
        if hub.supportsAPRSDecoding {
            menuButtonShell {
                openWindow(id: windowID)
            } label: {
                twoLineLabelEqualSize(top: "APRS", bottom: bottom)
            }
        } else {
            disabledPlaceholderButtonEqualSize(top: "APRS", bottom: bottom)
        }
    }

    /// Like `disabledPlaceholderButton`, but for a button whose two rig-label
    /// lines are both short label words rather than a name/value pair — same
    /// reasoning as `twoLineLabelEqualSize` vs `twoLineLabel`.
    private func disabledPlaceholderButtonEqualSize(top: String, bottom: String) -> some View {
        menuButtonShell {
            // Deliberately a no-op — see callers' doc comments above.
        } label: {
            twoLineLabelEqualSize(top: top, bottom: bottom)
                .foregroundStyle(.secondary)
        }
        .disabled(true)
    }

    /// For `hiddenCWItems` — same shell/sizing as every other button (so
    /// the grid's row heights stay aligned with neighboring visible
    /// buttons) but fully invisible and non-interactive, since these item
    /// numbers have no real function on the CW page at all.
    private func hiddenButtonPlaceholder(for item: Int) -> some View {
        menuButtonShell {
            // No-op — this item number has no function on the CW page.
        } label: {
            Text("\(item)")
                .font(.system(.body, design: .monospaced))
        }
        .opacity(0)
        .disabled(true)
        .allowsHitTesting(false)
    }

    private func menuButtonShell(disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    /// The bottom line is the button's current *setting* — colorized via
    /// `AppearanceSettings.buttonValueColor` (orange by default), matching
    /// how the rig's own MENU display shows the function name in white and
    /// the setting in orange. `colorizeValue: false` opts a caller out
    /// entirely (rather than passing `.secondary`) so an ancestor's own
    /// `.foregroundStyle` (e.g. `disabledPlaceholderButton`'s dimming) isn't
    /// overridden by an explicit style set here.
    private func twoLineLabel(top: String, bottom: String, colorizeValue: Bool = true) -> some View {
        VStack(spacing: 2) {
            Text(top).font(.caption2)
            if colorizeValue {
                Text(bottom)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle((ButtonValueColor(rawValue: buttonValueColorRawValue) ?? .orange).color)
            } else {
                Text(bottom)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    /// Like `twoLineLabel`, but both lines share one font size — used by
    /// `deepSettingsButton`, where top/bottom are both short label words
    /// (e.g. "RADIO" / "SETTING") rather than a name/value pair, so the
    /// size split that suits every other button's name+value labels looks
    /// mismatched here.
    private func twoLineLabelEqualSize(top: String, bottom: String) -> some View {
        VStack(spacing: 2) {
            Text(top).font(.caption2)
            Text(bottom).font(.caption2)
        }
    }
}

#if DEBUG
/// Preview-only stand-in for a real controller (`HubService`/
/// `RigClientViewModel`) — this package can't depend on either app target,
/// so `MenuPageView`'s preview needs its own minimal `RigController`.
@MainActor
private final class PreviewRigController: ObservableObject, RigController {
    @Published var rigState = RigState()
    func send(_ command: RigCommand) {}
}

#Preview {
    MenuPageView<PreviewRigController>()
        .environmentObject(PreviewRigController())
        .padding(40)
        .frame(width: 560)
}
#endif

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
    /// button 15 is antenna tuning (`RigCommand.triggerAntennaTune`,
    /// single-tap momentary action like CW page's ZIN), button 16 is the
    /// antenna tuner on/off (`RigCommand.setTuner`, single-tap toggle like
    /// MOX/ATT). Button 17 has no rig function on this page — confirmed
    /// against the real MENU display, same reasoning as `hiddenCWItems`
    /// below — and renders invisibly via `hiddenButtonPlaceholder`.
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
    /// `hiddenButtonPlaceholder`. Everything else is still a numbered
    /// placeholder pending real per-item functions.
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
            menuButtonShell {
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
        } else if selectedPage == .ssb, item == 15 {
            menuButtonShell {
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
    /// `BreakInDelay`), so the stepper steps through `BreakInDelay`'s 0-33
    /// code range rather than milliseconds directly, converting to/from
    /// ms only at the `RigCommand` boundary.
    private var bkDelayButton: some View {
        menuButtonShell {
            showingBKDelayPopover = true
        } label: {
            twoLineLabel(top: "BK-DELAY", bottom: hub.rigState.bkDelayMs.map { "\($0) ms" } ?? "—")
        }
        .popover(isPresented: $showingBKDelayPopover) {
            let currentCode = BreakInDelay.code(forMilliseconds: hub.rigState.bkDelayMs ?? 300) ?? 6
            Stepper(
                "\(BreakInDelay.milliseconds(forCode: currentCode) ?? 300) ms",
                value: Binding(
                    get: { currentCode },
                    set: { code in
                        if let ms = BreakInDelay.milliseconds(forCode: code) {
                            hub.send(.setBreakInDelay(ms: ms))
                        }
                    }
                ),
                in: 0...(BreakInDelay.allValuesMs.count - 1)
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

    private var displayedRFPowerLevel: Double {
        isDraggingRFPower ? localRFPowerLevel : (hub.rigState.powerLevel ?? 0)
    }

    private static func rfPowerLabel(_ level: Double?) -> String {
        guard let level else { return "—" }
        return "\(Int((level * 100).rounded()))%"
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

    /// Visible-but-disabled placeholder for a button whose rig label is
    /// known but which isn't wired to a CAT command yet (either because none
    /// exists, like SSB's D-COLOR, or because it's deprioritized, like CW
    /// MESSAGE/PLAY/RECORD above) — shows the real name instead of a bare
    /// numbered placeholder, without implying it's tappable.
    private func disabledPlaceholderButton(top: String) -> some View {
        menuButtonShell {
            // Deliberately a no-op — see callers' doc comments above.
        } label: {
            twoLineLabel(top: top, bottom: "—", colorizeValue: false)
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

    private func menuButtonShell(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
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

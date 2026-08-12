import FTX1Core
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

/// Grid of buttons mirroring one of the FTX-1's three menu pages. Layout
/// only for now — each button is a numbered placeholder; actual per-item
/// functions (which menu number maps to which CAT command) land once the
/// layout itself is confirmed against the real rig.
struct MenuPageView: View {
    @EnvironmentObject private var hub: HubService
    @State private var selectedPage: MenuPage = .ssb
    @State private var showingCWSpeedPopover = false
    @State private var showingCWPitchPopover = false
    @State private var showingBKDelayPopover = false
    @State private var showingMoniLevelPopover = false

    /// Matches the rig's own page size — each physical menu page holds up
    /// to 28 items.
    private static let itemsPerPage = 28
    private static let columns = 7

    /// CW page item numbers with no corresponding rig function — confirmed
    /// against the real MENU display, not just "not yet wired." Rendered
    /// as invisible (not just unlabeled) placeholders so they don't get
    /// mistaken for still-pending work, while keeping the grid's row
    /// alignment intact.
    private static let hiddenCWItems: Set<Int> = [3, 4, 5, 6, 7, 15, 16, 17, 18, 23, 24, 25, 26, 27]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Menu page", selection: $selectedPage) {
                ForEach(MenuPage.allCases) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: Self.columns),
                spacing: 6
            ) {
                ForEach(1...Self.itemsPerPage, id: \.self) { item in
                    menuButton(for: item)
                }
            }
        }
    }

    /// Button 1 on every page is the rig's own page-select button (pressing
    /// it on the real MENU display cycles 1/3 → 2/3 → 3/3), so it gets a
    /// two-line "PAGE n/3" / mode-name label instead of a plain number.
    /// Buttons 22 and 28 are left/right nav to the previous/next page in
    /// that cycle, shared by whichever pages don't repurpose the slot:
    /// SSB has its own RF POWER at 22, so nav-left only shows on CW/FM;
    /// FM/C4FM has its own APRS SETTING at 28, so nav-right only shows on
    /// SSB/CW.
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
        } else if selectedPage == .cw, Self.hiddenCWItems.contains(item) {
            hiddenButtonPlaceholder(for: item)
        } else {
            menuButtonShell {
                // Not yet wired to a CAT command — layout only.
            } label: {
                Text("\(item)")
                    .font(.system(.body, design: .monospaced))
            }
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
        menuButtonShell {
            // Deliberately a no-op — see doc comment above.
        } label: {
            twoLineLabel(top: top, bottom: "—")
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

    private func twoLineLabel(top: String, bottom: String) -> some View {
        VStack(spacing: 2) {
            Text(top).font(.caption2)
            Text(bottom).font(.system(.body, design: .monospaced))
        }
    }
}

#Preview {
    MenuPageView()
        .environmentObject(HubService())
        .padding(40)
        .frame(width: 560)
}

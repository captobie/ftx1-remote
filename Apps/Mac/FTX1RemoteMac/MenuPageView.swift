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
    /// CW button 2 is monitor level (`RigCommand.setMoniLevel`), button 8
    /// is the electronic keyer (`RigCommand.setKeyer`), button 9 is
    /// break-in (`RigCommand.setBreakIn`), button 10 is keyer speed
    /// (`RigCommand.setCWSpeed`), button 11 is CW pitch
    /// (`RigCommand.setCWPitch`), button 12 is break-in delay
    /// (`RigCommand.setBreakInDelay`), button 13 is zero-in
    /// (`RigCommand.triggerZeroIn`), button 14 is CW spot
    /// (`RigCommand.setCWSpot`). Everything else is still a numbered
    /// placeholder pending real per-item functions.
    @ViewBuilder
    private func menuButton(for item: Int) -> some View {
        if item == 1 {
            menuButtonShell {
                // Not yet wired — mirrors the rig's own page-select button.
            } label: {
                twoLineLabel(top: "PAGE \(selectedPage.pageNumber)/3", bottom: selectedPage.rawValue)
            }
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
    /// sub-value (P1=1) — see `RigState.moniLevel` — not MONI on/off,
    /// which shares the "ML" mnemonic under P1=0 but isn't exposed here.
    private var moniLevelButton: some View {
        menuButtonShell {
            showingMoniLevelPopover = true
        } label: {
            twoLineLabel(top: "MONI LEVEL", bottom: hub.rigState.moniLevel.map { "\($0)" } ?? "—")
        }
        .popover(isPresented: $showingMoniLevelPopover) {
            Stepper(
                "\(hub.rigState.moniLevel ?? 50)",
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

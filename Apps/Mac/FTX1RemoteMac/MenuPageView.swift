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
    /// CW button 8 is the electronic keyer (`RigCommand.setKeyer`), button 9
    /// is break-in (`RigCommand.setBreakIn`). Everything else is still a
    /// numbered placeholder pending real per-item functions.
    @ViewBuilder
    private func menuButton(for item: Int) -> some View {
        if item == 1 {
            menuButtonShell {
                // Not yet wired — mirrors the rig's own page-select button.
            } label: {
                twoLineLabel(top: "PAGE \(selectedPage.pageNumber)/3", bottom: selectedPage.rawValue)
            }
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
        } else {
            menuButtonShell {
                // Not yet wired to a CAT command — layout only.
            } label: {
                Text("\(item)")
                    .font(.system(.body, design: .monospaced))
            }
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

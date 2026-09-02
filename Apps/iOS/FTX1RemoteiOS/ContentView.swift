import FTX1Core
import SwiftUI

/// Focused single-rig-control view (see repo root CLAUDE.md) — no attempt
/// to cram the Mac's dense multi-pane layout in here. Real VFO/mode/PTT
/// controls land once this skeleton is wired up further.
struct ContentView: View {
    @EnvironmentObject private var viewModel: RigClientViewModel
    @AppStorage("hubHost") private var host: String = ""
    @State private var isPTTPressed = false

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.connectionState != .connected {
                TextField("Mac hostname (Tailscale)", text: $host)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }

            connectButton

            if viewModel.connectionState == .connected {
                FrequencyDisplay(
                    frequencyHz: viewModel.rigState.frequencyHz,
                    mode: viewModel.rigState.mode.displayName,
                    onSetFrequency: { viewModel.send(.setFrequency(hz: $0)) }
                )
                if let swr = viewModel.rigState.swr {
                    Text("SWR \(swr, specifier: "%.2f")")
                        .font(.system(.body, design: .monospaced))
                }
                pttButton
                modeGrid
            }
        }
        .padding(24)
    }

    /// Grid of mode buttons under PTT — iOS has no room for the Mac's
    /// segmented `Picker`, and a grid keeps every mode a single tap away
    /// instead of buried in a menu. 4 columns fits all 8 `RigMode` cases
    /// (excluding `.unknown`) in two rows on an iPhone-width screen.
    private var modeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
            ForEach(RigMode.allCases.filter { $0 != .unknown }, id: \.self) { mode in
                Button {
                    viewModel.send(.setMode(mode))
                } label: {
                    Text(mode.displayName)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(mode == viewModel.rigState.mode ? Color.accentColor : Color.gray.opacity(0.25))
                        .foregroundStyle(mode == viewModel.rigState.mode ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Momentary press-and-hold, not a toggle — keys on touch-down and
    /// unkeys on release, matching how PTT actually works. A plain
    /// `Button` only fires on release, so this uses a zero-distance
    /// `DragGesture` instead (fires `onChanged` immediately on touch-down,
    /// `onEnded` on release). `isPTTPressed` guards against sending
    /// `.setPTT(true)` repeatedly while `onChanged` keeps firing during
    /// the hold.
    private var pttButton: some View {
        Text(viewModel.rigState.ptt ? "TRANSMITTING" : "PTT")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(viewModel.rigState.ptt ? Color.red : Color.gray.opacity(0.25))
            .foregroundStyle(viewModel.rigState.ptt ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPTTPressed else { return }
                        isPTTPressed = true
                        viewModel.send(.setPTT(true))
                    }
                    .onEnded { _ in
                        isPTTPressed = false
                        viewModel.send(.setPTT(false))
                    }
            )
    }

    /// Replaces the old "Connect" button + separate tap-to-disconnect
    /// status text with a single button whose label and color reflect
    /// `connectionState`, same pattern as Mac/iPad's `ContentView`.
    private var connectButton: some View {
        Button {
            if viewModel.connectionState == .connected {
                viewModel.disconnect()
            } else {
                viewModel.connect(toHost: host)
            }
        } label: {
            Text(viewModel.connectionState == .connected ? "Connected" : "Disconnected")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(viewModel.connectionState == .connected ? Color.green : Color.red)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.connectionState != .connected && host.isEmpty)
    }
}

#Preview {
    ContentView()
        .environmentObject(RigClientViewModel())
}

import FTX1Core
import SwiftUI

/// Which receiver the iPhone screens show — one at a time, for space.
enum DisplaySide: String, CaseIterable {
    case main
    case sub

    static let storageKey = "iphone.displaySide"

    var label: String {
        switch self {
        case .main: "MAIN"
        case .sub: "SUB"
        }
    }
}

/// Top level: picks between the normal Mac-hub connection and the
/// Pi-direct proof of concept (`PiDirectView`). Switching disconnects the
/// side being left, so only one link is ever live. While the chosen route
/// is connected, the route switch gives way to the MAIN/SUB selector.
struct ContentView: View {
    enum ConnectionRoute: String, CaseIterable {
        case macHub
        case piDirect

        var label: String {
            switch self {
            case .macHub: String(localized: "content.macHub")
            case .piDirect: String(localized: "content.piDirect")
            }
        }
    }

    @EnvironmentObject private var hubViewModel: RigClientViewModel
    @EnvironmentObject private var piViewModel: PiDirectViewModel
    @AppStorage("connectionRoute") private var route: ConnectionRoute = .macHub
    @AppStorage(DisplaySide.storageKey) private var side: DisplaySide = .main

    /// Connecting/retrying still shows the route switch, as on the iPad.
    private var isConnected: Bool {
        switch route {
        case .macHub: hubViewModel.connectionState == .connected
        case .piDirect: piViewModel.connectionState == .connected
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isConnected {
                    Picker("common.receiver", selection: $side) {
                        ForEach(DisplaySide.allCases, id: \.self) { side in
                            Text(side.label).tag(side)
                        }
                    }
                } else {
                    Picker("common.connection", selection: $route) {
                        ForEach(ConnectionRoute.allCases, id: \.self) { route in
                            Text(route.label).tag(route)
                        }
                    }
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 12)

            switch route {
            case .macHub: HubControlView()
            case .piDirect: PiDirectView()
            }
            Spacer(minLength: 0)
        }
        .onChange(of: route) { _, newRoute in
            switch newRoute {
            case .macHub: piViewModel.disconnect()
            case .piDirect: hubViewModel.disconnect()
            }
        }
    }
}

/// Focused single-rig-control view (see repo root CLAUDE.md) — no attempt
/// to cram the Mac's dense multi-pane layout in here. Real VFO/mode/PTT
/// controls land once this skeleton is wired up further.
struct HubControlView: View {
    @EnvironmentObject private var viewModel: RigClientViewModel
    @AppStorage("hubHost") private var host: String = ""
    @AppStorage(DisplaySide.storageKey) private var side: DisplaySide = .main
    @State private var isPTTPressed = false

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.connectionState != .connected {
                TextField("content.macHostnameTailscale", text: $host)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }

            connectButton

            if viewModel.connectionState == .connected {
                SideDisplay(side: side, state: viewModel.rigState, send: viewModel.send)
                pttButton
            }
        }
        .padding(24)
    }

    /// Momentary press-and-hold, not a toggle — keys on touch-down and
    /// unkeys on release, matching how PTT actually works. A plain
    /// `Button` only fires on release, so this uses a zero-distance
    /// `DragGesture` instead (fires `onChanged` immediately on touch-down,
    /// `onEnded` on release). `isPTTPressed` guards against sending
    /// `.setPTT(true)` repeatedly while `onChanged` keeps firing during
    /// the hold.
    /// Mirrors `HubService.send(_:)`'s TX gate (transmit-enabled toggle AND
    /// inside an amateur allocation) so the button visibly reflects why a
    /// press won't do anything — the real enforcement happens on the Mac
    /// hub regardless, since every command here goes out over the
    /// WebSocket, but a silent no-op with no visual cue would be confusing.
    private var canTransmit: Bool {
        viewModel.rigState.transmitEnabled && BandPlan.band(containing: viewModel.rigState.frequencyHz) != nil
    }

    private var pttButton: some View {
        Text(viewModel.rigState.ptt ? "TRANSMITTING" : "PTT")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(viewModel.rigState.ptt ? Color.red : Color.gray.opacity(0.25))
            .foregroundStyle(viewModel.rigState.ptt ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(canTransmit ? 1 : 0.4)
            .help(
                viewModel.rigState.transmitEnabled
                    ? (canTransmit ? "" : "common.transmitDisabledOutsideAn")
                    : "common.transmitDisabled"
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPTTPressed, canTransmit else { return }
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
            Text(viewModel.connectionState == .connected ? "common.connected" : "common.disconnected")
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

/// The selected receiver's frequency, S-meter and mode grid — MAIN's or
/// SUB's, tuned with `.setFrequency`/`.setMode` or their SUB
/// counterparts. Shared by the hub and Pi-direct screens; `extra` goes
/// between the meter and the mode grid (Pi direct's audio controls).
struct SideDisplay<Extra: View>: View {
    let side: DisplaySide
    let state: RigState
    let send: (RigCommand) -> Void
    @ViewBuilder var extra: Extra

    init(side: DisplaySide, state: RigState, send: @escaping (RigCommand) -> Void, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.side = side
        self.state = state
        self.send = send
        self.extra = extra()
    }

    var body: some View {
        switch side {
        case .main:
            FrequencyDisplay(
                frequencyHz: state.frequencyHz,
                mode: state.mode.displayName,
                onSetFrequency: { send(.setFrequency(hz: $0)) }
            )
            // Same bar as the iPad's MAIN strip; while transmitting it
            // shows the TX meter (tap to pick) with the SWR under it.
            BarSMeterView(
                label: "MAIN",
                smeterDb: state.smeterDb,
                txReadings: MeterReadings(powerWatts: state.powerWatts, swr: state.swr, tx: state.txMeters),
                ptt: state.ptt
            )
            extra
            ModeGrid(selected: state.mode) { send(.setMode($0)) }
        case .sub:
            FrequencyDisplay(
                frequencyHz: state.secondaryFrequencyHz,
                mode: state.secondaryMode?.displayName ?? "—",
                onSetFrequency: { send(.setSecondaryFrequency(hz: $0)) }
            )
            // The TX readings are Main's, so SUB always shows its S-meter.
            BarSMeterView(label: "SUB", smeterDb: state.subSmeterDb, txReadings: nil, ptt: state.ptt)
            extra
            ModeGrid(selected: state.secondaryMode ?? .unknown) { send(.setSecondaryMode($0)) }
        }
    }
}

/// Grid of mode buttons — iOS has no room for the Mac's segmented
/// `Picker`, and a grid keeps every mode a single tap away instead of
/// buried in a menu. 4 columns fits all 8 `RigMode` cases (excluding
/// `.unknown`) in two rows on an iPhone-width screen. Shared by the hub
/// and Pi-direct views.
struct ModeGrid: View {
    let selected: RigMode
    let onSelect: (RigMode) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
            ForEach(RigMode.allCases.filter { $0 != .unknown }, id: \.self) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.displayName)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(mode == selected ? Color.accentColor : Color.gray.opacity(0.25))
                        .foregroundStyle(mode == selected ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RigClientViewModel())
        .environmentObject(PiDirectViewModel(logSubsystem: "com.ftx1remote.ios"))
}

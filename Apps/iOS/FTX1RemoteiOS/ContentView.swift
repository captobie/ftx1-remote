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
/// to cram the Mac's dense multi-pane layout in here. Hold-to-talk PTT
/// along the bottom sends the microphone to the hub, as on the iPad.
struct HubControlView: View {
    @EnvironmentObject private var viewModel: RigClientViewModel
    @AppStorage("hubHost") private var host: String = ""
    @AppStorage(DisplaySide.storageKey) private var side: DisplaySide = .main
    @Environment(\.scenePhase) private var scenePhase

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

            HStack(spacing: 12) {
                connectButton
                if viewModel.connectionState == .connected {
                    transmitLockButton
                }
            }

            if viewModel.connectionState == .connected {
                SideDisplay(side: side, state: viewModel.rigState, send: viewModel.send)
            }

            Spacer(minLength: 0)

            if viewModel.connectionState == .connected {
                if let problem = viewModel.transmitProblem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                PTTButton(
                    isTransmitting: viewModel.isTransmitting || viewModel.rigState.ptt,
                    blockReason: transmitBlockReason,
                    onPress: viewModel.startTransmit,
                    onRelease: viewModel.stopTransmit
                )
            }
        }
        .padding(24)
        // A press can't be released from the background; don't stay keyed.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stopTransmit() }
        }
    }

    /// The hub's Enable Transmit, as on the iPad's hub screen: tapping it
    /// sets the hub's toggle (`.setTransmitEnabled`), and the button
    /// follows the state the hub echoes back.
    private var transmitLockButton: some View {
        let enabled = viewModel.rigState.transmitEnabled
        return TransmitLockButton(
            isEnabled: enabled,
            enabledLabel: "content.transmitEnabledOnThe",
            disabledLabel: "content.transmitDisabledOnThe"
        ) {
            viewModel.send(.setTransmitEnabled(!enabled))
        }
    }

    /// Mirrors `HubService.send(_:)`'s TX gate (transmit-enabled toggle AND
    /// inside an amateur allocation) so the PTT button visibly reflects why
    /// a press won't do anything — the real enforcement happens on the hub
    /// regardless, but a silent no-op with no visual cue would be confusing.
    private var transmitBlockReason: String? {
        guard viewModel.rigState.transmitEnabled else { return String(localized: "content.transmitDisabledOnTheMac") }
        guard BandPlan.band(containing: viewModel.rigState.frequencyHz) != nil else {
            return String(localized: "common.transmitDisabledOutsideAn")
        }
        return nil
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

/// The selected receiver's frequency, S-meter and band/mode/power row —
/// MAIN's or SUB's, tuned with `.setFrequency`/`.setMode` or their SUB
/// counterparts. Shared by the hub and Pi-direct screens; `extra` goes
/// between the meter and the row (Pi direct's audio controls).
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
            ControlRow(
                currentBand: BandPicker.name(containing: state.frequencyHz),
                onSetBand: { send(.setBand($0)) },
                mode: state.mode,
                onSetMode: { send(.setMode($0)) },
                powerLevel: state.powerLevel,
                onSetPower: { send(.setPowerLevel($0)) }
            )
        case .sub:
            FrequencyDisplay(
                frequencyHz: state.secondaryFrequencyHz,
                mode: state.secondaryMode?.displayName ?? "—",
                onSetFrequency: { send(.setSecondaryFrequency(hz: $0)) }
            )
            // The TX readings are Main's, so SUB always shows its S-meter.
            BarSMeterView(label: "SUB", smeterDb: state.subSmeterDb, txReadings: nil, ptt: state.ptt)
            extra
            ControlRow(
                currentBand: state.secondaryFrequencyHz.flatMap(BandPicker.name(containing:)),
                onSetBand: setSubBand,
                mode: state.secondaryMode ?? .unknown,
                onSetMode: { send(.setSecondaryMode($0)) },
                powerLevel: state.powerLevel,
                onSetPower: { send(.setPowerLevel($0)) }
            )
        }
    }

    /// `.setBand` is MAIN's (and, on the hub, its band memory), so SUB
    /// goes to the band's default frequency with its mode kept — and a
    /// general-coverage segment's default mode, as Pi direct does for MAIN.
    private func setSubBand(_ name: String) {
        if let band = BandPlan.band(named: name) {
            send(.setSecondaryFrequency(hz: band.defaultFrequencyHz))
        } else if let segment = GeneralCoverageSegments.segment(named: name) {
            send(.setSecondaryFrequency(hz: segment.defaultFrequencyHz))
            send(.setSecondaryMode(segment.defaultMode))
        }
    }
}

/// RF power, band and mode on one line, each a drop-down tile
/// (`DropDownTile`): a power button whose popover holds a slider, and
/// menus over the shared `BandPicker` and a mode picker. Power is the
/// rig's one RF POWER setting, whichever side is shown.
struct ControlRow: View {
    let currentBand: String?
    let onSetBand: (String) -> Void
    let mode: RigMode
    let onSetMode: (RigMode) -> Void
    let powerLevel: Double?
    let onSetPower: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            PowerControl(level: powerLevel, onSet: onSetPower)
            Menu {
                BandPicker(currentBand: currentBand, onSetBand: onSetBand)
                    .pickerStyle(.inline)
            } label: {
                DropDownTile(text: currentBand ?? "—")
            }
            .accessibilityLabel("common.band")
            Menu {
                Picker("sideDisplay.mode", selection: Binding(
                    get: { mode },
                    set: { if $0 != .unknown { onSetMode($0) } }
                )) {
                    ForEach(RigMode.allCases.filter { $0 != .unknown }, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                DropDownTile(text: mode == .unknown ? "—" : mode.displayName)
            }
            .accessibilityLabel("sideDisplay.mode")
        }
    }
}

/// The face of a `ControlRow` drop-down: the current value and a chevron
/// on an accent-tinted, outlined tile filling its third of the row, so the
/// whole tile is the tap target and reads as a control, not a label.
struct DropDownTile: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// RF POWER as a drop-down: the button shows the setting in watts (the
/// rig reads 0–1 as 0–100 W), its popover a 5–100 W slider with 1 W
/// steps either side. The slider sends on release, not per tick. The hub
/// route doesn't update `rigState` optimistically, so the dragged or
/// stepped value is shown until the next read brings the new one back —
/// same as the MENU grid's RF POWER.
struct PowerControl: View {
    let level: Double?
    let onSet: (Double) -> Void

    @State private var isShowingPopover = false
    @State private var isDragging = false
    @State private var dragLevel: Double = 0
    @State private var pendingLevel: Double?

    private var displayedLevel: Double {
        if isDragging { return dragLevel }
        return max(pendingLevel ?? level ?? 0, RigState.minimumPowerLevel)
    }

    var body: some View {
        Button {
            isShowingPopover = true
        } label: {
            DropDownTile(text: Self.label(pendingLevel ?? level))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("sideDisplay.rfPower")
        .accessibilityValue(Text(verbatim: Self.label(pendingLevel ?? level)))
        .popover(isPresented: $isShowingPopover) {
            VStack(spacing: 8) {
                Text(verbatim: "RF POWER \(Self.label(displayedLevel))")
                    .font(.headline.monospacedDigit())
                HStack(spacing: 12) {
                    Button { step(by: -1) } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(displayedLevel <= RigState.minimumPowerLevel)
                    .accessibilityLabel("sideDisplay.decreasePower")
                    Slider(
                        value: Binding(get: { displayedLevel }, set: { dragLevel = $0 }),
                        in: RigState.minimumPowerLevel...1,
                        step: 0.01
                    ) { editing in
                        if editing {
                            dragLevel = displayedLevel
                            isDragging = true
                        } else {
                            isDragging = false
                            pendingLevel = dragLevel
                            onSet(dragLevel)
                        }
                    }
                    Button { step(by: 1) } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(displayedLevel >= 1)
                    .accessibilityLabel("sideDisplay.increasePower")
                }
            }
            .padding()
            .frame(width: 300)
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: level) { _, _ in
            pendingLevel = nil
        }
    }

    /// One watt per press, snapped to whole watts; quick presses add up
    /// before the next read.
    private func step(by watts: Int) {
        let current = (displayedLevel * 100).rounded()
        let next = min(max(current + Double(watts), RigState.minimumPowerLevel * 100), 100) / 100
        pendingLevel = next
        onSet(next)
    }

    private static func label(_ level: Double?) -> String {
        guard let level else { return "— W" }
        return "\(Int((level * 100).rounded())) W"
    }
}

#Preview {
    ContentView()
        .environmentObject(RigClientViewModel())
        .environmentObject(PiDirectViewModel(logSubsystem: "com.ftx1remote.ios"))
}

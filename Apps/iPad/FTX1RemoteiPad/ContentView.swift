import FTX1CW
import FTX1Core
import SwiftUI

/// Top level: picks between the normal desktop-hub connection
/// (`HubControlView`) and the Pi-direct proof of concept (`PiDirectView`),
/// same switch as the iPhone's. Switching disconnects the side being left,
/// so only one link is ever live. The switch is hidden while the chosen
/// route is connected — disconnect to get it back.
struct ContentView: View {
    enum ConnectionRoute: String, CaseIterable {
        // Raw value kept from when the hub was Mac-only, so a saved
        // `connectionRoute` still reads back.
        case desktopHub = "macHub"
        case piDirect

        var label: String {
            switch self {
            case .desktopHub: String(localized: "content.desktopHub")
            case .piDirect: String(localized: "content.piDirect")
            }
        }
    }

    @EnvironmentObject private var hubViewModel: RigClientViewModel
    @EnvironmentObject private var piViewModel: PiDirectViewModel
    /// The CW pane's sender, pointed at the route in use.
    @EnvironmentObject private var cwSender: CWSender
    @EnvironmentObject private var demo: DemoSession
    @AppStorage("connectionRoute") private var route: ConnectionRoute = .desktopHub

    var body: some View {
        VStack(spacing: 0) {
            if !isConnected {
                Picker("common.connection", selection: $route) {
                    ForEach(ConnectionRoute.allCases, id: \.self) { route in
                        Text(route.label).tag(route)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .padding(.horizontal, 32)
                .padding(.top, 12)
            }

            switch route {
            case .desktopHub: HubControlView()
            case .piDirect:
                // Demo Mode: the same screen on the demo's own objects;
                // the real model stays as it was.
                if let context = demo.context {
                    PiDirectView(isDemo: true)
                        .demoEnvironment(context)
                } else {
                    PiDirectView()
                }
            }
        }
        .onChange(of: route, initial: true) { _, newRoute in
            switch newRoute {
            case .desktopHub: cwSender.use(hubViewModel)
            case .piDirect: cwSender.use(piViewModel)
            }
        }
        .onChange(of: route) { _, newRoute in
            switch newRoute {
            case .desktopHub: piViewModel.disconnect()
            case .piDirect: hubViewModel.disconnect()
            }
        }
    }

    private var isConnected: Bool {
        if demo.context != nil { return true }
        return switch route {
        case .desktopHub: hubViewModel.connectionState == .connected
        case .piDirect: piViewModel.connectionState == .connected
        }
    }
}

/// Dense multi-pane control UI, modeled on the Mac's `ContentView` rather
/// than iPhone's single-focus flow (see repo root CLAUDE.md) — VFO A/B and
/// meters visible together, plus the numbered `MenuPageView` grid (whose
/// S.LIST/M.LIST swap in `APRSListPane` with the Mac's lists). Band
/// (MAIN only, VFO mode) and mode are picked in each VFO box's frequency
/// popover. Unlike the Mac, this is a WebSocket client only
/// (`RigClientViewModel`), never touches `RigctldClient` directly.
struct HubControlView: View {
    @EnvironmentObject private var viewModel: RigClientViewModel
    @AppStorage("hubHost") private var host: String = ""
    /// Hubs this iPad has connected to (`RecentHostField`).
    @AppStorage(RecentHosts.hubKey) private var recentHosts: String = ""
    @AppStorage(AudioPlaybackSettings.volumeKey) private var mainAudioVolume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.squelchThresholdKey) private var mainAudioSquelchThreshold: Double = 0.015
    @AppStorage(AudioPlaybackSettings.subVolumeKey) private var subAudioVolume: Double = 0.8
    @AppStorage(AudioPlaybackSettings.subSquelchThresholdKey) private var subAudioSquelchThreshold: Double = 0.015
    @Environment(\.scenePhase) private var scenePhase
    /// S.LIST/M.LIST shown in place of the MENU grid (`APRSListPane`).
    @State private var aprsListKind: APRSListKind?
    /// The CW decoder shown in place of the MENU grid (`CWPane`).
    @State private var showingCW = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if viewModel.connectionState != .connected {
                        RecentHostField(placeholder: String(localized: "content.desktopHostnameTailscale"), host: $host, recentHosts: $recentHosts.recentHostList)
                    }
                    connectButton
                    if viewModel.connectionState == .connected {
                        PTTButton(
                            isTransmitting: viewModel.isTransmitting || viewModel.rigState.ptt,
                            blockReason: transmitBlockReason,
                            onPress: viewModel.startTransmit,
                            onRelease: viewModel.stopTransmit
                        )
                        transmitEnabledIndicator
                        Spacer()
                        rigButtons
                    }
                }
                .zIndex(1)
                .onChange(of: viewModel.connectionState) { _, state in
                    if state == .connected {
                        recentHosts = RecentHosts.encode(RecentHosts.remember(host, in: RecentHosts.decode(recentHosts)))
                    }
                }

                if let problem = viewModel.transmitProblem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    VFODisplayBox(label: "SUB", frequencyHz: viewModel.rigState.secondaryFrequencyHz, isActive: viewModel.rigState.singleReceive != true, mode: viewModel.rigState.secondaryMode?.displayName ?? "—", txRxLabel: viewModel.rigState.subTxRxLabel, callsign: viewModel.rigState.secondaryMode == .c4fm ? viewModel.rigState.c4fmCallsign : (viewModel.rigState.aprsSubActive ? viewModel.rigState.aprsSubLastCallsign : nil), reflector: viewModel.rigState.secondaryMode == .c4fm ? viewModel.rigState.c4fmReflector : nil, aprsActive: viewModel.rigState.aprsSubActive, onSetFrequency: { viewModel.send(.setSecondaryFrequency(hz: $0)) }, vfoMemoryMode: viewModel.rigState.subVfoMemoryMode, memoryChannel: viewModel.rigState.subMemoryChannel, memoryChannelTag: viewModel.rigState.subMemoryChannelTag, onSetMemoryChannel: { viewModel.send(.setSubMemoryChannel($0)) }, onStepMemoryChannel: { viewModel.send(.stepSubMemoryChannel(up: $0)) }, memoryScan: viewModel.rigState.memoryScan(on: .sub), currentMode: viewModel.rigState.secondaryMode, onSetMode: { viewModel.send(.setSecondaryMode($0)) }, memoryList: viewModel.memoryList, onRefreshMemoryList: { viewModel.send(.refreshMemoryList) })
                    VFODisplayBox(label: "MAIN", frequencyHz: viewModel.rigState.frequencyHz, isActive: true, mode: viewModel.rigState.mode.displayName, txRxLabel: viewModel.rigState.mainTxRxLabel, callsign: viewModel.rigState.mode == .c4fm ? viewModel.rigState.c4fmCallsign : (viewModel.rigState.aprsActive ? viewModel.rigState.aprsLastCallsign : nil), reflector: viewModel.rigState.mode == .c4fm ? viewModel.rigState.c4fmReflector : nil, aprsActive: viewModel.rigState.aprsActive, onSetFrequency: { viewModel.send(.setFrequency(hz: $0)) }, vfoMemoryMode: viewModel.rigState.vfoMemoryMode, memoryChannel: viewModel.rigState.memoryChannel, memoryChannelTag: viewModel.rigState.memoryChannelTag, onSetMemoryChannel: { viewModel.send(.setMemoryChannel($0)) }, onStepMemoryChannel: { viewModel.send(.stepMemoryChannel(up: $0)) }, memoryScan: viewModel.rigState.memoryScan(on: .main), currentMode: viewModel.rigState.mode, onSetMode: { viewModel.send(.setMode($0)) }, memoryList: viewModel.memoryList, onRefreshMemoryList: { viewModel.send(.refreshMemoryList) }, currentBand: viewModel.rigState.band, onSetBand: { viewModel.send(.setBand($0)) })
                }

                // Same SUB | MAIN columns as the VFO boxes above, so each
                // strip sits under its own receiver.
                HStack(spacing: 12) {
                    ChannelStrip(
                        label: "SUB",
                        smeterDb: viewModel.rigState.subSmeterDb,
                        txReadings: nil,
                        ptt: viewModel.rigState.ptt,
                        volume: $subAudioVolume,
                        squelchThreshold: $subAudioSquelchThreshold,
                        isMuted: viewModel.isSubAudioMuted,
                        engine: viewModel.subAudioEngine,
                        onToggleMute: viewModel.toggleSubAudioMuted
                    )
                    ChannelStrip(
                        label: "MAIN",
                        smeterDb: viewModel.rigState.smeterDb,
                        txReadings: MeterReadings(powerWatts: viewModel.rigState.powerWatts, swr: viewModel.rigState.swr, tx: viewModel.rigState.txMeters),
                        ptt: viewModel.rigState.ptt,
                        volume: $mainAudioVolume,
                        squelchThreshold: $mainAudioSquelchThreshold,
                        isMuted: viewModel.isMainAudioMuted,
                        engine: viewModel.audioEngine,
                        onToggleMute: viewModel.toggleMainAudioMuted
                    )
                }

                // The APRS pane covers the filter block and the grid both.
                VStack(alignment: .leading, spacing: 16) {
                    FilterPanel<RigClientViewModel>(spectrumStore: viewModel.filterSpectrum, isActive: viewModel.connectionState == .connected && aprsListKind == nil && !showingCW)
                    MenuPageView<RigClientViewModel>(showsPagePicker: false, onShowAPRSList: { aprsListKind = $0 })
                }
                .aprsListPane(
                    kind: $aprsListKind,
                    stations: viewModel.aprsList?.stations ?? [],
                    messages: viewModel.aprsList?.messages ?? [],
                    onClearHistory: nil
                )
                .cwPane(
                    isShowing: $showingCW,
                    isConnected: viewModel.connectionState == .connected,
                    rigInfo: CWRigInfo(state: viewModel.rigState, connected: viewModel.connectionState == .connected, transmitting: viewModel.isTransmitting),
                    singleReceive: viewModel.rigState.singleReceive == true
                ) {
                    CWSendSection<RigClientViewModel>()
                }
            }
            .padding(32)
        }
        // A press can't be released from the background; don't stay keyed.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stopTransmit() }
        }
    }

    /// The Mac's Enable Transmit, where the Pi-direct screen has its own
    /// lock button: locked (gray) blocks PTT, MOX, ANT TUNE and CW sending
    /// for every client; unlocked (red) allows them. Tapping it sets the
    /// Mac's toggle (`.setTransmitEnabled`, user decision 2026-10-14 — lock
    /// and unlock both); the button follows the state the Mac echoes back.
    private var transmitEnabledIndicator: some View {
        let enabled = viewModel.rigState.transmitEnabled
        return Button {
            viewModel.send(.setTransmitEnabled(!enabled))
        } label: {
            Image(systemName: enabled ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(enabled ? Color.white : Color.primary)
        }
        .buttonStyle(.bordered)
        .tint(enabled ? .red : nil)
        .accessibilityLabel(enabled ? "content.transmitEnabledOnThe" : "content.transmitDisabledOnThe")
    }

    /// Scan/Skip, V/M, swap and audio-channel override — the same buttons,
    /// in the same order, as the Pi-direct screen's top row. Unlike Pi
    /// direct, swap and V/M stay enabled while the rig scans: the hub stops
    /// the scan first (`HubService.memoryScanStop`). The speaker button is
    /// the Mac's own override (`HubService.audioChannelsSwapped`), which
    /// also decides what the relayed MAIN/SUB audio is.
    private var rigButtons: some View {
        let state = viewModel.rigState
        let audioSwapped = state.audioChannelsSwapped == true
        return HStack(spacing: 12) {
            CWPaneButton(isShowing: $showingCW, aprsListKind: $aprsListKind)

            MemoryScanButtons(state: state, isConnected: true, send: viewModel.send)

            // Against `.vfo`, not `.memory`, as on the Mac: the rig's other
            // channel modes (PMS, 5 MHz band...) must exit to VFO too.
            Button {
                viewModel.send(.setVFOMemoryMode(memory: state.vfoMemoryMode == .vfo))
            } label: {
                Text("V/M")
                    .fontWeight(state.vfoMemoryMode == .vfo ? .regular : .bold)
            }
            .disabled(state.vfoMemoryMode == nil)

            Button {
                viewModel.send(.swapActiveVFO)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .accessibilityLabel("common.swapMainAndSub")

            Button {
                viewModel.send(.setAudioChannelsSwapped(!audioSwapped))
            } label: {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(audioSwapped ? Color.white : Color.primary)
            }
            .tint(audioSwapped ? .orange : nil)
            // nil: a hub from before this override was on the wire.
            .disabled(state.audioChannelsSwapped == nil)
            .accessibilityLabel(audioSwapped ? "common.audioChannelsSwappedTap" : "common.swapAudioChannels")
        }
        .buttonStyle(.bordered)
        // Natural width, one line: with longer translations the row is
        // full in portrait, and PTT is the one that gives way.
        .lineLimit(1)
        .fixedSize()
    }

    /// Mirrors `HubService.send(_:)`'s TX gate (transmit-enabled toggle AND
    /// inside an amateur allocation) so the PTT button visibly reflects why
    /// a press won't do anything — the real enforcement happens on the Mac
    /// hub regardless, since every command here goes out over the
    /// WebSocket, but a silent no-op with no visual cue would be confusing.
    private var transmitBlockReason: String? {
        guard viewModel.rigState.transmitEnabled else { return String(localized: "content.transmitDisabledOnTheMac") }
        guard BandPlan.band(containing: viewModel.rigState.frequencyHz) != nil else {
            return String(localized: "common.transmitDisabledOutsideAn")
        }
        return nil
    }

    /// Replaces the old "Connect" button + separate tap-to-disconnect
    /// status text with a single button whose label and color reflect
    /// `connectionState`, same pattern as Mac's `ContentView`.
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

#Preview {
    ContentView()
        .environmentObject(RigClientViewModel())
        .environmentObject(PiDirectViewModel(logSubsystem: "com.ftx1remote.ipad"))
        .environmentObject(DemoSession())
}

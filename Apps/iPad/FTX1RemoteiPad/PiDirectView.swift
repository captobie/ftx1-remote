import FTX1CW
import FTX1Core
import SwiftUI

/// The iPad's Pi-direct proof-of-concept screen (see `PiDirectViewModel`):
/// a cut-down `HubControlView` — SUB/MAIN `VFODisplayBox`es (showing
/// everything the Mac's do: TX/RX tags, memory channel + tag,
/// scan state, SUB dimmed in single receive, and — with a WPSD host set —
/// the C4FM callsign/reflector), a meter + audio `ChannelStrip` under
/// each. Tapping a box's frequency tunes it and sets its mode (VFO mode)
/// or picks a memory channel from the list (Memory mode), MAIN and SUB
/// alike — not while the rig is scanning (see `PiDirectViewModel.send`).
///
/// The top row adds, once connected, the memory scan (`MemoryScanButtons`),
/// V/M (MAIN only), the Mac's swap (`SV`) and audio-channel override
/// (speaker, orange while swapped) — the model tracks the audio parity
/// across swaps like `HubService`.
///
/// Transmit (2026-10-09): hold-to-talk `PTTButton` right of Connected,
/// with the iPad's microphone streamed to the Pi's TX audio service, and a
/// lock button beside it — this route's own Enable Transmit (off by
/// default), since the Mac's toggle isn't in the path.
///
/// The hub screen's `MenuPageView` (2026-10-09) sits at the bottom,
/// running on `PiDirectViewModel` (a `RigController`): the same three
/// pages, with MOX/ANT TUNE behind this route's lock and RECORD/PLAY
/// unavailable as on the hub route; power is
/// the grid's RF POWER, as on the hub screen. MAIN's frequency popover has
/// the band picker too, without the hub's band memory (see
/// `PiDirectViewModel.send`).
///
/// APRS (2026-10-14): S.LIST/M.LIST show `APRSListPane` in place of the
/// grid, with this iPad's own decode (`PiDirectViewModel.aprsStore`); its
/// gear button turns decoding on and sets the frequency.
///
/// The filter block (`FilterPanel`, 2026-10-11) sits between the strips
/// and the grid, as on the hub screen, with the spectrum computed from this
/// route's own audio (`PiDirectViewModel.filterSpectrum`).
///
/// Unlike the iPhone's `PiDirectView` (single focused VFO, Main audio
/// only), this shows both receivers, as the hub screen does.
///
/// Demo Mode (2026-10-15): a "Demo Mode" button under the host fields,
/// shown while disconnected, runs this same screen against a simulated Pi
/// (`DemoSession`); `isDemo` is that copy, with a DEMO banner and "Exit
/// Demo" in place of Connected.
struct PiDirectView: View {
    /// The Demo Mode copy of this screen (`ContentView` hands it the
    /// demo's own objects).
    var isDemo = false
    @EnvironmentObject private var viewModel: PiDirectViewModel
    @EnvironmentObject private var demo: DemoSession
    @AppStorage("piHost") private var host: String = "ftx1pi"
    /// Pis this iPad has connected to (`RecentHostField`).
    @AppStorage(RecentHosts.piKey) private var recentHosts: String = ""
    /// This device's own copy of the Mac's WPSD host key; empty = no C4FM
    /// callsign/reflector lookup.
    @AppStorage(WPSDSettings.hostKey) private var wpsdHost: String = ""
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
                if isDemo { DemoBanner() }

                HStack {
                    if viewModel.connectionState != .connected && !isDemo {
                        RecentHostField(placeholder: String(localized: "common.piHostnameTailscale"), host: $host, recentHosts: $recentHosts.recentHostList)
                        TextField("piDirect.wpsdHotspotOptionalC4fm", text: $wpsdHost)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    connectButton
                    if viewModel.connectionState == .connected {
                        PTTButton(
                            isTransmitting: viewModel.isTransmitting || viewModel.rigState.ptt,
                            blockReason: viewModel.transmitBlockReason,
                            onPress: viewModel.startTransmit,
                            onRelease: viewModel.stopTransmit
                        )
                        transmitEnableButton
                        Spacer()
                        rigButtons
                    }
                }
                .zIndex(1)
                .onChange(of: viewModel.connectionState) { _, state in
                    // The demo connects to loopback ports, not `host`.
                    if state == .connected && !isDemo {
                        recentHosts = RecentHosts.encode(RecentHosts.remember(host, in: RecentHosts.decode(recentHosts)))
                    }
                }

                if !isDemo, viewModel.connectionState == .disconnected {
                    demoButton
                }

                if viewModel.connectionState == .connected, let problem = viewModel.transmitProblem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if case .failed(let message) = viewModel.connectionState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.connectionState == .connected {
                    connectedContent
                }
            }
            .padding(32)
        }
        // A press can't be released from the background; don't stay keyed.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stopTransmit() }
        }
    }

    /// This route's Enable Transmit: locked (gray) blocks PTT; unlocked
    /// (red) allows it. Persisted by the model, off on first use.
    private var transmitEnableButton: some View {
        Button {
            viewModel.transmitEnabled.toggle()
        } label: {
            Image(systemName: viewModel.transmitEnabled ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(viewModel.transmitEnabled ? Color.white : Color.primary)
        }
        .buttonStyle(.bordered)
        .tint(viewModel.transmitEnabled ? .red : nil)
        .accessibilityLabel(viewModel.transmitEnabled ? "common.transmitEnabledTapTo" : "common.transmitDisabledTapTo")
    }

    @ViewBuilder
    private var connectedContent: some View {
        let state = viewModel.rigState
        // No editing while the rig scans — see `PiDirectViewModel.send`.
        let editable = state.memoryScan != .scanning && state.memoryScan != .paused
        HStack(spacing: 12) {
            // Same arguments as the hub screen's boxes; the APRS
            // indicator comes from this iPad's own decode.
            VFODisplayBox(
                label: "SUB",
                frequencyHz: state.secondaryFrequencyHz,
                isActive: state.singleReceive != true,
                mode: state.secondaryMode?.displayName ?? "—",
                txRxLabel: state.subTxRxLabel,
                callsign: state.secondaryMode == .c4fm ? state.c4fmCallsign : (state.aprsSubActive ? state.aprsSubLastCallsign : nil),
                reflector: state.secondaryMode == .c4fm ? state.c4fmReflector : nil,
                aprsActive: state.aprsSubActive,
                onSetFrequency: editable ? { viewModel.send(.setSecondaryFrequency(hz: $0)) } : nil,
                vfoMemoryMode: state.subVfoMemoryMode,
                memoryChannel: state.subMemoryChannel,
                memoryChannelTag: state.subMemoryChannelTag,
                onSetMemoryChannel: editable ? { viewModel.send(.setSubMemoryChannel($0)) } : nil,
                onStepMemoryChannel: editable ? { viewModel.send(.stepSubMemoryChannel(up: $0)) } : nil,
                memoryScan: state.memoryScan(on: .sub),
                currentMode: state.secondaryMode,
                onSetMode: { viewModel.send(.setSecondaryMode($0)) },
                memoryList: viewModel.memoryListSnapshot,
                onRefreshMemoryList: { viewModel.send(.refreshMemoryList) }
            )
            VFODisplayBox(
                label: "MAIN",
                frequencyHz: state.frequencyHz,
                isActive: true,
                mode: state.mode.displayName,
                txRxLabel: state.mainTxRxLabel,
                callsign: state.mode == .c4fm ? state.c4fmCallsign : (state.aprsActive ? state.aprsLastCallsign : nil),
                reflector: state.mode == .c4fm ? state.c4fmReflector : nil,
                aprsActive: state.aprsActive,
                onSetFrequency: editable ? { viewModel.send(.setFrequency(hz: $0)) } : nil,
                vfoMemoryMode: state.vfoMemoryMode,
                memoryChannel: state.memoryChannel,
                memoryChannelTag: state.memoryChannelTag,
                onSetMemoryChannel: editable ? { viewModel.send(.setMemoryChannel($0)) } : nil,
                onStepMemoryChannel: editable ? { viewModel.send(.stepMemoryChannel(up: $0)) } : nil,
                memoryScan: state.memoryScan(on: .main),
                currentMode: state.mode,
                onSetMode: { viewModel.send(.setMode($0)) },
                memoryList: viewModel.memoryListSnapshot,
                onRefreshMemoryList: { viewModel.send(.refreshMemoryList) },
                currentBand: BandPicker.name(containing: state.frequencyHz),
                onSetBand: editable ? { viewModel.send(.setBand($0)) } : nil
            )
        }

        // Same SUB | MAIN columns as the VFO boxes above. MAIN's bar shows
        // the TX meter while the rig transmits, as on the hub screen.
        HStack(spacing: 12) {
            ChannelStrip(
                label: "SUB",
                smeterDb: state.subSmeterDb,
                txReadings: nil,
                ptt: false,
                volume: $subAudioVolume,
                squelchThreshold: $subAudioSquelchThreshold,
                isMuted: viewModel.isSubAudioMuted,
                engine: viewModel.subAudioEngine,
                onToggleMute: viewModel.toggleSubAudioMuted
            )
            ChannelStrip(
                label: "MAIN",
                smeterDb: state.smeterDb,
                txReadings: MeterReadings(powerWatts: state.powerWatts, swr: state.swr, tx: state.txMeters),
                ptt: state.ptt,
                volume: $mainAudioVolume,
                squelchThreshold: $mainAudioSquelchThreshold,
                isMuted: viewModel.isMainAudioMuted,
                engine: viewModel.mainAudioEngine,
                onToggleMute: viewModel.toggleMainAudioMuted
            )
        }

        // Only the problem case gets a line; playing/off need no text.
        if viewModel.audioState == .waiting {
            Text("common.waitingForAudioIs")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Group {
            if let store = viewModel.aprsStore {
                ObservingAPRSStore(store: store) { store in
                    // The APRS pane covers the filter block and the grid both.
                    VStack(alignment: .leading, spacing: 16) {
                        FilterPanel<PiDirectViewModel>(spectrumStore: viewModel.filterSpectrum, isActive: viewModel.connectionState == .connected && aprsListKind == nil && !showingCW)
                        MenuPageView<PiDirectViewModel>(showsPagePicker: false, onShowAPRSList: { aprsListKind = $0 })
                    }
                    .aprsListPane(
                        kind: $aprsListKind,
                        stations: store.stations,
                        messages: store.messages,
                        onClearHistory: store.clearHistory
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    FilterPanel<PiDirectViewModel>(spectrumStore: viewModel.filterSpectrum, isActive: viewModel.connectionState == .connected && !showingCW)
                    MenuPageView<PiDirectViewModel>(showsPagePicker: false)
                }
            }
        }
        // Over the APRS pane's area too; the CW button closes the lists.
        .cwPane(
            isShowing: $showingCW,
            isConnected: viewModel.connectionState == .connected,
            rigInfo: CWRigInfo(state: viewModel.rigState, connected: viewModel.connectionState == .connected, transmitting: viewModel.isTransmitting),
            singleReceive: viewModel.rigState.singleReceive == true
        ) {
            CWSendSection<PiDirectViewModel>()
        }

        Text(isDemo
             ? "piDirect.demoModeASimulated"
             : "piDirect.directToRigctldOn")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Scan/Skip, V/M, swap and audio-channel override — same as the Mac's
    /// buttons by the VFO boxes. Swap and V/M are refused while the rig
    /// scans; stop the scan first.
    private var rigButtons: some View {
        let state = viewModel.rigState
        let scanning = state.memoryScan == .scanning || state.memoryScan == .paused
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
            .disabled(scanning || state.vfoMemoryMode == nil)

            Button {
                viewModel.send(.swapActiveVFO)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(scanning)
            .accessibilityLabel("common.swapMainAndSub")

            Button {
                viewModel.toggleAudioChannelsSwapped()
            } label: {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(viewModel.audioChannelsSwapped ? Color.white : Color.primary)
            }
            .tint(viewModel.audioChannelsSwapped ? .orange : nil)
            .accessibilityLabel(viewModel.audioChannelsSwapped ? "common.audioChannelsSwappedTap" : "common.swapAudioChannels")
        }
        .buttonStyle(.bordered)
        // Natural width, one line: with longer translations the row is
        // full in portrait, and PTT is the one that gives way.
        .lineLimit(1)
        .fixedSize()
    }

    /// Under the host fields while disconnected: the same screen against a
    /// simulated Pi (`DemoSession`).
    private var demoButton: some View {
        HStack(spacing: 12) {
            Button {
                demo.start()
            } label: {
                Label("common.demoMode", systemImage: "play.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(demo.isStarting)
            Text(demo.problem ?? String(localized: "piDirect.tryTheAppWith"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        if isDemo {
            exitDemoButton
        } else {
            realConnectButton
        }
    }

    /// In place of Connected while the demo runs, whatever the link state.
    private var exitDemoButton: some View {
        Button {
            demo.stop()
        } label: {
            Text("common.exitDemo")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow)
                .foregroundStyle(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var realConnectButton: some View {
        Button {
            if viewModel.connectionState == .disconnected {
                viewModel.connect(toHost: host, wpsdHost: wpsdHost)
            } else {
                viewModel.disconnect()
            }
        } label: {
            Text(buttonTitle)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(buttonColor)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.connectionState == .disconnected && host.isEmpty)
    }

    /// Connecting/retrying is tappable too — it cancels the retry loop.
    private var buttonTitle: String {
        switch viewModel.connectionState {
        case .disconnected: String(localized: "common.disconnected")
        case .connecting: String(localized: "common.connecting")
        case .connected: String(localized: "common.connected")
        case .failed: String(localized: "common.retrying")
        }
    }

    private var buttonColor: Color {
        switch viewModel.connectionState {
        case .disconnected: .red
        case .connecting, .failed: .orange
        case .connected: .green
        }
    }
}

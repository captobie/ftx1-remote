import CoreGraphics
import FTX1Core
import SwiftUI

/// Which `AudioCaptureEngine` frame `ScopeDisplayView` shows — both are
/// always being produced (see `AudioCaptureFrame`), so switching is just a
/// selection change, no capture restart.
enum ScopeDisplayMode: String {
    case waterfall
    case oscilloscope
    case off

    /// The `@AppStorage` key `ContentView` persists the selection under.
    static let storageKey = "ui.scopeDisplayMode"

    /// The persisted selection as of right now — what `ContentView`'s
    /// `@AppStorage` would read. `HubService` uses this at init so
    /// `AudioCaptureEngine` starts out matching the saved setting even
    /// before (or without) a window ever appearing; live changes are
    /// forwarded by `ContentView` via `HubService.setScopeDisplayMode`.
    static var persisted: ScopeDisplayMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ScopeDisplayMode.init(rawValue:)) ?? .waterfall
    }
}

/// Dense multi-pane control UI (see repo root CLAUDE.md) — still growing.
struct ContentView: View {
    @EnvironmentObject private var hub: HubService
    @State private var isPTTPressed = false
    @AppStorage(ScopeDisplayMode.storageKey) private var scopeDisplayMode: ScopeDisplayMode = .waterfall

    /// Height of the waterfall/oscilloscope, matching the S-meters
    /// (`meterWidth` at `SMeterView`'s 280:120 aspect) since they share a row.
    private let scopeHeight: CGFloat = 190 * 120 / 280
    /// Width of each VFO's S-meter; its height follows from `SMeterView`'s
    /// fixed aspect ratio (280:120 Main, cropped for Sub).
    private let meterWidth: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                connectButton
                // rigctldProcessState has nothing to report in .remote mode
                // (see HubService.startRigctld()) — nothing is ever spawned
                // there, so there's no process-lifecycle label worth showing.
                if RigctldSettings.connectionMode == .local {
                    Text(rigctldProcessLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // A Grid so each VFO's meter/audio row shares a column with its
            // VFO box (Sub left, Main right) and the waterfall/oscilloscope
            // sits between the two meters. The middle column's top line
            // (V/M, swap, room for more buttons later) is top-aligned with
            // the VFO boxes; the scope mode buttons sit below it.
            Grid(horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow(alignment: .top) {
                    VFODisplayBox(label: "SUB", frequencyHz: hub.rigState.secondaryFrequencyHz, isActive: hub.rigState.singleReceive != true, mode: hub.rigState.secondaryMode?.displayName ?? "—", txRxLabel: "RX", callsign: hub.rigState.secondaryMode == .c4fm ? hub.rigState.c4fmCallsign : (hub.rigState.aprsSubActive ? hub.rigState.aprsSubLastCallsign : nil), reflector: hub.rigState.secondaryMode == .c4fm ? hub.rigState.c4fmReflector : nil, aprsActive: hub.rigState.aprsSubActive, onSetFrequency: { hub.send(.setSecondaryFrequency(hz: $0)) })
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            vmToggleButton
                            vfoSwapButton
                            audioChannelSwapButton
                        }
                        HStack(spacing: 8) {
                            scopeDisplayModeButtons
                            Text(swrLabel)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(hub.rigState.swr == nil ? .secondary : .primary)
                                .fixedSize()
                        }
                    }
                    VFODisplayBox(label: "MAIN", frequencyHz: hub.rigState.frequencyHz, isActive: true, mode: hub.rigState.mode.displayName, txRxLabel: hub.rigState.splitEnabled == true ? "RX" : "TXRX", callsign: hub.rigState.mode == .c4fm ? hub.rigState.c4fmCallsign : (hub.rigState.aprsActive ? hub.rigState.aprsLastCallsign : nil), reflector: hub.rigState.mode == .c4fm ? hub.rigState.c4fmReflector : nil, aprsActive: hub.rigState.aprsActive, onSetFrequency: { hub.send(.setFrequency(hz: $0)) }, vfoMemoryMode: hub.rigState.vfoMemoryMode, memoryChannel: hub.rigState.memoryChannel, memoryChannelTag: hub.rigState.memoryChannelTag, onSetMemoryChannel: { hub.send(.setMemoryChannel($0)) }, onStepMemoryChannel: { hub.send(.stepMemoryChannel(up: $0)) })
                }
                GridRow(alignment: .top) {
                    channelControls(isSub: true)
                    HStack(spacing: 8) {
                        zoomControls
                        // `hub.scopeFrames` is a plain `let` on HubService, not
                        // `@Published` state, so reading it here adds no
                        // dependency — only ScopeDisplayView observes the
                        // store's per-frame updates (see ScopeFrameStore).
                        ScopeDisplayView(frames: hub.scopeFrames, mode: scopeDisplayMode, isActive: hub.connectionState == .connected)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: scopeHeight)
                    channelControls(isSub: false)
                }
            }

            pttButton

            HStack(spacing: 16) {
                Picker("Band", selection: bandBinding) {
                    Section("Amateur") {
                        ForEach(BandPlan.all, id: \.name) { band in
                            Text(band.name).tag(band.name)
                        }
                    }
                    Section("Broadcast") {
                        ForEach(GeneralCoverageSegments.all.filter { $0.category == .broadcast }, id: \.name) { segment in
                            Text(segment.name).tag(segment.name)
                        }
                    }
                    Section("Utility") {
                        ForEach(GeneralCoverageSegments.all.filter { $0.category == .utility }, id: \.name) { segment in
                            Text(segment.name).tag(segment.name)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)

                Picker("Mode", selection: modeBinding) {
                    ForEach(RigMode.allCases.filter { $0 != .unknown }, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Filter block: the rig's MAIN-knob function-menu controls in
            // two rows (kept off the Band/Mode row above since that one is
            // full at the default window width) with the Filter Function
            // Display on the right spanning both. Row 1: WIDTH, SHIFT.
            // Row 2: CONTOUR-or-APF (one slot, face picked by mode), N/W
            // (narrow), NOTCH. Rows left-aligned so later controls append.
            // The MAIN/SUB selector sits just left of the display and picks
            // which receiver the controls and the display address.
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        FilterWidthControl<HubService>()
                        IFShiftControl<HubService>()
                        Spacer()
                    }
                    HStack(spacing: 16) {
                        ContourAPFControl<HubService>()
                        NarrowControl<HubService>()
                        IFNotchControl<HubService>()
                        Spacer()
                    }
                }
                FilterSideSelector<HubService>()
                FilterDisplayHost(frames: hub.scopeFrames, scopeMode: scopeDisplayMode)
            }
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            MenuPageView<HubService>()
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 360)
        // Forwarded rather than read by HubService directly: @AppStorage is
        // what makes this view track the setting, and the engine needs to
        // hear about changes too (see HubService.setScopeDisplayMode).
        .onChange(of: scopeDisplayMode) {
            hub.setScopeDisplayMode(scopeDisplayMode)
        }
    }

    /// Momentary press-and-hold, not a toggle — keys on press-down and
    /// unkeys on release, matching how PTT actually works. A plain
    /// `Button` only fires on release, so this uses a zero-distance
    /// `DragGesture` instead (fires `onChanged` immediately on press,
    /// `onEnded` on release; works the same for a mouse click as it does
    /// for touch). `isPTTPressed` guards against sending `.setPTT(true)`
    /// repeatedly while `onChanged` keeps firing during the hold.
    /// Swaps which of Main/Sub is the active VFO — the rig's own physical
    /// A/B button, over CAT. `VFODisplayBox`'s existing live-state bindings
    /// (`rigState.frequencyHz`/`.secondaryFrequencyHz`) already relabel
    /// which box shows which frequency once the active VFO changes, so this
    /// button is the entire feature — no other display logic needed.
    private var vfoSwapButton: some View {
        Button {
            hub.send(.swapActiveVFO)
        } label: {
            Image(systemName: "arrow.left.arrow.right")
        }
        .buttonStyle(.bordered)
    }

    /// Manual override for which physical audio channel (L/R) plays under
    /// the Main/Sub controls — see `HubService.audioChannelsSwapped`. The
    /// app tracks swaps on its own, but the rig has no readout of the true
    /// mapping, so this is the escape hatch when the tracked state has
    /// drifted (a front-panel swap made while the app wasn't running).
    /// Highlighted while the channels are swapped relative to the default.
    private var audioChannelSwapButton: some View {
        Button {
            hub.toggleAudioChannelsSwapped()
        } label: {
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(hub.audioChannelsSwapped ? Color.white : Color.primary)
                .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .tint(hub.audioChannelsSwapped ? .orange : nil)
        .help(hub.audioChannelsSwapped
              ? "Audio channels are swapped relative to the rig's default (L=Main, R=Sub). Click to swap back."
              : "Swap which audio channel plays as Main and Sub — use if the audio doesn't match the VFO it's under.")
    }

    /// Toggles VFO A between VFO and Memory-channel mode — the rig's own
    /// V/M concept, over CAT (see `RigState.vfoMemoryMode`, the FTX-1's raw
    /// "VM" command). Explicit-set rather than a blind toggle command:
    /// reads the current mode from `rigState` and sends the opposite as an
    /// explicit target, per this project's established preference for
    /// determining intent explicitly rather than trusting a symmetric
    /// toggle (see git history on the "PR"/MIC EQ "backwards toggle" bug).
    private var vmToggleButton: some View {
        Button {
            // Compare against `.vfo`, not `.memory`: the rig has several
            // non-plain-Memory VM sub-modes (PMS, P-01L~P-50U, 5MHz Band,
            // EMG — see `VFOMemoryMode`), all reported as `.other(rawP2:)`.
            // Comparing against `.memory` left any of those states reading
            // as "not memory" and this button would re-send "enter Memory"
            // forever instead of ever exiting to VFO — confirmed on real
            // hardware 2026-09-17 landing in the 5MHz Band Memory sub-mode.
            hub.send(.setVFOMemoryMode(memory: hub.rigState.vfoMemoryMode == .vfo))
        } label: {
            Text("V/M")
                .font(.caption)
                .fontWeight(hub.rigState.vfoMemoryMode == .vfo ? .regular : .bold)
        }
        .buttonStyle(.bordered)
    }

    /// Mirrors `HubService.send(_:)`'s TX gate (transmit-enabled toggle
    /// AND inside an amateur allocation) so the button visibly reflects
    /// why a press won't do anything, rather than silently no-opping.
    private var canTransmit: Bool {
        hub.rigState.transmitEnabled && BandPlan.band(containing: hub.rigState.frequencyHz) != nil
    }

    private var pttButton: some View {
        Text(hub.rigState.ptt ? "TRANSMITTING" : "PTT")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(hub.rigState.ptt ? Color.red : Color.gray.opacity(0.25))
            .foregroundStyle(hub.rigState.ptt ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(canTransmit ? 1 : 0.4)
            .help(
                hub.rigState.transmitEnabled
                    ? (canTransmit ? "" : "Transmit disabled: outside an amateur band")
                    : "Transmit disabled"
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPTTPressed, canTransmit else { return }
                        isPTTPressed = true
                        hub.send(.setPTT(true))
                    }
                    .onEnded { _ in
                        isPTTPressed = false
                        hub.send(.setPTT(false))
                    }
            )
    }

    /// Reserves the SWR row's height even before there's a reading (rather
    /// than omitting the row via `if let`), so the window's total content
    /// height — fixed once the disconnected layout first appears — doesn't
    /// grow on connect and squeeze the frequency digits' `minimumScaleFactor`
    /// down to fit.
    private var swrLabel: String {
        guard let swr = hub.rigState.swr else { return "SWR --" }
        return String(format: "SWR %.2f", swr)
    }

    private var scopeDisplayModeButtons: some View {
        HStack(spacing: 4) {
            scopeDisplayModeButton("Waterfall", mode: .waterfall)
            scopeDisplayModeButton("Oscilloscope", mode: .oscilloscope)
            scopeDisplayModeButton("Off", mode: .off)
        }
    }

    private func scopeDisplayModeButton(_ title: String, mode: ScopeDisplayMode) -> some View {
        let isSelected = scopeDisplayMode == mode
        return Button {
            scopeDisplayMode = mode
        } label: {
            Text(title)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    /// Generic over which channel it mutes — `scopeDisplayModeButtons`
    /// always shows both, side by side.
    private func channelMuteButton(label: String, isMuted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(isMuted ? Color.red : Color.gray.opacity(0.2))
                .foregroundStyle(isMuted ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    /// One VFO's meter and audio playback controls, laid out under its VFO
    /// box: the S-meter on the left, Mute plus horizontal SQL/VOL sliders
    /// (see `HubService.mainAudioVolume`/`.mainSquelchThreshold` and the Sub
    /// equivalents) on the right. The sliders exist because the squelch
    /// default (0.02) gated quiet-but-real audio out with no Mac-side way
    /// to adjust it; Sub's are shown in both `.local` and `.remote` (Sub
    /// capture works in both when the input device is stereo — otherwise
    /// they're just inert, see `HubService.isSubAudioMuted`). Independent of
    /// the waterfall/oscilloscope, which mute/volume don't affect.
    private func channelControls(isSub: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SMeterView(
                smeterDb: isSub ? hub.rigState.subSmeterDb : hub.rigState.smeterDb,
                swr: hub.rigState.swr,
                ptt: hub.rigState.ptt,
                powerWatts: hub.rigState.powerWatts,
                txMeters: hub.rigState.txMeters,
                isSub: isSub
            )
            .frame(width: meterWidth, height: meterWidth * 120 / 280)
            VStack(spacing: 4) {
                if isSub {
                    channelMuteButton(label: "Mute", isMuted: hub.isSubAudioMuted, action: hub.toggleSubAudioMuted)
                    horizontalSlider(value: subSquelchBinding, label: "SQL", range: 0...Self.squelchDisplayRange)
                    horizontalSlider(value: subVolumeBinding, label: "VOL")
                } else {
                    channelMuteButton(label: "Mute", isMuted: hub.isMainAudioMuted, action: hub.toggleMainAudioMuted)
                    horizontalSlider(value: mainSquelchBinding, label: "SQL", range: 0...Self.squelchDisplayRange)
                    horizontalSlider(value: mainVolumeBinding, label: "VOL")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    /// Upper bound of the squelch slider's *displayed* range — chosen to
    /// give useful resolution around real quieting-dip/static-floor values
    /// (~0.001-0.08 in the 2026-09-08 hardware capture `SquelchGate`'s
    /// design is based on), not the old 0...0.2 loudness-threshold range.
    /// Shared by Main and Sub — no evidence yet Sub needs a different range.
    private static let squelchDisplayRange: Float = 0.05

    /// `SquelchGate.threshold` is now "how close to true silence counts as
    /// quieting" — *smaller* is stricter (see its doc comment). That reads
    /// backwards on a slider, where raising it should tighten the squelch
    /// like a normal radio's knob, so this inverts the displayed position:
    /// dragging up lowers the stored threshold (stricter), dragging down
    /// raises it (more lenient).
    private var mainSquelchBinding: Binding<Float> {
        Binding(
            get: { Self.squelchDisplayRange - hub.mainSquelchThreshold },
            set: { hub.mainSquelchThreshold = Self.squelchDisplayRange - $0 }
        )
    }

    private var subSquelchBinding: Binding<Float> {
        Binding(
            get: { Self.squelchDisplayRange - hub.subSquelchThreshold },
            set: { hub.subSquelchThreshold = Self.squelchDisplayRange - $0 }
        )
    }

    private var mainVolumeBinding: Binding<Float> {
        Binding(get: { hub.mainAudioVolume }, set: { hub.mainAudioVolume = $0 })
    }

    private var subVolumeBinding: Binding<Float> {
        Binding(get: { hub.subAudioVolume }, set: { hub.subAudioVolume = $0 })
    }

    private func horizontalSlider(value: Binding<Float>, label: String, range: ClosedRange<Float> = 0...1) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    /// Adjusts whichever display `scopeDisplayMode` currently shows — the
    /// waterfall's color-zoom and the oscilloscope's vertical scale are
    /// independent settings (`HubService.waterfallZoom`/`oscilloscopeZoom`),
    /// this just routes the same pair of arrows to whichever one is active
    /// rather than showing four buttons at once. Dimmed and inert while
    /// `.off` — nothing to zoom, but keeps the same width reserved so the
    /// row doesn't jump when switching modes.
    private var zoomControls: some View {
        VStack(spacing: 4) {
            zoomButton(systemImage: "chevron.up") { stepZoom(up: true) }
            Text(zoomLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            zoomButton(systemImage: "chevron.down") { stepZoom(up: false) }
        }
        .frame(width: 28)
        .opacity(scopeDisplayMode == .off ? 0.3 : 1)
        .disabled(scopeDisplayMode == .off)
    }

    private func zoomButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 24, height: 20)
                .background(Color.gray.opacity(0.2))
                .foregroundStyle(Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func stepZoom(up: Bool) {
        switch scopeDisplayMode {
        case .waterfall: hub.stepWaterfallZoom(up: up)
        case .oscilloscope: hub.stepOscilloscopeZoom(up: up)
        case .off: break
        }
    }

    private var zoomLabel: String {
        switch scopeDisplayMode {
        case .waterfall: String(format: "%.1fx", hub.waterfallZoom)
        case .oscilloscope: String(format: "%.1fx", hub.oscilloscopeZoom)
        case .off: "—"
        }
    }

    /// Falls back to the first band in the plan if the active frequency
    /// isn't within any known band (e.g. rigctld hasn't reported yet).
    private var bandBinding: Binding<String> {
        Binding(
            get: { hub.rigState.band ?? BandPlan.all.first?.name ?? "" },
            set: { hub.send(.setBand($0)) }
        )
    }

    private var modeBinding: Binding<RigMode> {
        Binding(
            get: { hub.rigState.mode },
            set: { hub.send(.setMode($0)) }
        )
    }

    /// Replaces the old rigctld on/off `Toggle` with a button whose label
    /// and color reflect `connectionState` (what the user actually cares
    /// about — is the app talking to the rig), while its tap action still
    /// starts/stops the rigctld process itself, same as the toggle did.
    private var connectButton: some View {
        Button {
            if isRigctldActive {
                hub.stopRigctld()
            } else {
                hub.startRigctld()
            }
        } label: {
            Text(hub.connectionState == .connected ? "Connected" : "Disconnected")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(hub.connectionState == .connected ? Color.green : Color.red)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var isRigctldActive: Bool {
        hub.isActive
    }

    private var rigctldProcessLabel: String {
        switch hub.rigctldProcessState {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .failed(let message): "Failed: \(message)"
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(HubService())
}

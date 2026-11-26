import Combine
import FTX1Core
import SwiftUI

/// The SDR pane's MyKiwiSDR side: the Mac's Tools → MyKiwiSDR on the shared
/// `LocalSDRModel`, in the area the CW pane and the APRS lists use (the
/// filter block + MENU grid), opened by the top row's SDR button on both
/// routes. The Kiwi is reached straight from the iPad (over Tailscale, as
/// the Pi or the hub is); the rig side — Follow, Tune rig, Mute on TX and
/// MAIN muted while the Kiwi is audible — goes through the route's view
/// model (`SDRRigHost`).
///
/// The address and password are in the pane's own header while
/// disconnected (the iPad has no Settings screen): `localSDR.host` and the
/// keychain item the Mac uses, in this device's own store. Explicit connect
/// only; closing the pane or leaving the route disconnects. No recording
/// and no decoder feed here (both Mac-only).
struct KiwiSDRPaneContent: View {
    @ObservedObject var model: LocalSDRModel

    @AppStorage(LocalSDRModel.hostKey) private var hostPort = ""
    @State private var password = ""
    @State private var passwordLoaded = false
    @State private var showingReceiver = false
    @State private var showingFrequencyEntry = false

    private static let steps = [100, 1_000, 5_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            LocalSDRWaterfallView(model: model, store: model.waterfall)
                .frame(minHeight: 260, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                tuningRow
                meterAndAudioRow
                rigLinkRow
                Text(verbatim: statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            .padding(12)
        }
        .sheet(isPresented: $showingReceiver) { receiverSheet }
        .task { await loadPassword() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if model.isConnected {
                Text(verbatim: model.connectedHostPort)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                TextField("sdrPane.address", text: $hostPort)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .frame(maxWidth: 260)
                SecureField("sdrPane.password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit(connect)
            }
            connectButton
            Spacer(minLength: 0)
            Button {
                showingReceiver = true
            } label: {
                Label("common.receiver", systemImage: "slider.horizontal.3")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("sdrPane.receiverSettings")
        }
        .buttonStyle(.bordered)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var connectButton: some View {
        if model.isConnected {
            Button("common.disconnect", systemImage: "stop.circle", action: model.disconnect)
                .labelStyle(.titleAndIcon)
                .fixedSize()
        } else {
            Button("common.connect", systemImage: "play.circle", action: connect)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .disabled(model.isLoadingPassword || !LocalSDRModel.isValidHost(hostPort))
        }
    }

    /// Saves the password (the model reads it back from the keychain at
    /// connect, as on the Mac), then connects.
    private func connect() {
        guard LocalSDRModel.isValidHost(hostPort), !model.isLoadingPassword else { return }
        let password = password
        Task {
            await Task.detached { LocalSDRPassword.write(password, logSubsystem: "com.ftx1remote.ipad") }.value
            model.connect()
        }
    }

    private func loadPassword() async {
        guard !passwordLoaded else { return }
        password = await Task.detached { LocalSDRPassword.read(logSubsystem: "com.ftx1remote.ipad") }.value
        passwordLoaded = true
    }

    // MARK: - Rows

    private var tuningRow: some View {
        HStack(spacing: 10) {
            Button {
                showingFrequencyEntry = true
            } label: {
                Text(verbatim: FrequencyFormat.dotted(model.frequencyHz))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 10)
                    .frame(width: 200, height: 40, alignment: .trailing)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.6), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("sdrPane.enterFrequency")
            .popover(isPresented: $showingFrequencyEntry) {
                FrequencyEntryView(currentHz: model.frequencyHz, onSetFrequency: model.setFrequency)
                    .padding()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { stepButtons(Self.steps) }
                HStack(spacing: 10) { stepButtons([1_000]) }
                EmptyView()
            }

            Spacer(minLength: 0)

            Picker("common.mode", selection: Binding(get: { model.mode }, set: model.selectMode)) {
                ForEach(KiwiSDRMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func stepButtons(_ steps: [Int]) -> some View {
        ForEach(steps, id: \.self) { step in
            HStack(spacing: 2) {
                Button { model.step(byHz: -step) } label: { Image(systemName: "chevron.left") }
                Text(verbatim: Self.stepLabel(step))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 40)
                Button { model.step(byHz: step) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
    }

    private var meterAndAudioRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { meterAndAudio }
            VStack(alignment: .leading, spacing: 10) { meterAndAudio }
        }
    }

    @ViewBuilder
    private var meterAndAudio: some View {
        Group {
            SDRPaneMeter(meter: model.meter)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1)
                    .frame(width: 160)
                    .accessibilityLabel("localSDR.volume")
                Button(action: model.toggleMuted) {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        .foregroundStyle(model.isMuted ? Color.white : Color.primary)
                }
                .buttonStyle(.bordered)
                .tint(model.isMuted ? .red : nil)
                .accessibilityLabel(model.isMuted ? "localSDR.muted" : "localSDR.mute")
            }
        }
    }

    private var rigLinkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One row, or two in a narrower pane (the split screen).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    followToggles
                    rigToggles
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) { followToggles }
                    HStack(spacing: 18) { rigToggles }
                }
            }
            .toggleStyle(.switch)
            .font(.callout)
            Text(verbatim: rigLinkText)
                .font(.caption)
                .foregroundStyle(model.rigLinkNote == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var followToggles: some View {
        Toggle("localSDR.followRig", isOn: $model.followRig)
            .fixedSize()
        Toggle("localSDR.followRigWidth", isOn: Binding(get: { model.followRigWidth }, set: model.setFollowRigWidth))
            .fixedSize()
            .disabled(!model.followRig)
    }

    @ViewBuilder
    private var rigToggles: some View {
        Toggle("localSDR.tuneRig", isOn: $model.tuneRig)
            .fixedSize()
        Toggle("localSDR.muteOnTx", isOn: $model.muteOnTransmit)
            .fixedSize()
    }

    private var receiverSheet: some View {
        NavigationStack {
            ScrollView {
                LocalSDRReceiverControls(model: model)
                    .padding()
            }
            .navigationTitle("common.receiver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { showingReceiver = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Text

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var statusText: String {
        switch model.state {
        case .disconnected:
            model.isLoadingPassword
                ? String(localized: "localSDR.status.readingPassword")
                : String(localized: "localSDR.status.disconnected")
        case .connecting:
            String(localized: "localSDR.status.connecting \(model.connectedHostPort)")
        case .connected(let rate):
            String(localized: "localSDR.status.connected \(model.connectedHostPort) \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rate))")
        case .failed(let error):
            error.localizedMessage
        }
    }

    /// Which direction is active, then the last refusal, if any (the Mac
    /// window's line).
    private var rigLinkText: String {
        let active: String
        switch (model.followRig, model.tuneRig) {
        case (true, true): active = String(localized: "localSDR.rigLink.both")
        case (true, false): active = String(localized: "localSDR.rigLink.followOnly")
        case (false, true): active = String(localized: "localSDR.rigLink.tuneOnly")
        case (false, false): active = String(localized: "localSDR.rigLink.off")
        }
        if !model.isConnected, model.followRig || model.tuneRig {
            return String(localized: "localSDR.rigLink.whenConnected \(active)")
        }
        guard let note = model.rigLinkNote else { return active }
        return String(localized: "localSDR.rigLink.withNote \(active) \(note)")
    }

    private static func stepLabel(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }
}

/// Which SDR the pane shows (`ipad.sdrSource`).
enum SDRPaneSource: String, CaseIterable {
    case myKiwiSDR
    case webSDR
}

/// The iPad's SDR pane, in the area the CW pane and the APRS lists use (or
/// the split screen): MyKiwiSDR (`KiwiSDRPaneContent`) or a WebSDR page
/// (`WebSDRPaneContent`), picked at the top, one at a time — switching
/// disconnects the one left. Split and Close beside the picker.
struct SDRPane: View {
    @ObservedObject var model: LocalSDRModel
    @ObservedObject var webModel: WebSDRFollowModel
    let directory: KiwiSDRDirectory
    @Binding var isShowing: Bool
    /// The split screen (`SDRSplitLayout`) instead of the overlay.
    @Binding var isSplit: Bool
    @AppStorage("ipad.sdrSource") private var source: SDRPaneSource = .myKiwiSDR

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("sdrPane.source", selection: $source) {
                    Text(verbatim: "MyKiwiSDR").tag(SDRPaneSource.myKiwiSDR)
                    Text(verbatim: "WebSDR").tag(SDRPaneSource.webSDR)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 0)
                Button {
                    isSplit.toggle()
                } label: {
                    Image(systemName: isSplit ? "rectangle.inset.filled" : "rectangle.split.2x1")
                }
                .accessibilityLabel(isSplit ? "sdrPane.leaveSplit" : "sdrPane.split")
                Button {
                    isShowing = false
                } label: {
                    Label("common.close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .padding(12)
            switch source {
            case .myKiwiSDR: KiwiSDRPaneContent(model: model)
            case .webSDR: WebSDRPaneContent(model: webModel, directory: directory)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: source) { _, source in
            switch source {
            case .myKiwiSDR: webModel.disconnect()
            case .webSDR: model.disconnect()
            }
        }
    }
}

/// The Kiwi's S-meter as the iPad strips' bar (S9 = −73 dBm, 6 dB per
/// unit, so dB over S9 is dBm + 73), with the dBm reading and the ADC
/// overload flag. Its own view, so ~10 meter updates a second redraw only
/// this.
private struct SDRPaneMeter: View {
    @ObservedObject var meter: LocalSDRMeterStore

    var body: some View {
        HStack(spacing: 12) {
            BarSMeterView(label: "KIWI", smeterDb: meter.dBm.map { $0 + 73 }, txReadings: nil, ptt: false,
                          transmits: false)
                .frame(maxWidth: 320)
            Text(verbatim: meter.dBm.map { "\(Int($0.rounded())) dBm" } ?? "— dBm")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            if meter.overload {
                Text("localSDR.adcOverload")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .fixedSize()
            }
        }
    }
}

/// The top row's SDR button: shows or hides `SDRPane`. Turning it on
/// closes the CW pane and the APRS lists, which use the same area.
struct SDRPaneButton: View {
    @Binding var isShowing: Bool
    @Binding var showingCW: Bool
    @Binding var aprsListKind: APRSListKind?

    var body: some View {
        Button {
            isShowing.toggle()
            if isShowing {
                showingCW = false
                aprsListKind = nil
            }
        } label: {
            Text(verbatim: "SDR")
                .fontWeight(isShowing ? .bold : .regular)
                .foregroundStyle(isShowing ? Color.white : Color.primary)
        }
        .tint(isShowing ? .accentColor : nil)
        .accessibilityLabel(isShowing ? "sdrPane.hide" : "sdrPane.show")
    }
}

/// The two routes' MyKiwiSDR models, made once for the app (each needs its
/// route's view model as its rig side).
@MainActor
final class SDRModels: ObservableObject {
    let hub: LocalSDRModel
    let piDirect: LocalSDRModel
    /// The WebSDR page on each route (`WebSDRPaneContent`).
    let hubWeb: WebSDRFollowModel
    let piDirectWeb: WebSDRFollowModel
    /// The public KiwiSDR list, shared (its disk cache is anyway).
    let directory = KiwiSDRDirectory()

    init(hub: RigClientViewModel, piDirect: PiDirectViewModel) {
        self.hub = LocalSDRModel(rigHost: hub, logSubsystem: "com.ftx1remote.ipad")
        self.piDirect = LocalSDRModel(rigHost: piDirect, logSubsystem: "com.ftx1remote.ipad")
        hubWeb = WebSDRFollowModel(rigHost: hub)
        piDirectWeb = WebSDRFollowModel(rigHost: piDirect)
    }
}

extension View {
    /// Shows `SDRPane` over this view (the filter block + MENU grid, under
    /// the CW pane and APRS lists) while `isShowing`, hiding — not removing
    /// — the view underneath, as `cwPane` does; the area grows to fit the
    /// waterfall. The connection's lifetime is `sdrSession`'s.
    func sdrPane(isShowing: Binding<Bool>, isSplit: Binding<Bool>, model: LocalSDRModel,
                 webModel: WebSDRFollowModel, directory: KiwiSDRDirectory) -> some View {
        modifier(SDRPaneModifier(isShowing: isShowing, isSplit: isSplit, model: model, webModel: webModel,
                                 directory: directory))
    }
}

/// The waterfall wants more than the ~490 pt the filter block + MENU grid
/// take in portrait.
private let sdrMinHeight: CGFloat = 700

private struct SDRPaneModifier: ViewModifier {
    @Binding var isShowing: Bool
    @Binding var isSplit: Bool
    let model: LocalSDRModel
    let webModel: WebSDRFollowModel
    let directory: KiwiSDRDirectory

    func body(content: Content) -> some View {
        content
            .frame(minHeight: isShowing ? sdrMinHeight : nil, alignment: .top)
            .opacity(isShowing ? 0 : 1)
            .allowsHitTesting(!isShowing)
            .accessibilityHidden(isShowing)
            .overlay {
                if isShowing {
                    SDRPane(model: model, webModel: webModel, directory: directory, isShowing: $isShowing,
                            isSplit: $isSplit)
                }
            }
    }
}

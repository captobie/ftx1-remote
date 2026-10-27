import Combine
import FTX1CW
import FTX1Core
import SwiftUI

/// Demo Mode (2026-10-15): the Pi-direct screen against an in-process
/// simulated Pi (`DemoPi`) on loopback, for App Review and anyone without
/// an FTX-1, Pi or Mac. Everything the screen does runs for real; only the
/// rig and its audio are simulated.
///
/// A demo session never changes the real setup: it doesn't write the Pi
/// host, and while it runs `SettingsStore` points at a throwaway
/// `UserDefaults` suite and data folder — so the mutes and VOL/SQL
/// (`AudioPlaybackSettings`), the audio swap parity, the transmit lock
/// (`piDirect.transmitEnabled`), `APRSSettings` and `aprs-history.json`,
/// the memory-list cache, the station call/grid and the `cw.*` keys all go
/// there, and both are deleted on exit. Its model, CW receiver and sender
/// are its own, made after the switch (they read their settings at init),
/// and the screen's `@AppStorage` reads the same suite
/// (`.defaultAppStorage`). The real `PiDirectViewModel` stays disconnected
/// meanwhile, so leaving the demo shows the screen exactly as it was.
@MainActor
final class DemoSession: ObservableObject {
    /// One running demo.
    final class Context {
        let pi: DemoPi
        let viewModel: PiDirectViewModel
        let cwReceiver: CWReceiver
        let cwSender: CWSender
        let cwMonitor: CWMonitor
        let defaults: UserDefaults
        fileprivate var subscriptions: Set<AnyCancellable> = []

        fileprivate init(pi: DemoPi, viewModel: PiDirectViewModel, cwReceiver: CWReceiver, cwSender: CWSender, cwMonitor: CWMonitor,
                         defaults: UserDefaults) {
            self.pi = pi
            self.viewModel = viewModel
            self.cwReceiver = cwReceiver
            self.cwSender = cwSender
            self.cwMonitor = cwMonitor
            self.defaults = defaults
        }
    }

    @Published private(set) var context: Context?
    @Published private(set) var isStarting = false
    /// Why the last start failed (a loopback port wouldn't open).
    @Published private(set) var problem: String?

    private static let suiteName = "com.ftx1remote.ipad.demo"
    private static var dataDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FTX1RemoteDemo", isDirectory: true)
    }

    /// Display preferences copied into the demo's suite so the screen
    /// looks as it does outside the demo.
    private static let copiedPreferences = [
        AppearanceSettings.themeKey, AppearanceSettings.buttonValueColorKey,
        MeterSettings.key, MeterSettings.subKey, "ui.frequencyStepSize",
        CWMonitor.enabledKey,
    ]

    func start() {
        guard context == nil, !isStarting else { return }
        isStarting = true
        problem = nil
        Task {
            let pi = DemoPi()
            do {
                let endpoint = try await pi.start()
                begin(pi: pi, endpoint: endpoint)
            } catch {
                pi.stop()
                problem = String(localized: "demoMode.demoModeCouldntStart \(error.localizedDescription)")
            }
            isStarting = false
        }
    }

    private func begin(pi: DemoPi, endpoint: PiEndpoint) {
        let defaults = Self.freshDefaults()
        try? FileManager.default.removeItem(at: Self.dataDirectory)
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        SettingsStore.use(defaults: defaults, dataDirectory: Self.dataDirectory)
        // Something to show from the start: APRS decoding on (off by
        // default on a real setup), and a call for the CW macros.
        APRSSettings.enabled = true
        StationSettings.callsign = "DEMO"
        StationSettings.gridSquare = "FN31"

        let viewModel = PiDirectViewModel(
            logSubsystem: "com.ftx1remote.ipad",
            playsSubAudio: true,
            readsSMeter: true,
            readsVFODetails: true,
            readsMenuSettings: true,
            readsFilters: true,
            decodesAPRS: true
        )
        let cwReceiver = CWReceiver(logSubsystem: "com.ftx1remote.ipad", channels: [.main, .sub])
        let cwSender = CWSender(link: viewModel, logSubsystem: "com.ftx1remote.ipad")
        viewModel.onReceiveAudio = { pcm, side in
            cwReceiver.ingest(pcm: pcm, sampleRate: AudioStreamFormat.sampleRate, channel: side == .main ? .main : .sub)
        }
        cwSender.onActiveChanged = { cwReceiver.setSenderActive($0) }
        let cwMonitor = CWMonitor(logSubsystem: "com.ftx1remote.ipad")
        cwSender.onKeying = { cwMonitor.handle($0) }
        let context = Context(pi: pi, viewModel: viewModel, cwReceiver: cwReceiver, cwSender: cwSender,
                              cwMonitor: cwMonitor, defaults: defaults)
        // As the App does for the real route: locking or losing the link
        // stops the sender.
        viewModel.$transmitEnabled
            .sink { [weak cwSender] enabled in if !enabled { cwSender?.stop() } }
            .store(in: &context.subscriptions)
        viewModel.$connectionState
            .dropFirst()
            .sink { [weak cwSender] state in if state != .connected { cwSender?.stop() } }
            .store(in: &context.subscriptions)
        self.context = context
        viewModel.connect(to: endpoint)
    }

    /// Back to exactly where the screen was: the demo's objects go, the
    /// simulator stops, settings point at the real ones again, and the
    /// demo's suite and folder are deleted.
    func stop() {
        guard let context else { return }
        context.subscriptions.removeAll()
        context.cwSender.stop()
        context.cwMonitor.stop()
        context.cwReceiver.stop()
        context.viewModel.disconnect()
        self.context = nil
        // Give the model's teardown (it unkeys over the link) a moment.
        let pi = context.pi
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            pi.stop()
        }
        SettingsStore.useStandard()
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: Self.dataDirectory)
    }

    private static func freshDefaults() -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        for key in copiedPreferences {
            if let value = UserDefaults.standard.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        return defaults
    }
}

/// The demo's own objects, for the Pi-direct screen and its panes.
extension View {
    func demoEnvironment(_ context: DemoSession.Context) -> some View {
        environmentObject(context.viewModel)
            .environmentObject(context.cwReceiver)
            .environmentObject(context.cwSender)
            .environmentObject(context.cwMonitor)
            .defaultAppStorage(context.defaults)
    }
}

/// Across the top of the Pi-direct screen while the demo runs.
struct DemoBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("DEMO")
                .font(.headline.weight(.heavy))
            Text("demoMode.simulatedRadioNoFtx")
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

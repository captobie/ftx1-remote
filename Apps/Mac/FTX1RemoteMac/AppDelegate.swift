import AppKit
import Sparkle

/// Owns the hub service at the app-delegate level so it keeps running
/// independent of window state (per FTX1Remote's background-server
/// architecture — see repo root CLAUDE.md).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let hub: HubService

    /// `startingUpdater: true` starts Sparkle's automatic background check
    /// on launch (interval/opt-in governed by its own first-run permission
    /// prompt, not app code); the "Check for Updates…" menu item
    /// (`CheckForUpdatesView`) drives the same `updater` for manual checks.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Resolves which host `HubService` connects to once, at launch, per
    /// `RigctldSettings.connectionMode` — switching modes takes a relaunch
    /// to apply (see repo root CLAUDE.md's "Remote rigctld (Option A)"),
    /// so there's no need to re-check this after this point.
    override init() {
        switch RigctldSettings.connectionMode {
        case .local:
            hub = HubService()
        case .remote:
            hub = HubService(rigctldHost: RigctldSettings.remoteHost)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hub.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stop()
    }
}

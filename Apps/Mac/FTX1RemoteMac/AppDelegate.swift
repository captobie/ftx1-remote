import AppKit
import Sparkle

/// Owns the hub service at the app-delegate level so it keeps running
/// independent of window state (per FTX1Remote's background-server
/// architecture — see repo root CLAUDE.md).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let hub: HubService

    /// `startingUpdater: true` starts Sparkle's automatic background check
    /// on launch. Automatic checks default to on via `SUEnableAutomaticChecks`
    /// in `FTX1RemoteMac-Info.plist` (which also skips Sparkle's first-run
    /// permission prompt); Settings → Updates (`UpdaterSettingsViewModel`)
    /// toggles it per Mac. The "Check for Updates…" menu item
    /// (`CheckForUpdatesView`) drives the same `updater` for manual checks.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Resolves which host `HubService` connects to once, at launch, per
    /// `RigctldSettings.activeConnectionMode` — switching modes takes a relaunch
    /// to apply (see repo root CLAUDE.md's "Remote rigctld (Option A)"),
    /// so there's no need to re-check this after this point.
    override init() {
        switch RigctldSettings.activeConnectionMode {
        case .local:
            hub = HubService()
        case .remote:
            hub = HubService(rigctldHost: RigctldSettings.activeRemoteHost)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hub.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stop()
    }

    /// Quits and reopens the app, for settings that only apply at launch
    /// (the Local/Remote connection mode). A detached shell waits for this
    /// process to exit before running `open`, so the new instance can't
    /// start while this one is still shutting down (`applicationWillTerminate`
    /// stops rigctld and the WebSocket server first) — or be swallowed by
    /// `open` just re-activating the old one.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
        ]
        do {
            try task.run()
        } catch {
            // Without the helper nothing would reopen the app — stay
            // running rather than quit into nothing.
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}

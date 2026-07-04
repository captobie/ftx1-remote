import AppKit

/// Owns the hub service at the app-delegate level so it keeps running
/// independent of window state (per FTX1Remote's background-server
/// architecture — see repo root CLAUDE.md).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let hub = HubService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hub.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stop()
    }
}

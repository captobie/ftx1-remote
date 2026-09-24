import FTX1Core
import Sparkle
import SwiftUI

@main
struct FTX1RemoteMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppearanceSettings.themeKey) private var themeRawValue = AppTheme.system.rawValue
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.hub)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.updaterController.updater)
            }
            CommandGroup(after: .toolbar) {
                Menu("APRS") {
                    Button("Station List") {
                        openWindow(id: "aprs-stations")
                    }
                    Button("Message List") {
                        openWindow(id: "aprs-messages")
                    }
                    Divider()
                    Button("Map") {
                        openWindow(id: "aprs-map")
                    }
                }
            }
            // A top-level menu (CommandMenu), not nested under an existing
            // one (CommandGroup) like APRS above — first of what's meant to
            // grow into more than one digital mode (FT4, etc.), each its
            // own sibling Button/Window here.
            CommandMenu("Digital") {
                Button("FT8") {
                    openWindow(id: "ft8")
                }
                Divider()
                Button("WebSDR") {
                    openWindow(id: "websdr-follow")
                }
            }
        }

        // APRS S.LIST/M.LIST (`MenuPageView.aprsListButton`) open these by
        // id rather than a sheet, so a station/message list can stay open
        // alongside the main window while operating.
        Window("APRS Stations", id: "aprs-stations") {
            APRSStationListView()
                .environmentObject(appDelegate.hub.aprsStore)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }
        Window("APRS Messages", id: "aprs-messages") {
            APRSMessageListView()
                .environmentObject(appDelegate.hub.aprsStore)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }
        // Opened via the View menu's "APRS Map" command above, not from
        // MenuPageView — unlike S.LIST/M.LIST, a map isn't currently one
        // of the FM/C4FM page's numbered menu buttons.
        Window("APRS Map", id: "aprs-map") {
            APRSMapView()
                .environmentObject(appDelegate.hub.aprsStore)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }

        // Digital → FT8 (Digital menu above). Injects `hub` itself, not just
        // `hub.ft8Store` (unlike the APRS windows, which only need the
        // store) — `FT8ListView` calls `hub.startFT8Decoding()`/
        // `stopFT8Decoding()` from its own onAppear/onDisappear.
        Window("FT8", id: "ft8") {
            FT8ListView()
                .environmentObject(appDelegate.hub)
                .environmentObject(appDelegate.hub.ft8Store)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }

        // Digital → WebSDR. Passes `hub` in directly rather than via the
        // environment — `WebSDRFollowView` needs it in `init` to build its
        // `@StateObject` model, which subscribes to `hub.$rigState`.
        Window("WebSDR", id: "websdr-follow") {
            WebSDRFollowView(hub: appDelegate.hub)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }

        // CW page's PLAY button (`MenuPageView.playRecordingsButton`) opens
        // this by id, same "own window, not a sheet" treatment as the APRS
        // windows — a plain file browser, unrelated to `hub`/`RigController`.
        Window("Recordings", id: "recordings") {
            RecordingsListView()
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }

        // Replaces the old "Settings…" button in ContentView's toolbar row —
        // this scene type is what puts it in the app menu (⌘,) instead,
        // matching standard Mac app conventions.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.hub)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }
    }
}

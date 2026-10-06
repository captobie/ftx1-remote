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
            // A top-level menu (CommandMenu), not nested under an existing
            // one — holds APRS, the digital modes (FT8, FT4 later, etc.) and
            // other tools like WebSDR, each its own sibling Button/Window here.
            CommandMenu("Tools") {
                Menu("APRS") {
                    Button("List") {
                        openWindow(id: "aprs-stations")
                    }
                    Button("Messages") {
                        openWindow(id: "aprs-messages")
                    }
                    Button("Map") {
                        openWindow(id: "aprs-map")
                    }
                }
                Divider()
                Button("FT8") {
                    openWindow(id: "ft8")
                }
                Button("CW") {
                    openWindow(id: "cw")
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
        // Opened via Tools → APRS → Map above, not from
        // MenuPageView — unlike S.LIST/M.LIST, a map isn't currently one
        // of the FM/C4FM page's numbered menu buttons.
        Window("APRS Map", id: "aprs-map") {
            APRSMapView()
                .environmentObject(appDelegate.hub.aprsStore)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }

        // Tools → FT8 (Tools menu above). Injects `hub` itself, not just
        // `hub.ft8Store` (unlike the APRS windows, which only need the
        // store) — `FT8ListView` calls `hub.startFT8Decoding()`/
        // `stopFT8Decoding()` from its own onAppear/onDisappear.
        Window("FT8", id: "ft8") {
            FT8ListView()
                .environmentObject(appDelegate.hub)
                .environmentObject(appDelegate.hub.ft8Store)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }

        // Tools → CW. `hub` for the MAIN/SUB picker's single-receive
        // check and the send pane's keyer controls, `cwReceiver`/`cwSender`
        // for the two panes; decoding runs while the window is open, like FT8.
        Window("CW", id: "cw") {
            CWWindowView()
                .environmentObject(appDelegate.hub)
                .environmentObject(appDelegate.hub.cwReceiver)
                .environmentObject(appDelegate.hub.cwSender)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }

        // Tools → WebSDR. Passes `hub` in directly rather than via the
        // environment — `WebSDRFollowView` needs it in `init` to build its
        // `@StateObject` model, which subscribes to `hub.$rigState`.
        Window("WebSDR", id: "websdr-follow") {
            WebSDRFollowView(hub: appDelegate.hub)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }

        // The Mem List button under Waterfall (ContentView). `hub` to send
        // the MAIN/SUB recalls and highlight the current channels.
        Window("Memory Channels", id: "memory-list") {
            MemoryListView()
                .environmentObject(appDelegate.hub)
                .environmentObject(appDelegate.hub.memoryList)
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
            SettingsView(updater: appDelegate.updaterController.updater)
                .environmentObject(appDelegate.hub)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }
    }
}

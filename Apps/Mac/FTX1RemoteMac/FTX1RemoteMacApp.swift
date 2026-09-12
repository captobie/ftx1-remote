import FTX1Core
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
            CommandGroup(after: .toolbar) {
                Button("APRS Map") {
                    openWindow(id: "aprs-map")
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

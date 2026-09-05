import FTX1Core
import SwiftUI

@main
struct FTX1RemoteMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppearanceSettings.themeKey) private var themeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.hub)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
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
    }
}

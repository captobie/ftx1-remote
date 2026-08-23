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
    }
}

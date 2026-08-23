import FTX1Core
import SwiftUI

@main
struct FTX1RemoteiOSApp: App {
    @StateObject private var viewModel = RigClientViewModel()
    @AppStorage(AppearanceSettings.themeKey) private var themeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }
    }
}

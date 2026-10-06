import FTX1Core
import SwiftUI

@main
struct FTX1RemoteiOSApp: App {
    @StateObject private var viewModel = RigClientViewModel()
    @StateObject private var piViewModel = PiDirectViewModel(logSubsystem: "com.ftx1remote.ios")
    @AppStorage(AppearanceSettings.themeKey) private var themeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(piViewModel)
                .preferredColorScheme((AppTheme(rawValue: themeRawValue) ?? .system).colorScheme)
        }
    }
}

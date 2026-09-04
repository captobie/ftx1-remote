import FTX1Core
import SwiftUI

@main
struct FTX1RemoteiPadApp: App {
    @StateObject private var viewModel = RigClientViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
        }
    }
}

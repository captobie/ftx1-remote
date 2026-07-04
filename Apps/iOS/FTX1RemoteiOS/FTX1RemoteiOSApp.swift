import SwiftUI

@main
struct FTX1RemoteiOSApp: App {
    @StateObject private var viewModel = RigClientViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}

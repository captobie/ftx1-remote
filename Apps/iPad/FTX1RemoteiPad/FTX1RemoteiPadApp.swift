import FTX1Core
import SwiftUI

@main
struct FTX1RemoteiPadApp: App {
    @StateObject private var viewModel = RigClientViewModel()
    @StateObject private var piViewModel = PiDirectViewModel(
        logSubsystem: "com.ftx1remote.ipad",
        playsSubAudio: true,
        readsSMeter: true,
        readsVFODetails: true
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(piViewModel)
                .preferredColorScheme(.dark)
        }
    }
}

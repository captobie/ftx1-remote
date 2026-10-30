import FTX1Core
import SwiftUI

@main
struct FTX1RemoteiOSApp: App {
    @StateObject private var viewModel = RigClientViewModel()
    @StateObject private var piViewModel = PiDirectViewModel(logSubsystem: "com.ftx1remote.ios", playsSubAudio: true, readsSMeter: true, readsPower: true)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(piViewModel)
                .preferredColorScheme(.dark)
        }
    }
}

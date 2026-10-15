import FTX1CW
import FTX1Core
import SwiftUI

@main
struct FTX1RemoteiPadApp: App {
    @StateObject private var viewModel = RigClientViewModel()
    @StateObject private var piViewModel = PiDirectViewModel(
        logSubsystem: "com.ftx1remote.ipad",
        playsSubAudio: true,
        readsSMeter: true,
        readsVFODetails: true,
        readsMenuSettings: true,
        readsFilters: true,
        decodesAPRS: true
    )
    /// The CW pane's decoder, shared by both routes (fed their audio below).
    @StateObject private var cwReceiver = CWReceiver(logSubsystem: "com.ftx1remote.ipad", channels: [.main, .sub])

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(piViewModel)
                .environmentObject(cwReceiver)
                // Both routes' 8 kHz receive audio to the CW decoder, which
                // keeps only the selected receiver and only while its pane
                // is open.
                .onAppear {
                    // The receiver lives as long as the app.
                    let receiver = cwReceiver
                    let feed: @MainActor (Data, FilterSide) -> Void = { pcm, side in
                        receiver.ingest(pcm: pcm, sampleRate: AudioStreamFormat.sampleRate, channel: side == .main ? .main : .sub)
                    }
                    viewModel.onReceiveAudio = feed
                    piViewModel.onReceiveAudio = feed
                }
                .preferredColorScheme(.dark)
        }
    }
}

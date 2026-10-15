import FTX1CW
import FTX1Core
import SwiftUI

@main
struct FTX1RemoteiPadApp: App {
    @StateObject private var viewModel = RigClientViewModel()
    @StateObject private var piViewModel: PiDirectViewModel
    /// The CW pane's decoder, shared by both routes (fed their audio below).
    @StateObject private var cwReceiver = CWReceiver(logSubsystem: "com.ftx1remote.ipad", channels: [.main, .sub])
    /// The CW pane's send section — Pi direct only for now (the hub route
    /// needs wire messages for the keyer first), so it keys through
    /// `piViewModel`.
    @StateObject private var cwSender: CWSender

    init() {
        let piViewModel = PiDirectViewModel(
            logSubsystem: "com.ftx1remote.ipad",
            playsSubAudio: true,
            readsSMeter: true,
            readsVFODetails: true,
            readsMenuSettings: true,
            readsFilters: true,
            decodesAPRS: true
        )
        _piViewModel = StateObject(wrappedValue: piViewModel)
        _cwSender = StateObject(wrappedValue: CWSender(link: piViewModel, logSubsystem: "com.ftx1remote.ipad"))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(piViewModel)
                .environmentObject(cwReceiver)
                .environmentObject(cwSender)
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
                    // No decoding the operator's own sidetone while sending.
                    cwSender.onActiveChanged = { receiver.setSenderActive($0) }
                }
                // As on the Mac: locking transmit, or the link going away,
                // stops the sender and drops what's queued (the model sends
                // "KY00" itself on a lock or a disconnect).
                .onChange(of: piViewModel.transmitEnabled) { _, enabled in
                    if !enabled { cwSender.stop() }
                }
                .onChange(of: piViewModel.connectionState) { _, state in
                    if state != .connected { cwSender.stop() }
                }
                .preferredColorScheme(.dark)
        }
    }
}

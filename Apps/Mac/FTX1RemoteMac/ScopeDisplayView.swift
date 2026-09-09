import Combine
import CoreGraphics
import SwiftUI

/// Holds the most recent waterfall/oscilloscope frames from
/// `AudioCaptureEngine`, published at its ~21 Hz frame rate. Split out of
/// `HubService` on purpose: `ScopeDisplayView` is the only thing that needs
/// to re-render per frame, and `ObservableObject` invalidation is per
/// object, not per property — while these lived on `HubService`, every
/// frame re-evaluated all of `ContentView` (see the `scopeFrames` doc
/// comment on `HubService` for the measured cost). Both frames are always
/// stored, so switching display mode is instant with no capture restart.
@MainActor
final class ScopeFrameStore: ObservableObject {
    @Published private(set) var waterfall: CGImage?
    @Published private(set) var oscilloscope: CGImage?

    func update(_ frame: AudioCaptureFrame) {
        waterfall = frame.waterfall
        oscilloscope = frame.oscilloscope
    }

    func clear() {
        waterfall = nil
        oscilloscope = nil
    }
}

/// Draws whatever frame `ScopeFrameStore` last received for the currently
/// selected mode (waterfall or oscilloscope) — a dumb view, no DSP or mode
/// switching of its own (see `AudioCaptureEngine`, `ContentView`'s
/// `ScopeDisplayMode`). Observes the store itself rather than taking a
/// `CGImage` from its parent, so per-frame invalidation stays confined to
/// this leaf (see `ScopeFrameStore`). Dark-box styling matches `SMeterView`/
/// `VFODisplayBox` so it reads as part of the same instrument cluster;
/// dims per `VFODisplayBox`'s `isActive` convention while rigctld isn't
/// connected, rather than hiding outright, so the row's layout doesn't
/// jump as the connection toggles.
struct ScopeDisplayView: View {
    @ObservedObject var frames: ScopeFrameStore
    let mode: ScopeDisplayMode
    let isActive: Bool

    private var image: CGImage? {
        switch mode {
        case .waterfall: frames.waterfall
        case .oscilloscope: frames.oscilloscope
        case .off: nil
        }
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if let image {
                context.draw(Image(image, scale: 1, label: Text("Scope display")), in: rect)
            }
        }
        .opacity(isActive ? 1 : 0.4)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.4), lineWidth: 1.5)
        )
    }
}

#Preview("Active, no signal yet") {
    ScopeDisplayView(frames: ScopeFrameStore(), mode: .waterfall, isActive: true)
        .frame(width: 400, height: 120)
        .padding()
}

#Preview("Inactive") {
    ScopeDisplayView(frames: ScopeFrameStore(), mode: .waterfall, isActive: false)
        .frame(width: 400, height: 120)
        .padding()
}

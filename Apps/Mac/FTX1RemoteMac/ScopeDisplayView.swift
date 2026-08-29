import CoreGraphics
import SwiftUI

/// Draws whatever frame `HubService` last published for the currently
/// selected mode (waterfall or oscilloscope) — a dumb view, no DSP or mode
/// switching of its own (see `AudioCaptureEngine`, `ContentView`'s
/// `ScopeDisplayMode`). Dark-box styling matches `SMeterView`/
/// `VFODisplayBox` so it reads as part of the same instrument cluster;
/// dims per `VFODisplayBox`'s `isActive` convention while rigctld isn't
/// connected, rather than hiding outright, so the row's layout doesn't
/// jump as the connection toggles.
struct ScopeDisplayView: View {
    let image: CGImage?
    let isActive: Bool

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
    ScopeDisplayView(image: nil, isActive: true)
        .frame(width: 400, height: 120)
        .padding()
}

#Preview("Inactive") {
    ScopeDisplayView(image: nil, isActive: false)
        .frame(width: 400, height: 120)
        .padding()
}

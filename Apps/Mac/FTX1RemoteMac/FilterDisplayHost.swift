import SwiftUI
import FTX1Core

/// Mac-side wrapper that feeds the shared `FilterDisplayView`: builds the
/// `FilterPassbandModel` from `HubService`'s rig state and hands it the
/// live audio spectrum from `ScopeFrameStore`. This is the only view
/// besides `ScopeDisplayView` that observes the store, so its ~21 Hz
/// per-frame invalidation stays confined to this leaf and never touches
/// the Filter-row controls or the rest of `ContentView` (see the
/// `ScopeFrameStore` doc comment for why that matters).
///
/// The spectrum is dropped (shape only) when the scope column is Off —
/// `AudioCaptureEngine.displayEnabled` stops computing the FFT then, so
/// the store's last frame would just go stale — and while disconnected.
struct FilterDisplayHost: View {
    @EnvironmentObject private var hub: HubService
    @ObservedObject var frames: ScopeFrameStore
    let scopeMode: ScopeDisplayMode

    var body: some View {
        let connected = hub.connectionState == .connected
        FilterDisplayView(
            model: FilterPassbandModel(state: hub.rigState),
            spectrum: (connected && scopeMode != .off) ? frames.spectrum : [],
            isActive: connected
        )
    }
}

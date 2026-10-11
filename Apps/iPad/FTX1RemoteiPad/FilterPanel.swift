import FTX1Core
import SwiftUI

/// The Mac `ContentView`'s Filter block on the iPad, between the meter
/// strips and the MENU grid (always visible — user decision, 2026-10-11):
/// WIDTH/SHIFT on the first row, CONTOUR-or-APF, N/W and NOTCH on the
/// second, then the MAIN/SUB `FilterSideSelector` and the Filter Function
/// Display. All the controls are the shared `FTX1Core` views, so this only
/// arranges them. Generic over `RigController` so both iPad screens can use
/// it — the hub screen drives it with `RigClientViewModel`, whose commands
/// and filter state already cross the WebSocket, and the Pi-direct screen
/// with `PiDirectViewModel` (`readsFilters`).
///
/// `spectrumStore` is the display's audio overlay, computed on the iPad
/// from the receive audio it already gets (`FilterSpectrumStore`); the
/// display turns it on only while it's on screen.
///
/// Picked by `ViewThatFits`, widest first: the Mac's arrangement (both
/// control rows, then selector + display) in landscape; in portrait the
/// selector + display with WIDTH and SHIFT stacked beside them and the
/// second row underneath; failing that, everything stacked.
struct FilterPanel<Controller: RigController>: View {
    let spectrumStore: FilterSpectrumStore
    let isActive: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                controls
                sideAndDisplay
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 16) {
                    sideAndDisplay
                    VStack(alignment: .leading, spacing: 8) {
                        FilterWidthControl<Controller>()
                        IFShiftControl<Controller>()
                    }
                    .fixedSize()
                }
                secondRow
            }
            VStack(alignment: .leading, spacing: 12) {
                sideAndDisplay
                controls
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Out here, not on the display: each `ViewThatFits` layout has its
        // own display, and on rotation the new one can appear before the
        // old one disappears.
        .onAppear { spectrumStore.isEnabled = true }
        .onDisappear { spectrumStore.isEnabled = false }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                FilterWidthControl<Controller>()
                IFShiftControl<Controller>()
            }
            secondRow
        }
        .fixedSize()
    }

    private var secondRow: some View {
        HStack(spacing: 16) {
            ContourAPFControl<Controller>()
            NarrowControl<Controller>()
            IFNotchControl<Controller>()
        }
        .fixedSize()
    }

    private var sideAndDisplay: some View {
        HStack(spacing: 12) {
            FilterSideSelector<Controller>()
            FilterDisplayHostView<Controller>(spectrumStore: spectrumStore, isActive: isActive)
        }
    }
}

/// Builds the display's `FilterPassbandModel` from the controller's state
/// and draws the spectrum over it. The only view observing
/// `spectrumStore`, so its ~21 updates a second re-render nothing else.
private struct FilterDisplayHostView<Controller: RigController>: View {
    @EnvironmentObject private var hub: Controller
    @ObservedObject var spectrumStore: FilterSpectrumStore
    let isActive: Bool

    var body: some View {
        FilterDisplayView(
            model: FilterPassbandModel(state: hub.rigState),
            spectrum: isActive ? spectrumStore.spectrum : [],
            isActive: isActive
        )
    }
}

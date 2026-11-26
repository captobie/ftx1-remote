import FTX1Core
import SwiftUI

/// The SDR pane's split screen (user design, 2026-11-26): the SDR beside
/// (landscape) or above (portrait) the rig's VFO boxes, meter + audio
/// strips and filter block, with the MENU grid left out. The top row stays
/// full width above it (the screen draws that). Orientation is the shape of
/// the space given, so Split View and Stage Manager windows pick what fits.
///
/// `side(narrow)` is the rig column: `narrow` = the landscape column, where
/// the VFO boxes and strips stack instead of sitting side by side.
struct SDRSplitLayout<SDR: View, Side: View>: View {
    let sdr: SDR
    @ViewBuilder let side: (_ narrow: Bool) -> Side

    /// Portrait: the SDR's share of the height (its waterfall, tuning,
    /// meter and rig-link rows need about this much on an 11-inch iPad).
    private static var portraitSDRFraction: CGFloat { 0.56 }
    private static var portraitSDRMinHeight: CGFloat { 560 }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if size.width > size.height {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) { side(true) }
                    }
                    .frame(width: max(360, size.width * 0.4))
                    sdr
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    sdr
                        .frame(height: min(size.height, max(Self.portraitSDRMinHeight,
                                                            size.height * Self.portraitSDRFraction)))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) { side(false) }
                    }
                }
            }
        }
    }
}

extension View {
    /// The SDR's connection follows the pane, not its layout (switching
    /// between the overlay and the split screen rebuilds the views): hiding
    /// the pane, the route dropping (the pane needs it) or the screen going
    /// away disconnects.
    func sdrSession(isShowing: Binding<Bool>, routeConnected: Bool, model: LocalSDRModel,
                    webModel: WebSDRFollowModel) -> some View {
        self
            .onChange(of: isShowing.wrappedValue) { _, showing in
                if !showing {
                    model.disconnect()
                    webModel.disconnect()
                }
            }
            .onChange(of: routeConnected) { _, connected in
                if !connected { isShowing.wrappedValue = false }
            }
            .onDisappear {
                model.disconnect()
                webModel.disconnect()
            }
    }
}

/// The VFO boxes and strips: side by side, or stacked in the split
/// screen's landscape column. One `AnyLayout`, so their identity (and an
/// open popover) survives the switch.
struct RigRow<Content: View>: View {
    let stacked: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout { content }
    }
}

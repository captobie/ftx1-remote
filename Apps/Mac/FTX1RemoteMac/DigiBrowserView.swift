import FTX1Digi
import SwiftUI

/// The RTTY/PSK window's PSK browser (BPSK31/BPSK63, Browser on): one
/// line per signal found in the passband, lowest frequency first, each
/// decoded on its own (`PSKBrowser`), like fldigi's signal browser. A
/// click on a line moves the main decoder there, whose full text then
/// prints below. Observes only `PSKBrowserStore` (~4 updates a second)
/// and the tracked frequency for the highlight.
struct DigiBrowserList: View {
    @EnvironmentObject private var receiver: DigiReceiver
    @ObservedObject var store: PSKBrowserStore
    @ObservedObject var meters: DigiMeterStore

    var body: some View {
        Group {
            if store.channels.isEmpty {
                Text("digiWindow.browserPlaceholder")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.channels) { channel in
                            row(channel)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ channel: PSKBrowserChannel) -> some View {
        let isTracked = abs(channel.frequencyHz - meters.trackedHz) < receiver.mode.bandwidthHz(rtty: receiver.rttySettings) / 2
        return HStack(spacing: 10) {
            Text(verbatim: "\(Int(channel.frequencyHz.rounded()))")
                .font(.system(.callout, design: .monospaced))
                .frame(width: 44, alignment: .trailing)
            Capsule()
                .fill(Double(channel.quality) >= receiver.squelch ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: max(3, 36 * CGFloat(channel.quality)), height: 5)
                .frame(width: 36, alignment: .leading)
            Text(verbatim: channel.text)
                .font(.system(size: 14, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(channel.isActive ? 1 : 0.5)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(isTracked ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { receiver.setCenter(channel.frequencyHz) }
        .help("digiWindow.browserRowHelp")
    }
}

/// A small tick at the top of the tuning strip for each browser channel
/// (green while its signal is there). Its own view so the store's updates
/// redraw only the ticks.
struct DigiBrowserMarks: View {
    @ObservedObject var store: PSKBrowserStore
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.channels) { channel in
                Rectangle()
                    .fill(channel.isActive ? Color.green : Color.gray)
                    .frame(width: 2, height: 9)
                    .offset(x: CGFloat(channel.frequencyHz / DigiDecoder.stripSpanHz) * width - 1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

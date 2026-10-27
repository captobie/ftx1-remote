import CWKit
import FTX1CW
import FTX1Core
import SwiftUI

/// The iPad's CW decoder: shown in place of the filter block and the MENU
/// grid — the same area as `APRSListPane` — while the top row's CW button
/// is on, on both routes. The shared `CWReceiver` (`FTX1CW`, the Mac's
/// Tools → CW decoder) is fed the route's 8 kHz MAIN/SUB audio
/// (`onReceiveAudio`), and decodes only while this pane is showing on a
/// connected route.
///
/// Sending: `CWSendSection` under the tuning row, on the shared
/// `CWSender` (pointed at the route in use), which pauses the decoder
/// while it runs (`CWReceiver.setSenderActive(_:)`). Pi direct since
/// phase 2, the hub route since phase 3.
struct CWPane<SendSection: View>: View {
    @EnvironmentObject private var receiver: CWReceiver
    @Binding var isShowing: Bool
    /// The rig is in single-receive display: no SUB.
    let singleReceive: Bool
    let sendSection: SendSection

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CWSignalStatusBar(meters: receiver.meters, isDecodingFile: receiver.isDecodingFile, sourceNote: sourceNote)
            Divider()
            CWDecodedText(text: receiver.decodedText, tentative: receiver.tentativeText)
            Divider()
            CWTuningControls(meters: receiver.meters)
            if SendSection.self != EmptyView.self {
                Divider()
                sendSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("common.receiver", selection: $receiver.channel) {
                ForEach([CWAudioChannel.main, .sub], id: \.self) { channel in
                    Text(channel.title).tag(channel)
                        .selectionDisabled(channel == .sub && subUnavailableReason != nil)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            CWDecoderPicker()

            Spacer()
            // Icons alone when the titles don't fit (longer translations).
            ViewThatFits(in: .horizontal) {
                actionButtons.labelStyle(.titleAndIcon)
                actionButtons.labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = receiver.decodedText
            } label: {
                Label("common.copy", systemImage: "doc.on.doc")
            }
            .disabled(receiver.decodedText.isEmpty)

            Button {
                receiver.clearText()
            } label: {
                Label("common.clear", systemImage: "trash")
            }
            .disabled(receiver.decodedText.isEmpty)

            Button {
                isShowing = false
            } label: {
                Label("common.close", systemImage: "xmark")
            }
        }
        .lineLimit(1)
    }

    /// Why SUB can't be picked, or nil when it can. On the hub route the
    /// Mac relays SUB audio only from a stereo input.
    private var subUnavailableReason: String? {
        if singleReceive { return String(localized: "common.subIsOffThe") }
        if !receiver.isSubAudioAvailable { return String(localized: "cwPane.noSubAudioYet") }
        return nil
    }

    private var sourceNote: String? {
        if receiver.isPausedForTransmit {
            return String(localized: "common.pausedWhileTransmitting")
        }
        if receiver.channel == .sub, let subUnavailableReason {
            return subUnavailableReason
        }
        if let mode = receiver.sourceModeIfNotCW {
            return String(localized: "common.isInNotCw \(receiver.channel.title) \(mode.displayName)")
        }
        return nil
    }
}

/// The decoded text, newest at the bottom; the neural decoder's tentative
/// text dimmed after it.
private struct CWDecodedText: View {
    let text: String
    let tentative: String

    var body: some View {
        ScrollView {
            Group {
                if text.isEmpty && tentative.isEmpty {
                    Text("common.decodedCwFromThe")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(text)\(Text(tentative).foregroundStyle(.tertiary))")
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 20, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding()
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// The top row's CW button: shows or hides `CWPane`. Turning it on closes
/// the APRS lists, which use the same area.
struct CWPaneButton: View {
    @Binding var isShowing: Bool
    @Binding var aprsListKind: APRSListKind?

    var body: some View {
        Button {
            isShowing.toggle()
            if isShowing { aprsListKind = nil }
        } label: {
            Text("CW")
                .fontWeight(isShowing ? .bold : .regular)
                .foregroundStyle(isShowing ? Color.white : Color.primary)
        }
        .tint(isShowing ? .accentColor : nil)
        .accessibilityLabel(isShowing ? "common.hideTheCwDecoder" : "common.showTheCwDecoder")
    }
}

extension View {
    /// Shows `CWPane` over this view (the filter block + MENU grid) while
    /// `isShowing`, hiding — not removing — the view underneath, as
    /// `aprsListPane` does. Also runs the decoder: on while the pane shows
    /// on a connected route (`isConnected`), off otherwise, and keeps it
    /// told about TX, the CW pitch and the modes (`rigInfo`).
    /// `sendSection` goes under the tuning row (`CWSendSection` on Pi
    /// direct); with one, the area is given at least `sendingMinHeight` so
    /// the decoded text keeps room.
    func cwPane<SendSection: View>(
        isShowing: Binding<Bool>, isConnected: Bool, rigInfo: CWRigInfo, singleReceive: Bool,
        @ViewBuilder sendSection: () -> SendSection = { EmptyView() }
    ) -> some View {
        modifier(CWPaneModifier(isShowing: isShowing, isConnected: isConnected, rigInfo: rigInfo,
                                singleReceive: singleReceive, sendSection: sendSection()))
    }
}

/// With the send section the pane needs more than the filter block + MENU
/// grid it covers (~490 pt in portrait): decoded text, tuning row, then
/// keyer controls, macros, the send log and the input line.
private let sendingMinHeight: CGFloat = 780

private struct CWPaneModifier<SendSection: View>: ViewModifier {
    @EnvironmentObject private var receiver: CWReceiver
    @Binding var isShowing: Bool
    let isConnected: Bool
    let rigInfo: CWRigInfo
    let singleReceive: Bool
    let sendSection: SendSection

    private var hasSendSection: Bool { SendSection.self != EmptyView.self }

    func body(content: Content) -> some View {
        content
            .frame(minHeight: isShowing && hasSendSection ? sendingMinHeight : nil, alignment: .top)
            .opacity(isShowing ? 0 : 1)
            .allowsHitTesting(!isShowing)
            .accessibilityHidden(isShowing)
            .overlay {
                if isShowing {
                    CWPane(isShowing: $isShowing, singleReceive: singleReceive, sendSection: sendSection)
                }
            }
            .onChange(of: isShowing && isConnected, initial: true) { _, decoding in
                if decoding { receiver.start() } else { receiver.stop() }
            }
            .onChange(of: rigInfo, initial: true) { _, info in
                receiver.rigInfoChanged(info)
            }
            .onDisappear { receiver.stop() }
    }
}

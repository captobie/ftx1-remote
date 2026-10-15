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
/// Receive only for now. The send controls are meant to go in a section of
/// their own under the tuning row (see the Mac's `CWSendPane`), pausing
/// the decoder through `CWReceiver.setSenderActive(_:)` as the Mac's do.
struct CWPane: View {
    @EnvironmentObject private var receiver: CWReceiver
    @Binding var isShowing: Bool
    /// The rig is in single-receive display: no SUB.
    let singleReceive: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CWSignalStatusBar(meters: receiver.meters, isDecodingFile: receiver.isDecodingFile, sourceNote: sourceNote)
            Divider()
            CWDecodedText(text: receiver.decodedText, tentative: receiver.tentativeText)
            Divider()
            CWTuningControls(meters: receiver.meters)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Receiver", selection: $receiver.channel) {
                ForEach([CWAudioChannel.main, .sub], id: \.self) { channel in
                    Text(channel.title).tag(channel)
                        .selectionDisabled(channel == .sub && subUnavailableReason != nil)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            CWDecoderPicker()

            Spacer()

            Button {
                UIPasteboard.general.string = receiver.decodedText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(receiver.decodedText.isEmpty)

            Button {
                receiver.clearText()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(receiver.decodedText.isEmpty)

            Button {
                isShowing = false
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
    }

    /// Why SUB can't be picked, or nil when it can. On the hub route the
    /// Mac relays SUB audio only from a stereo input.
    private var subUnavailableReason: String? {
        if singleReceive { return "SUB is off: the rig is in single-receive display" }
        if !receiver.isSubAudioAvailable { return "No SUB audio yet" }
        return nil
    }

    private var sourceNote: String? {
        if receiver.isPausedForTransmit {
            return "Paused while transmitting"
        }
        if receiver.channel == .sub, let subUnavailableReason {
            return subUnavailableReason
        }
        if let mode = receiver.sourceModeIfNotCW {
            return "\(receiver.channel.title) is in \(mode.displayName), not CW — decoding anyway"
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
                    Text("Decoded CW from the selected receiver appears here. Tune to a CW signal.")
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
        .accessibilityLabel(isShowing ? "Hide the CW decoder" : "Show the CW decoder")
    }
}

extension View {
    /// Shows `CWPane` over this view (the filter block + MENU grid) while
    /// `isShowing`, hiding — not removing — the view underneath, as
    /// `aprsListPane` does. Also runs the decoder: on while the pane shows
    /// on a connected route (`isConnected`), off otherwise, and keeps it
    /// told about TX, the CW pitch and the modes (`rigInfo`).
    func cwPane(isShowing: Binding<Bool>, isConnected: Bool, rigInfo: CWRigInfo, singleReceive: Bool) -> some View {
        modifier(CWPaneModifier(isShowing: isShowing, isConnected: isConnected, rigInfo: rigInfo, singleReceive: singleReceive))
    }
}

private struct CWPaneModifier: ViewModifier {
    @EnvironmentObject private var receiver: CWReceiver
    @Binding var isShowing: Bool
    let isConnected: Bool
    let rigInfo: CWRigInfo
    let singleReceive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShowing ? 0 : 1)
            .allowsHitTesting(!isShowing)
            .accessibilityHidden(isShowing)
            .overlay {
                if isShowing {
                    CWPane(isShowing: $isShowing, singleReceive: singleReceive)
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

import SwiftUI

/// Hold-to-talk PTT for the top row of both iPad screens, right of the
/// Connected button: the same width (a hidden "Connected" behind the
/// label) but taller, 48 pt, since it's the control that must be easy to
/// hit and hold. Keys on touch-down and unkeys on release — the `DragGesture`
/// pattern the hub screen's old full-width PTT used.
///
/// `blockReason` non-nil: dimmed and inert (the route's transmit gate
/// says no). The models check the gate again on press regardless.
struct PTTButton: View {
    let isTransmitting: Bool
    let blockReason: String?
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            Text("common.connected").hidden()
            HStack(spacing: 6) {
                // Blocked: a lock says so at a glance instead of only dimming.
                if blockReason != nil && !isTransmitting {
                    Image(systemName: "lock.fill").imageScale(.small)
                }
                Text(isTransmitting ? "TX" : "PTT")
            }
        }
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(isTransmitting ? Color.red : Color.gray.opacity(0.25))
        .foregroundStyle(isTransmitting ? Color.white : (blockReason == nil ? Color.primary : Color.secondary))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(blockReason == nil || isTransmitting ? 1 : 0.7)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    if blockReason == nil { onPress() }
                }
                .onEnded { _ in
                    isPressed = false
                    onRelease()
                }
        )
        .accessibilityLabel(isTransmitting ? "pttButton.transmitting" : "pttButton.pushToTalk")
        .accessibilityHint(blockReason ?? String(localized: "pttButton.holdToTransmit"))
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    HStack {
        PTTButton(isTransmitting: false, blockReason: nil, onPress: {}, onRelease: {})
        PTTButton(isTransmitting: true, blockReason: nil, onPress: {}, onRelease: {})
        PTTButton(isTransmitting: false, blockReason: String(localized: "common.transmitDisabled"), onPress: {}, onRelease: {})
    }
    .padding()
}

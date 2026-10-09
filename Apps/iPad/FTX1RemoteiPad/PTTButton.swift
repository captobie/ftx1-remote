import SwiftUI

/// Hold-to-talk PTT for the top row of both iPad screens, right of the
/// Connected button and the same size: same font, padding and corner
/// radius, and a hidden "Connected" behind the label so the width matches
/// too. Keys on touch-down and unkeys on release — the `DragGesture`
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
            Text("Connected").hidden()
            Text(isTransmitting ? "TX" : "PTT")
        }
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isTransmitting ? Color.red : Color.gray.opacity(0.25))
        .foregroundStyle(isTransmitting ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(blockReason == nil || isTransmitting ? 1 : 0.4)
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
        .accessibilityLabel(isTransmitting ? "Transmitting" : "Push to talk")
        .accessibilityHint(blockReason ?? "Hold to transmit")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    HStack {
        PTTButton(isTransmitting: false, blockReason: nil, onPress: {}, onRelease: {})
        PTTButton(isTransmitting: true, blockReason: nil, onPress: {}, onRelease: {})
        PTTButton(isTransmitting: false, blockReason: "Transmit disabled", onPress: {}, onRelease: {})
    }
    .padding()
}

import SwiftUI

/// Hold-to-talk PTT along the bottom of both iPhone screens, full width
/// and tall enough for a thumb. Keys on touch-down and unkeys on release
/// — a zero-distance `DragGesture`, since a plain `Button` only fires on
/// release; `isPressed` keeps `onChanged` from re-keying during the hold.
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
        Text(isTransmitting ? "TRANSMITTING" : "PTT")
            .font(.title2.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(isTransmitting ? Color.red : Color.gray.opacity(0.25))
            .foregroundStyle(isTransmitting ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
            .accessibilityLabel(isTransmitting ? "pttButton.transmitting" : "pttButton.pushToTalk")
            .accessibilityHint(blockReason ?? String(localized: "pttButton.holdToTransmit"))
            .accessibilityAddTraits(.isButton)
    }
}

/// The transmit lock right of the Connected button: locked (gray) blocks
/// PTT, unlocked (red) allows it. Each route says what it locks — the
/// hub's Enable Transmit or Pi direct's own — through `action` and the
/// accessibility labels.
struct TransmitLockButton: View {
    let isEnabled: Bool
    let enabledLabel: LocalizedStringKey
    let disabledLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isEnabled ? "lock.open.fill" : "lock.fill")
                .font(.headline)
                .foregroundStyle(isEnabled ? Color.white : Color.primary)
        }
        .buttonStyle(.bordered)
        .tint(isEnabled ? .red : nil)
        .accessibilityLabel(isEnabled ? enabledLabel : disabledLabel)
    }
}

#Preview {
    VStack {
        HStack {
            TransmitLockButton(isEnabled: false, enabledLabel: "common.transmitEnabledTapTo", disabledLabel: "common.transmitDisabledTapTo", action: {})
            TransmitLockButton(isEnabled: true, enabledLabel: "common.transmitEnabledTapTo", disabledLabel: "common.transmitDisabledTapTo", action: {})
        }
        PTTButton(isTransmitting: false, blockReason: nil, onPress: {}, onRelease: {})
        PTTButton(isTransmitting: true, blockReason: nil, onPress: {}, onRelease: {})
        PTTButton(isTransmitting: false, blockReason: String(localized: "common.transmitDisabled"), onPress: {}, onRelease: {})
    }
    .padding()
}

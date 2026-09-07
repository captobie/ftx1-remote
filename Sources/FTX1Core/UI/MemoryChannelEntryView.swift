import SwiftUI

/// Popover content for directly entering a memory channel number or
/// stepping it with up/down arrows — presented by `VFODisplayBox` in place
/// of `FrequencyEntryView` while `vfoMemoryMode == .memory`. Sibling to
/// `FrequencyEntryView`, same shared-across-targets rationale, even though
/// only the Mac app wires the callbacks today.
///
/// Unlike `FrequencyEntryView`'s step buttons, which compute the new value
/// client-side (pure arithmetic), the step buttons here call `onStep(_:)`
/// and let the server resolve what "up"/"down" actually does — the FTX-1's
/// raw "CH" CAT command's exact wrap-around and MAIN/SUB-side behavior
/// isn't hardware-confirmed yet (see `RigCommand.stepMemoryChannel`), so the
/// client shouldn't bake in an assumption about it.
public struct MemoryChannelEntryView: View {
    let currentChannel: Int?
    let onSetChannel: (Int) -> Void
    let onStep: (Bool) -> Void

    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    public init(currentChannel: Int?, onSetChannel: @escaping (Int) -> Void, onStep: @escaping (Bool) -> Void) {
        self.currentChannel = currentChannel
        self.onSetChannel = onSetChannel
        self.onStep = onStep
        _text = State(initialValue: currentChannel.map(String.init) ?? "")
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Channel", text: $text)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit(commitText)
                Button("Set", action: commitText)
            }

            HStack(spacing: 20) {
                Button {
                    onStep(false)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 32, height: 32)
                }
                Button {
                    onStep(true)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func commitText() {
        guard let channel = Int(text), (1...99).contains(channel) else { return }
        onSetChannel(channel)
        dismiss()
    }
}

#Preview {
    MemoryChannelEntryView(currentChannel: 5, onSetChannel: { _ in }, onStep: { _ in })
}

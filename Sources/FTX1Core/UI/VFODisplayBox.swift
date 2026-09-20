import SwiftUI

/// One VFO's frequency rendered as a dark digital-readout box, styled after
/// the rig's own LCD — used in a side-by-side pair in `ContentView`. Shared
/// by the Mac and iPad apps, which both want the dense side-by-side VFO A/B
/// layout (iOS uses its own single-VFO `FrequencyDisplay` instead).
public struct VFODisplayBox: View {
    let label: String
    let frequencyHz: Int?
    let isActive: Bool
    let mode: String
    /// "TXRX"/"RX"/"TX" indicator shown next to `label`, matching the
    /// rig's own display — see `RigState.splitEnabled`: `nil` (the
    /// default, also used before the first successful read) shows nothing,
    /// same as every other not-yet-read field in this view.
    let txRxLabel: String?
    /// Callsign most recently associated with whichever digital mode is
    /// active on this VFO: the station currently being received in C4FM
    /// (see `RigState.c4fmCallsign`), or — while `aprsActive` — the most
    /// recently APRS-decoded station's callsign (see
    /// `RigState.aprsLastCallsign`, already expired back to `nil` after 5
    /// seconds by the time it reaches here). `nil` (the default) shows
    /// nothing extra; callers are expected to only pass a value under the
    /// matching condition.
    let callsign: String?
    /// Name of the YSF reflector the WPSD hotspot is currently linked to, if
    /// known — see `RigState.c4fmReflector`. `nil` (the default) shows
    /// nothing extra; same "only while this VFO is in C4FM mode" contract
    /// as `callsign`.
    let reflector: String?
    /// Whether this VFO is currently parked on the configured APRS
    /// frequency — see `RigState.aprsActive`. Shows a static "APRS"
    /// indicator under `mode`, the same slot `reflector` occupies for
    /// C4FM (the two are mutually exclusive in practice).
    let aprsActive: Bool
    /// Tap-to-edit callback for this VFO's frequency. `nil` (the default)
    /// leaves the display read-only — used for VFO B, which has no
    /// corresponding `RigCommand` to write back through today.
    let onSetFrequency: ((Int) -> Void)?
    /// VFO-vs-memory mode (see `RigState.vfoMemoryMode`). `nil` (the
    /// default) behaves exactly as before this existed — plain VFO
    /// display/tap-to-set-frequency. Only VFO A wires this up today; VFO B
    /// leaves it `nil`.
    let vfoMemoryMode: VFOMemoryMode?
    /// Currently-selected memory channel, shown on the top line alongside
    /// `mode` and passed through to the memory popover — see
    /// `RigState.memoryChannel`.
    let memoryChannel: Int?
    /// `memoryChannel`'s user-assigned name, if any — see
    /// `RigState.memoryChannelTag`. Shown next to the channel number on the
    /// top line when present.
    let memoryChannelTag: String?
    /// Direct memory-channel-entry callback — see `onSetFrequency`. Only
    /// used while `vfoMemoryMode == .memory`.
    let onSetMemoryChannel: ((Int) -> Void)?
    /// Up/down memory-channel-step callback — see `onSetFrequency`. Only
    /// used while `vfoMemoryMode == .memory`.
    let onStepMemoryChannel: ((Bool) -> Void)?

    @State private var isEditing = false

    public init(
        label: String,
        frequencyHz: Int?,
        isActive: Bool,
        mode: String,
        txRxLabel: String? = nil,
        callsign: String? = nil,
        reflector: String? = nil,
        aprsActive: Bool = false,
        onSetFrequency: ((Int) -> Void)? = nil,
        vfoMemoryMode: VFOMemoryMode? = nil,
        memoryChannel: Int? = nil,
        memoryChannelTag: String? = nil,
        onSetMemoryChannel: ((Int) -> Void)? = nil,
        onStepMemoryChannel: ((Bool) -> Void)? = nil
    ) {
        self.label = label
        self.frequencyHz = frequencyHz
        self.isActive = isActive
        self.mode = mode
        self.txRxLabel = txRxLabel
        self.callsign = callsign
        self.reflector = reflector
        self.aprsActive = aprsActive
        self.onSetFrequency = onSetFrequency
        self.vfoMemoryMode = vfoMemoryMode
        self.memoryChannel = memoryChannel
        self.memoryChannelTag = memoryChannelTag
        self.onSetMemoryChannel = onSetMemoryChannel
        self.onStepMemoryChannel = onStepMemoryChannel
    }

    /// Whether tapping should open the memory-channel popover instead of
    /// the plain frequency-entry one.
    private var isMemoryMode: Bool {
        vfoMemoryMode == .memory && onSetMemoryChannel != nil && onStepMemoryChannel != nil
    }

    /// The memory-channel tag's text ("CH 11 K7RPT") while in Memory mode,
    /// shown in its own box after the TXRX/RX indicator; nil otherwise.
    private var channelText: String? {
        guard vfoMemoryMode == .memory, let memoryChannel else { return nil }
        let tagSuffix = memoryChannelTag.map { " \($0)" } ?? ""
        return "CH \(memoryChannel)\(tagSuffix)"
    }

    public var body: some View {
        // Two flow-laid-out columns rather than absolutely-positioned
        // overlays: MAIN/SUB + TXRX/RX and the decoded reflector/APRS/
        // callsign info stack on the left, mode info and the frequency
        // readout stack on the right. Using real layout (not fixed overlay
        // offsets) means the box grows to fit whichever column is taller,
        // so the two never overlap regardless of how many lines either one
        // shows.
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .tagBoxed()
                    if let txRxLabel {
                        Text(txRxLabel)
                            .font(.caption2)
                            .foregroundStyle(txRxFillColor == nil ? Color.secondary : Color.white)
                            .tagBoxed(fill: txRxFillColor)
                    }
                    if let channelText {
                        Text(channelText)
                            .font(.caption2)
                            .foregroundStyle(digitColor)
                            .lineLimit(1)
                            .tagBoxed()
                    }
                }
                // Tags keep their natural size: without this, a wide callsign
                // or the priority frequency squeezes them into wrapped/
                // truncated text.
                .fixedSize(horizontal: true, vertical: false)
                // Reflector/APRS indicator and the decoded callsign are
                // grouped together — all three describe the same
                // decoded-digital-traffic state for this VFO.
                if reflector != nil || aprsActive || callsign != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        if let reflector {
                            Text(reflector)
                                .font(.caption2)
                                .foregroundStyle(digitColor)
                                .lineLimit(1)
                        }
                        if aprsActive {
                            Text("APRS")
                                .font(.caption2)
                                .foregroundStyle(digitColor)
                        }
                        if let callsign {
                            Text(callsign)
                                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                                .foregroundStyle(digitColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(mode)
                    .font(.caption2)
                    .foregroundStyle(digitColor)
                    .tagBoxed()
                Text(formattedFrequency)
                    .font(.system(size: 52, weight: .medium, design: .monospaced))
                    .foregroundStyle(digitColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard onSetFrequency != nil || isMemoryMode else { return }
                        isEditing = true
                    }
                    .popover(isPresented: $isEditing) {
                        if isMemoryMode, let onSetMemoryChannel, let onStepMemoryChannel {
                            MemoryChannelEntryView(
                                currentChannel: memoryChannel,
                                onSetChannel: onSetMemoryChannel,
                                onStep: onStepMemoryChannel
                            )
                        } else if let onSetFrequency {
                            FrequencyEntryView(currentHz: frequencyHz ?? 0, onSetFrequency: onSetFrequency)
                        }
                    }
            }
            // Frequency claims its width first: without this, a callsign/
            // reflector appearing in the left column shrinks the readout
            // (via minimumScaleFactor) until it expires.
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.green.opacity(0.7) : Color.gray.opacity(0.4), lineWidth: 1.5)
        )
    }

    /// Fill color for the TXRX/RX box, matching the rig's own display:
    /// red while transmitting is possible on this VFO, green while
    /// receive-only (split RX). `nil` for any other/future value of
    /// `txRxLabel`, which keeps the plain bordered style.
    private var txRxFillColor: Color? {
        switch txRxLabel {
        case "TXRX", "TX": return .red
        case "RX": return .green
        default: return nil
        }
    }

    private var digitColor: Color {
        isActive ? .green : .green.opacity(0.45)
    }

    /// Grouped like the rig's own display (e.g. "147.380.000") rather than
    /// a plain Hz count, so it reads the way a radio operator expects.
    private var formattedFrequency: String {
        guard let frequencyHz else { return "-- . --- . ---" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: frequencyHz)) ?? "\(frequencyHz)"
    }
}

private extension View {
    /// Small boxed tag around a label (MAIN/SUB, TXRX/RX, mode) so it reads
    /// as a distinct element rather than blending into the surrounding
    /// text. With `fill` set (TXRX/RX, matching the rig's own red/green),
    /// the box is a solid color instead of just bordered.
    func tagBoxed(fill: Color? = nil) -> some View {
        padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(fill ?? .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(fill == nil ? Color.secondary.opacity(0.5) : Color.clear, lineWidth: 1)
            )
    }
}

#Preview {
    HStack(spacing: 12) {
        VFODisplayBox(label: "VFO A", frequencyHz: 147_380_000, isActive: true, mode: "FM", onSetFrequency: { _ in })
        VFODisplayBox(label: "VFO B", frequencyHz: 431_075_000, isActive: false, mode: "FM")
    }
    .padding()
    .frame(width: 420)
}

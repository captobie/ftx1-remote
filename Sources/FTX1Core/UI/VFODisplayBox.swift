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
    /// VFO-vs-memory mode (see `RigState.vfoMemoryMode`/
    /// `subVfoMemoryMode`). `nil` (the default) behaves exactly as before
    /// this existed — plain VFO display/tap-to-set-frequency.
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
    /// The rig's memory scan — see `RigState.memoryScan`. While scanning,
    /// the channel, frequency and mode are hidden (they're a stale sample:
    /// the rig steps faster than the app polls) and the indicator line
    /// reads SCAN; paused shows the channel it stopped on. `nil` (the
    /// default) shows nothing extra.
    let memoryScan: MemoryScanState?
    /// This VFO's mode, for the frequency popover's mode buttons
    /// (`ModeButtonGrid`), shown only together with `onSetMode`. `mode`
    /// above is just the label.
    let currentMode: RigMode?
    /// Mode-button callback. `nil` (the default, the Mac) leaves the
    /// frequency popover without mode buttons.
    let onSetMode: ((RigMode) -> Void)?
    /// Programmed channels for the memory popover's list
    /// (`MemoryChannelListView`, which selects through
    /// `onSetMemoryChannel`). `nil` (the default) with no
    /// `onRefreshMemoryList` either leaves the popover without a list.
    let memoryList: MemoryListSnapshot?
    /// Re-reads `memoryList` from the rig.
    let onRefreshMemoryList: (() -> Void)?
    /// The band this VFO is on (`RigState.band`), for the frequency
    /// popover's `BandPicker`, shown only together with `onSetBand` — VFO
    /// mode only, like the rest of that popover.
    let currentBand: String?
    /// Band-picker callback (`RigCommand.setBand`). `nil` (the default)
    /// leaves the popover without one.
    let onSetBand: ((String) -> Void)?

    @State private var isEditing = false
    /// Settings → Appearance's theme (`VFOTheme`); nil outside
    /// `.appTheme()`, e.g. on the iPad — the boxes as they always looked.
    @Environment(\.appTheme) private var appTheme

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
        onStepMemoryChannel: ((Bool) -> Void)? = nil,
        memoryScan: MemoryScanState? = nil,
        currentMode: RigMode? = nil,
        onSetMode: ((RigMode) -> Void)? = nil,
        memoryList: MemoryListSnapshot? = nil,
        onRefreshMemoryList: (() -> Void)? = nil,
        currentBand: String? = nil,
        onSetBand: ((String) -> Void)? = nil
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
        self.memoryScan = memoryScan
        self.currentMode = currentMode
        self.onSetMode = onSetMode
        self.memoryList = memoryList
        self.onRefreshMemoryList = onRefreshMemoryList
        self.currentBand = currentBand
        self.onSetBand = onSetBand
    }

    /// Whether the memory popover shows the channel list.
    private var showsMemoryList: Bool {
        memoryList != nil || onRefreshMemoryList != nil
    }

    private var isScanning: Bool { memoryScan == .scanning }

    private var scanIndicator: String? {
        switch memoryScan {
        case .scanning: return "SCAN"
        case .paused: return "SCAN PAUSED"
        case .stopped, nil: return nil
        }
    }

    /// Whether tapping should open the memory-channel popover instead of
    /// the plain frequency-entry one.
    private var isMemoryMode: Bool {
        vfoMemoryMode == .memory && onSetMemoryChannel != nil && onStepMemoryChannel != nil
    }

    /// Whether this VFO is in anything other than plain VFO mode (Memory,
    /// or one of the rig's other channel modes — see `VFOMemoryMode.other`).
    /// The frequency-entry popover is never offered then: the rig rejects
    /// a frequency write outside VFO mode, and the tap belongs to the
    /// memory-channel popover (or does nothing when there isn't one).
    private var isOutsideVFOMode: Bool {
        guard let vfoMemoryMode else { return false }
        return vfoMemoryMode != .vfo
    }

    private var canEdit: Bool {
        isMemoryMode || (onSetFrequency != nil && !isOutsideVFOMode)
    }

    /// The memory-channel tag's text ("CH 11 K7RPT") while in Memory mode,
    /// shown in its own box after the TXRX/RX indicator; nil otherwise.
    private var channelText: String? {
        if isScanning { return "SCANNING" }
        guard vfoMemoryMode == .memory, let memoryChannel else { return nil }
        let tagSuffix = memoryChannelTag.map { " \($0)" } ?? ""
        return "CH \(memoryChannel)\(tagSuffix)"
    }

    public var body: some View {
        // Fixed three-row structure so nothing here can resize the box or
        // the frequency: tags (MAIN/TXRX/channel) and mode on top, the
        // reflector/APRS indicator under them (height reserved), then the
        // decoded callsign on the left and the frequency on the right. The
        // frequency and callsign are fixed-size (never scale).
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(labelStyle)
                    .tagBoxed(border: tagBorderColor)
                    .fixedSize()
                if let txRxLabel {
                    Text(txRxLabel)
                        .font(.caption2)
                        .foregroundStyle(txRxFillColor == nil ? Color.secondary : Color.white)
                        .tagBoxed(fill: txRxFillColor)
                        .fixedSize()
                }
                if let channelText {
                    Text(channelText)
                        .font(.caption2)
                        .foregroundStyle(themed(vfo.memoryChannel))
                        .lineLimit(1)
                        .tagBoxed(border: tagBorderColor)
                }
                Spacer(minLength: 8)
                Text(isScanning ? "—" : mode)
                    .font(.caption2)
                    .foregroundStyle(themed(vfo.mode))
                    .tagBoxed(border: tagBorderColor)
                    .fixedSize()
            }
            // Reflector/APRS indicator sits directly under MAIN/SUB. Its
            // height is reserved even when empty so neither it nor anything
            // below it moves as indicators or callsigns come and go — one
            // hidden caption2 line, not a fixed height: caption2 is ~13pt on
            // iPad vs 10pt on the Mac, and a 14pt minimum let the iPad box
            // grow when a reflector appeared.
            ZStack(alignment: .leading) {
                Text(" ")
                    .font(.caption2)
                    .hidden()
                HStack(spacing: 6) {
                    if let reflector, !isScanning {
                        Text(reflector)
                            .font(.caption2)
                            .foregroundStyle(themed(vfo.secondary))
                            .lineLimit(1)
                    }
                    if aprsActive {
                        Text("APRS")
                            .font(.caption2)
                            .foregroundStyle(themed(vfo.secondary))
                    }
                    if let scanIndicator {
                        Text(scanIndicator)
                            .font(.caption2)
                            .foregroundStyle(themed(vfo.secondary))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 8) {
                if let callsign, !isScanning {
                    Text(callsign)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(themed(vfo.callsign))
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                frequencyText
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard canEdit else { return }
                        isEditing = true
                    }
                    .popover(isPresented: $isEditing) {
                        if isMemoryMode, let onSetMemoryChannel, let onStepMemoryChannel {
                            if showsMemoryList {
                                VStack(spacing: 0) {
                                    MemoryChannelEntryView(
                                        currentChannel: memoryChannel,
                                        onSetChannel: onSetMemoryChannel,
                                        onStep: onStepMemoryChannel
                                    )
                                    MemoryChannelListView(
                                        list: memoryList,
                                        currentChannel: memoryChannel,
                                        onSelect: onSetMemoryChannel,
                                        onRefresh: onRefreshMemoryList
                                    )
                                    .padding([.horizontal, .bottom])
                                }
                                .frame(width: 420)
                            } else {
                                MemoryChannelEntryView(
                                    currentChannel: memoryChannel,
                                    onSetChannel: onSetMemoryChannel,
                                    onStep: onStepMemoryChannel
                                )
                            }
                        } else if !isOutsideVFOMode, let onSetFrequency {
                            if onSetMode != nil || onSetBand != nil {
                                VStack(spacing: 0) {
                                    FrequencyEntryView(currentHz: frequencyHz ?? 0, onSetFrequency: onSetFrequency)
                                    if let onSetBand {
                                        HStack {
                                            Text("common.band", bundle: .module)
                                            Spacer()
                                            BandPicker(currentBand: currentBand, onSetBand: onSetBand)
                                                .pickerStyle(.menu)
                                        }
                                        .padding([.horizontal, .bottom])
                                    }
                                    if let onSetMode {
                                        ModeButtonGrid(currentMode: currentMode, onSetMode: onSetMode)
                                            .padding([.horizontal, .bottom])
                                    }
                                }
                                .frame(width: 340)
                            } else {
                                FrequencyEntryView(currentHz: frequencyHz ?? 0, onSetFrequency: onSetFrequency)
                            }
                        }
                    }
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(vfo.background?.style ?? AnyShapeStyle(Color.black)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderStyle, lineWidth: 1.5)
        )
    }

    private var vfo: VFOTheme { appTheme?.theme.vfo ?? VFOTheme() }

    private var borderStyle: AnyShapeStyle {
        if isActive {
            return vfo.border?.style ?? AnyShapeStyle(Color.green.opacity(0.7))
        }
        return vfo.borderInactive?.style ?? AnyShapeStyle(Color.gray.opacity(0.4))
    }

    /// A themed colour for this box's text, dimmed like the digits while
    /// the receiver isn't shown; unset = `digitColor`, the original look.
    private func themed(_ hex: String?) -> Color {
        guard let color = themeColor(hex) else { return digitColor }
        return isActive ? color : color.opacity(0.45)
    }

    private var labelStyle: AnyShapeStyle {
        if let color = themeColor(vfo.label) {
            return AnyShapeStyle(isActive ? color : color.opacity(0.45))
        }
        return isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var tagBorderColor: Color {
        themeColor(vfo.modeBorder) ?? Color.secondary.opacity(0.5)
    }

    private var digitFont: VFODigitFont {
        appTheme?.vfoDigitFont ?? vfo.digitFont ?? .systemMono
    }

    /// The frequency in the theme's font; the 7-segment font draws the lit
    /// digits over faint unlit "8"s (`SevenSegmentText`), an LCD look.
    @ViewBuilder
    private var frequencyText: some View {
        let font = VFODigitFonts.font(digitFont, size: 36, bold: vfo.digitsBold ?? false)
        if digitFont == .sevenSegment, VFODigitFonts.hasSevenSegment {
            let lit = SevenSegmentText.lit(hasFrequency ? formattedFrequency : "")
            ZStack(alignment: .trailing) {
                Text(SevenSegmentText.unlit(lit))
                    .foregroundStyle(unlitSegmentColor)
                Text(lit)
                    .foregroundStyle(digitColor)
            }
            .font(font)
            .lineLimit(1)
            .fixedSize()
        } else {
            Text(formattedFrequency)
                .font(font)
                .foregroundStyle(digitColor)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// The unlit segments: the theme's, at the theme's faintness but in the
    /// overridden digit colour if Settings picked one; ~10% of the digit
    /// colour when the theme has none.
    private var unlitSegmentColor: Color {
        let alpha = ThemeColor(hex: vfo.unlitSegments).map { Double($0.a) / 255 } ?? 0.1
        if appTheme?.vfoDigitColor == nil, let color = themeColor(vfo.unlitSegments) {
            return color
        }
        return baseDigitColor.opacity(alpha)
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

    /// Settings → Appearance's VFO digit colour, else the theme's, else
    /// the original green.
    private var baseDigitColor: Color {
        appTheme?.vfoDigitColor?.color ?? themeColor(vfo.digits) ?? .green
    }

    private var digitColor: Color {
        isActive ? baseDigitColor : baseDigitColor.opacity(0.45)
    }

    private var hasFrequency: Bool {
        !isScanning && (frequencyHz ?? 0) > 0
    }

    /// Grouped like the rig's own display (e.g. "147.380.000") rather than
    /// a plain Hz count, so it reads the way a radio operator expects.
    private var formattedFrequency: String {
        guard !isScanning, let frequencyHz, frequencyHz > 0 else { return "-- . --- . ---" }
        return FrequencyFormat.dotted(frequencyHz)
    }
}

private extension View {
    /// Small boxed tag around a label (MAIN/SUB, TXRX/RX, mode) so it reads
    /// as a distinct element rather than blending into the surrounding
    /// text. With `fill` set (TXRX/RX, matching the rig's own red/green),
    /// the box is a solid color instead of just bordered.
    func tagBoxed(fill: Color? = nil, border: Color = Color.secondary.opacity(0.5)) -> some View {
        padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(fill ?? .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(fill == nil ? border : Color.clear, lineWidth: 1)
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

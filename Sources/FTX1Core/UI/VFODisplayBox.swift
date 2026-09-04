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
    /// Callsign of the station currently being received in C4FM, if known —
    /// see `RigState.c4fmCallsign`. `nil` (the default) shows nothing extra;
    /// callers are expected to only pass a value while this VFO is actually
    /// in C4FM mode.
    let callsign: String?
    /// Name of the YSF reflector the WPSD hotspot is currently linked to, if
    /// known — see `RigState.c4fmReflector`. `nil` (the default) shows
    /// nothing extra; same "only while this VFO is in C4FM mode" contract
    /// as `callsign`.
    let reflector: String?
    /// Tap-to-edit callback for this VFO's frequency. `nil` (the default)
    /// leaves the display read-only — used for VFO B, which has no
    /// corresponding `RigCommand` to write back through today.
    let onSetFrequency: ((Int) -> Void)?

    @State private var isEditing = false

    public init(label: String, frequencyHz: Int?, isActive: Bool, mode: String, callsign: String? = nil, reflector: String? = nil, onSetFrequency: ((Int) -> Void)? = nil) {
        self.label = label
        self.frequencyHz = frequencyHz
        self.isActive = isActive
        self.mode = mode
        self.callsign = callsign
        self.reflector = reflector
        self.onSetFrequency = onSetFrequency
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(isActive ? .primary : .secondary)
            Text(formattedFrequency)
                .font(.system(size: 38, weight: .medium, design: .monospaced))
                .foregroundStyle(digitColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard onSetFrequency != nil else { return }
                    isEditing = true
                }
                .popover(isPresented: $isEditing) {
                    if let onSetFrequency {
                        FrequencyEntryView(currentHz: frequencyHz ?? 0, onSetFrequency: onSetFrequency)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.green.opacity(0.7) : Color.gray.opacity(0.4), lineWidth: 1.5)
        )
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode)
                    .font(.caption2)
                    .foregroundStyle(digitColor)
                if let reflector {
                    Text(reflector)
                        .font(.caption2)
                        .foregroundStyle(digitColor)
                }
            }
            .padding(.leading, 10)
            .padding(.top, 6)
        }
        .overlay(alignment: .bottomLeading) {
            if let callsign {
                Text(callsign)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundStyle(digitColor)
                    .padding(.leading, 10)
                    .padding(.bottom, 6)
            }
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

#Preview {
    HStack(spacing: 12) {
        VFODisplayBox(label: "VFO A", frequencyHz: 147_380_000, isActive: true, mode: "FM", onSetFrequency: { _ in })
        VFODisplayBox(label: "VFO B", frequencyHz: 431_075_000, isActive: false, mode: "FM")
    }
    .padding()
    .frame(width: 420)
}

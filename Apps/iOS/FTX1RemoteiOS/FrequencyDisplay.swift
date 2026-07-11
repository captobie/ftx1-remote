import SwiftUI

/// Large digital-readout frequency display for iOS's focused single-rig
/// view — same dark/green LCD styling as the Mac's `VFODisplayBox`, but
/// bigger and standalone (no side-by-side VFO A/B pairing; see repo root
/// CLAUDE.md on why the iPhone view stays focused rather than dense).
struct FrequencyDisplay: View {
    let frequencyHz: Int
    let mode: String

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(formattedFrequency)
                .font(.system(size: 44, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.green)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.green.opacity(0.7), lineWidth: 1.5)
        )
        .overlay(alignment: .topLeading) {
            Text(mode)
                .font(.caption)
                .foregroundStyle(Color.green)
                .padding(.leading, 14)
                .padding(.top, 10)
        }
    }

    /// Grouped like the rig's own display (e.g. "147.380.000") rather than
    /// a plain Hz count, so it reads the way a radio operator expects.
    private var formattedFrequency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: frequencyHz)) ?? "\(frequencyHz)"
    }
}

#Preview {
    FrequencyDisplay(frequencyHz: 147_380_000, mode: "FM")
        .padding()
}

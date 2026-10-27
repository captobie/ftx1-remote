import FTX1Core
import SwiftUI

/// One receiver's meter + audio controls in a single compact strip, laid
/// out under its `VFODisplayBox`: a segmented bar S-meter with a numeric
/// readout and a mute button on the top row, SQL and VOL sliders side by
/// side below. Used by both the hub screen (`HubControlView`, fed by
/// `RigClientViewModel`) and the Pi-direct screen (`PiDirectView`, fed by
/// `PiDirectViewModel`), which persist volume/squelch under the same
/// `AudioPlaybackSettings` keys.
///
/// Replaced (2026-10-09, user request) the Mac-style analog `SMeterView`
/// plus two tall label-over-slider columns, which together took ~2.5× the
/// height. The analog face stays on the Mac; on the iPad a bar reads at a
/// glance and fits beside the sliders.
///
/// The meter row itself is the shared `BarSMeterView` (`FTX1Core/UI/`,
/// also on the iPhone), incl. MAIN's TX meter while transmitting.
///
/// Volume/squelch are written straight to `engine` on every change (not
/// routed back through a view model) since `AudioPlaybackEngine` is a
/// reference type the view model already owns.
struct ChannelStrip: View {
    let label: String
    let smeterDb: Double?
    /// TX readings for MAIN's strip; nil for SUB (always shows S).
    let txReadings: MeterReadings?
    let ptt: Bool
    @Binding var volume: Double
    @Binding var squelchThreshold: Double
    let isMuted: Bool
    let engine: AudioPlaybackEngine
    let onToggleMute: () -> Void

    /// Upper bound of the squelch slider's *displayed* range — see the
    /// Mac's identical constant/doc comment in its own `ContentView`.
    private static let squelchDisplayRange: Double = 0.05

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                BarSMeterView(label: label, smeterDb: smeterDb, txReadings: txReadings, ptt: ptt)
                muteButton
            }
            HStack(spacing: 14) {
                sliderRow("SQL", value: squelchDisplayBinding, range: 0...Self.squelchDisplayRange)
                sliderRow("VOL", value: $volume, range: 0...1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        .onChange(of: volume, initial: true) { _, newValue in
            engine.volume = Float(newValue)
        }
        .onChange(of: squelchThreshold, initial: true) { _, newValue in
            engine.squelchThreshold = Float(newValue)
        }
    }

    // MARK: - Audio

    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.body)
                .frame(width: 40, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(isMuted ? Color.red : Color.gray.opacity(0.2)))
                .foregroundStyle(isMuted ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "common.unmute \(label)" : "common.mute \(label)")
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(title == "SQL" ? "channelStrip.squelchOf \(label)" : "channelStrip.volumeOf \(label)")
        }
    }

    /// `SquelchGate.threshold` is "how close to true silence counts as
    /// quieting" — smaller is stricter (see its doc comment). Inverted here
    /// so dragging right still tightens the squelch, matching a normal
    /// radio's knob and the Mac's own slider — see its `squelchBinding`
    /// doc comment.
    private var squelchDisplayBinding: Binding<Double> {
        Binding(
            get: { Self.squelchDisplayRange - squelchThreshold },
            set: { squelchThreshold = Self.squelchDisplayRange - $0 }
        )
    }
}

#Preview {
    VStack {
        ChannelStrip(label: "MAIN", smeterDb: 12, txReadings: MeterReadings(powerWatts: 8, swr: 1.3, tx: nil), ptt: false, volume: .constant(0.8), squelchThreshold: .constant(0.015), isMuted: false, engine: AudioPlaybackEngine(), onToggleMute: {})
        ChannelStrip(label: "MAIN", smeterDb: nil, txReadings: MeterReadings(powerWatts: 8, swr: 1.3, tx: nil), ptt: true, volume: .constant(0.8), squelchThreshold: .constant(0.015), isMuted: false, engine: AudioPlaybackEngine(), onToggleMute: {})
        ChannelStrip(label: "SUB", smeterDb: -30, txReadings: nil, ptt: false, volume: .constant(0.5), squelchThreshold: .constant(0.03), isMuted: true, engine: AudioPlaybackEngine(), onToggleMute: {})
    }
    .frame(width: 500)
    .padding()
}

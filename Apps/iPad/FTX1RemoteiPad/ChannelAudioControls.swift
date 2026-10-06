import FTX1Core
import SwiftUI

/// One channel's audio column: mute + volume + "virtual" squelch (a
/// client-side noise gate — see `AudioPlaybackEngine`/`SquelchGate` —
/// independent of the rig's own hardware squelch). Used by both the hub
/// screen (`HubControlView.audioControls`, fed by `RigClientViewModel`)
/// and the Pi-direct screen (`PiDirectView`, fed by `PiDirectViewModel`),
/// which persist volume/squelch under the same `AudioPlaybackSettings`
/// keys.
///
/// `engine` is written to directly on every slider change (not routed
/// back through a view model) since `AudioPlaybackEngine` is a reference
/// type the view model already owns.
struct ChannelAudioControls: View {
    let label: String
    @Binding var volume: Double
    @Binding var squelchThreshold: Double
    let isMuted: Bool
    let engine: AudioPlaybackEngine
    let onToggleMute: () -> Void

    /// Upper bound of the squelch slider's *displayed* range — see the
    /// Mac's identical constant/doc comment in its own `ContentView`.
    private static let squelchDisplayRange: Double = 0.05

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onToggleMute) {
                    Text(isMuted ? "Muted" : "Mute")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isMuted ? Color.red : Color.gray.opacity(0.2))
                        .foregroundStyle(isMuted ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            Text("Volume")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: $volume, in: 0...1)
                .onChange(of: volume, initial: true) { _, newValue in
                    engine.volume = Float(newValue)
                }
            Text("Squelch")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // `SquelchGate.threshold` is "how close to true silence counts
            // as quieting" — smaller is stricter (see its doc comment).
            // Inverted here so dragging right still tightens the squelch,
            // matching a normal radio's knob and the Mac's own slider —
            // see its `squelchBinding` doc comment.
            Slider(
                value: Binding(
                    get: { Self.squelchDisplayRange - squelchThreshold },
                    set: { squelchThreshold = Self.squelchDisplayRange - $0 }
                ),
                in: 0...Self.squelchDisplayRange
            )
            .onChange(of: squelchThreshold, initial: true) { _, newValue in
                engine.squelchThreshold = Float(newValue)
            }
        }
    }
}

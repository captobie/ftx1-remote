import AVFoundation
import Combine
import SwiftUI

/// Plays back one `AudioRecorder.Recording` at a time via `AVAudioPlayer` —
/// a plain file player, unrelated to `AudioPlaybackEngine` (which decodes
/// the live network wire format for the Mac→iPad relay, not a WAV file on
/// disk).
@MainActor
private final class RecordingPlayer: NSObject, ObservableObject {
    @Published private(set) var playingURL: URL?
    private var player: AVAudioPlayer?

    func play(_ recording: AudioRecorder.Recording) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: recording.url) else { return }
        player.delegate = self
        self.player = player
        player.play()
        playingURL = recording.url
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }
}

extension RecordingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.playingURL = nil
            self?.player = nil
        }
    }
}

/// The CW page's PLAY button (`MenuPageView`) opens this in its own window
/// (`recordings`, declared in `FTX1RemoteMacApp`) — a browser for whatever
/// the RECORD button has written via `AudioRecorder`. A plain file browser,
/// not tied to `HubService`/`RigController` at all: recording playback has
/// nothing to do with the rig link, unlike the APRS/FT8 windows.
struct RecordingsListView: View {
    @State private var recordings: [AudioRecorder.Recording] = []
    @StateObject private var player = RecordingPlayer()

    var body: some View {
        List {
            ForEach(recordings) { recording in
                row(for: recording)
            }
        }
        .navigationTitle("Recordings")
        .frame(minWidth: 360, minHeight: 320)
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { reload() }
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView(
                    "No Recordings Yet",
                    systemImage: "waveform",
                    description: Text("Recordings made from the CW page's RECORD button will appear here.")
                )
            }
        }
        .onAppear { reload() }
        .onDisappear { player.stop() }
    }

    private func row(for recording: AudioRecorder.Recording) -> some View {
        let isPlaying = player.playingURL == recording.url
        return HStack {
            Button {
                isPlaying ? player.stop() : player.play(recording)
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading) {
                Text(recording.date, format: .dateTime)
                Text(Self.durationLabel(recording.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                if isPlaying { player.stop() }
                AudioRecorder.delete(recording)
                reload()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func reload() {
        recordings = AudioRecorder.listRecordings()
    }

    private static func durationLabel(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

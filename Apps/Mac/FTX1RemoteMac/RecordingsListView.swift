import AppKit
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
    /// Non-nil while the rename alert is up — the recording it targets.
    /// `newName` is seeded from its current filename (minus extension)
    /// when the pencil button sets this.
    @State private var renamingRecording: AudioRecorder.Recording?
    @State private var newName = ""
    @State private var showingDeleteAllConfirmation = false
    /// URLs of the currently checked rows, toggled by each row's leading
    /// circle button — tracked by URL rather than holding onto `Recording`
    /// values directly, so a rename (which produces a new `Recording` with
    /// a new URL on reload) doesn't silently drop that row out of the set;
    /// `reload()` intersects this against what's still on disk.
    @State private var selection: Set<URL> = []
    @State private var showingDeleteSelectedConfirmation = false
    @State private var exportResultMessage: String?

    private var selectedRecordings: [AudioRecorder.Recording] {
        recordings.filter { selection.contains($0.url) }
    }

    var body: some View {
        List {
            ForEach(recordings) { recording in
                row(for: recording)
            }
        }
        .navigationTitle("recordingsList.recordings")
        .frame(minWidth: 560, minHeight: 320)
        .toolbar {
            // Only shown once something's actually selected, rather than
            // always-present-but-disabled — at rest there's exactly one
            // trash icon (Delete All) in the toolbar, not two
            // near-identical ones sitting side by side.
            if !selection.isEmpty {
                ToolbarItem {
                    Button("recordingsList.exportSelected \(selection.count)", systemImage: "square.and.arrow.up") {
                        exportSelected()
                    }
                    .labelStyle(.titleAndIcon)
                }
                ToolbarItem {
                    Button("recordingsList.deleteSelectedX \(selection.count)", systemImage: "minus.circle", role: .destructive) {
                        showingDeleteSelectedConfirmation = true
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            ToolbarItem {
                Button("recordingsList.deleteAll", systemImage: "trash", role: .destructive) {
                    showingDeleteAllConfirmation = true
                }
                .disabled(recordings.isEmpty)
                .labelStyle(.titleAndIcon)
            }
            ToolbarItem {
                Button("common.refresh", systemImage: "arrow.clockwise") { reload() }
                    .labelStyle(.titleAndIcon)
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView(
                    "recordingsList.noRecordingsYet",
                    systemImage: "waveform",
                    description: Text("recordingsList.recordingsMadeFromThe")
                )
            }
        }
        .confirmationDialog(
            "recordingsList.deleteAllRecordingsThis \(recordings.count)",
            isPresented: $showingDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("recordingsList.deleteAll", role: .destructive) {
                player.stop()
                AudioRecorder.deleteAll()
                selection.removeAll()
                reload()
            }
        }
        .confirmationDialog(
            "recordingsList.deleteSelectedConfirm \(selection.count)",
            isPresented: $showingDeleteSelectedConfirmation,
            titleVisibility: .visible
        ) {
            Button("recordingsList.deleteSelected", role: .destructive) {
                deleteSelected()
            }
        }
        .alert(
            "recordingsList.renameRecording",
            isPresented: Binding(
                get: { renamingRecording != nil },
                set: { isPresented in if !isPresented { renamingRecording = nil } }
            ),
            presenting: renamingRecording
        ) { recording in
            TextField("common.name", text: $newName)
            Button("common.cancel", role: .cancel) {}
            Button("common.rename") {
                if AudioRecorder.rename(recording, to: newName) != nil {
                    reload()
                }
            }
        }
        .alert(
            "recordingsList.exportComplete",
            isPresented: Binding(
                get: { exportResultMessage != nil },
                set: { isPresented in if !isPresented { exportResultMessage = nil } }
            ),
            presenting: exportResultMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .onAppear { reload() }
        .onDisappear { player.stop() }
    }

    private func row(for recording: AudioRecorder.Recording) -> some View {
        let isPlaying = player.playingURL == recording.url
        let isSelected = selection.contains(recording.url)
        return HStack {
            Button {
                if isSelected {
                    selection.remove(recording.url)
                } else {
                    selection.insert(recording.url)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)

            Button {
                isPlaying ? player.stop() : player.play(recording)
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading) {
                Text(recording.url.deletingPathExtension().lastPathComponent)
                Text("\(recording.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.durationLabel(recording.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if isPlaying { player.stop() }
                newName = recording.url.deletingPathExtension().lastPathComponent
                renamingRecording = recording
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                if isPlaying { player.stop() }
                AudioRecorder.delete(recording)
                selection.remove(recording.url)
                reload()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func deleteSelected() {
        if let playingURL = player.playingURL, selection.contains(playingURL) {
            player.stop()
        }
        for recording in selectedRecordings {
            AudioRecorder.delete(recording)
        }
        selection.removeAll()
        reload()
    }

    /// Opens a directory-choosing `NSOpenPanel`, same pattern as
    /// `SettingsView.chooseBinaryPath()`'s file panel, and copies the
    /// selected recordings there via `AudioRecorder.export(_:to:)`.
    private func exportSelected() {
        let toExport = selectedRecordings
        guard !toExport.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "recordingsList.exportPrompt")
        panel.message = String(localized: "recordingsList.chooseExportFolder \(toExport.count)")

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let succeeded = AudioRecorder.export(toExport, to: destination)
        exportResultMessage = String(localized: "recordingsList.exportedOf \(succeeded) \(toExport.count) \(destination.lastPathComponent)")
    }

    /// Reloads from disk and drops any selected URL that no longer exists
    /// (deleted, or renamed to a different URL) — a plain `selection =
    /// AudioRecorder.listRecordings()`-independent reassignment would
    /// otherwise leave stale URLs selected forever, since nothing else
    /// prunes this set.
    private func reload() {
        let updated = AudioRecorder.listRecordings()
        recordings = updated
        selection.formIntersection(Set(updated.map(\.url)))
    }

    private static func durationLabel(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

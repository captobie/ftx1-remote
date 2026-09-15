import AVFoundation
import Foundation
import os

/// Records the raw samples `AudioCaptureEngine` hands to `HubService`'s
/// audio tap — the same audio behind the waterfall/oscilloscope, Mac-local
/// playback, and the iPad relay, whichever of `.local`/`.remote` is
/// currently supplying it — straight to a WAV file on disk. Backs the CW
/// page's RECORD button (`MenuPageView`); `RecordingsListView` (opened by
/// the PLAY button) browses what this writes via `listRecordings()`.
///
/// Mirrors `APRSDecoder`'s shape: a private serial queue does the actual
/// file I/O so it never blocks the main-actor hop `AudioCaptureEngine.
/// onAudioSamples` calls into, and `toggle()`/`ingest(samples:sampleRate:)`
/// are the only two entry points `HubService` needs.
final class AudioRecorder {
    struct Recording: Identifiable, Hashable {
        let url: URL
        let date: Date
        let duration: TimeInterval
        var id: URL { url }
    }

    /// Always invoked on the main actor — same contract as
    /// `RigctldProcessController.onStateChange` — `HubService` assigns
    /// straight into its own `@Published` state from inside it.
    var onRecordingStateChanged: ((Bool) -> Void)?

    private(set) var isRecording = false
    private let queue = DispatchQueue(label: "com.ftx1remote.audio-recorder")
    private var audioFile: AVAudioFile?

    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "audio-recorder")

    static let recordingsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FTX1Remote", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Called from the RECORD button's tap — starts a new file, or closes
    /// out the one currently being written. The file itself is created
    /// lazily on the next `ingest(samples:sampleRate:)` call rather than
    /// here, since only the audio tap knows the actual sample rate.
    func toggle() {
        isRecording.toggle()
        if !isRecording {
            queue.async { [weak self] in self?.audioFile = nil }
        }
        onRecordingStateChanged?(isRecording)
    }

    /// Called unconditionally from `HubService`'s audio tap, same as
    /// `FT8DecodeCoordinator.ingest` — a cheap no-op whenever not
    /// recording. The actual file write happens on `queue`, off the main
    /// actor.
    func ingest(samples: [Float], sampleRate: Double) {
        guard isRecording else { return }
        queue.async { [weak self] in
            self?.writeOnQueue(samples: samples, sampleRate: sampleRate)
        }
    }

    private func writeOnQueue(samples: [Float], sampleRate: Double) {
        if audioFile == nil {
            audioFile = Self.makeFile(sampleRate: sampleRate)
        }
        guard let audioFile,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        do {
            try audioFile.write(from: buffer)
        } catch {
            Self.logger.error("write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func makeFile(sampleRate: Double) -> AVAudioFile? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = recordingsDirectory.appendingPathComponent("Recording \(formatter.string(from: Date())).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return nil }
        do {
            return try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            Self.logger.error("failed to create recording file: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Reads `recordingsDirectory` fresh each call — recordings are only
    /// ever browsed from `RecordingsListView`, which reloads on appear, so
    /// there's no separate in-memory index to keep in sync with disk.
    static func listRecordings() -> [Recording] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "wav" }
            .map { url -> Recording in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                // A throwaway AVAudioPlayer is the cheapest way to read a
                // file's duration without separately opening it for
                // reading via AVAudioFile.
                let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
                return Recording(url: url, date: date, duration: duration)
            }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
    }

    /// Used by `RecordingsListView`'s "Delete All" toolbar button — clears
    /// `recordingsDirectory` entirely rather than looping `delete(_:)` over
    /// a previously-fetched `[Recording]`, so it can't miss a file written
    /// after that list was last loaded.
    static func deleteAll() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension.lowercased() == "wav" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Renames a recording's file on disk to `newName` (any existing
    /// ".wav" the caller typed is stripped first so it isn't doubled) and
    /// returns the updated `Recording`, or `nil` if `newName` is blank or
    /// the move fails (e.g. another recording already has that name).
    static func rename(_ recording: Recording, to newName: String) -> Recording? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var sanitized = trimmed.replacingOccurrences(of: "/", with: "-")
        if sanitized.lowercased().hasSuffix(".wav") {
            sanitized = String(sanitized.dropLast(4))
        }
        let newURL = recordingsDirectory.appendingPathComponent(sanitized).appendingPathExtension("wav")
        guard newURL.path != recording.url.path else { return recording }
        do {
            try FileManager.default.moveItem(at: recording.url, to: newURL)
            return Recording(url: newURL, date: recording.date, duration: recording.duration)
        } catch {
            Self.logger.error("rename failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Copies each of `recordings` into `directory` (chosen via
    /// `NSOpenPanel` by `RecordingsListView`'s "Export Selected" button) —
    /// the app's own copy in `recordingsDirectory` is untouched, this is a
    /// plain export. A name collision at the destination (the folder
    /// already has a file with that name) is resolved with a Finder-style
    /// " 2"/" 3" suffix rather than overwriting or failing outright.
    /// Returns the number that copied successfully.
    @discardableResult
    static func export(_ recordings: [Recording], to directory: URL) -> Int {
        let fm = FileManager.default
        var succeeded = 0
        for recording in recordings {
            let base = recording.url.deletingPathExtension().lastPathComponent
            var destination = directory.appendingPathComponent(base).appendingPathExtension("wav")
            var suffix = 2
            while fm.fileExists(atPath: destination.path) {
                destination = directory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("wav")
                suffix += 1
            }
            do {
                try fm.copyItem(at: recording.url, to: destination)
                succeeded += 1
            } catch {
                Self.logger.error("export failed for \(recording.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return succeeded
    }
}

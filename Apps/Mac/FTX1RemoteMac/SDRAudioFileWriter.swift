import AVFoundation
import Foundation
import os

/// Writes the audio `SDRPageBridge` taps out of an OpenWebRX page (Int16
/// mono chunks, posted by the page tap) to a WAV in Recordings — the
/// app-side recorder for the one WebSDR-window platform with no recorder of
/// its own. 16-bit PCM at the page's own `AudioContext` rate (44.1/48 kHz;
/// WFM needs the full rate, so nothing is decimated).
///
/// Same shape as `AudioRecorder`: every file operation runs on a private
/// serial queue, so the WebKit message callback on the main actor only
/// decodes and hands off. The file is created on the first chunk, since
/// only the page knows its rate.
nonisolated final class SDRAudioFileWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.ftx1remote.sdr-audio-writer")
    // Only touched on `queue`.
    private var file: AVAudioFile?
    private var framesWritten = 0
    private var failed = false

    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "websdr-recording")

    init(url: URL) {
        self.url = url
    }

    /// `pcm`: little-endian Int16 samples, as the page tap packs them.
    func append(pcm: Data, sampleRate: Double) {
        queue.async { [self] in
            guard !failed, sampleRate > 0 else { return }
            let count = pcm.count / MemoryLayout<Int16>.size
            guard count > 0 else { return }
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                do {
                    file = try AVAudioFile(forWriting: url, settings: settings,
                                           commonFormat: .pcmFormatInt16, interleaved: false)
                } catch {
                    failed = true
                    Self.logger.error("couldn't create \(self.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    return
                }
            }
            guard let file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                buffer.int16ChannelData?[0].update(from: samples.baseAddress!, count: count)
            }
            do {
                try file.write(from: buffer)
                framesWritten += count
            } catch {
                Self.logger.error("write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Closes the file once every chunk already handed over is written.
    /// Returns its URL, or nil (and no file) if nothing was recorded.
    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                file = nil  // AVAudioFile finalizes the WAV header on release.
                if framesWritten == 0 {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }
}

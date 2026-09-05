import AVFoundation
import FTX1Core
import Foundation

/// Downsamples the Mac's captured radio audio (native hardware rate, mono
/// Float32 — see `AudioCaptureEngine.onAudioSamples`) to the fixed wire
/// format both sides agree on (`AudioStreamFormat`), using `AVAudioConverter`
/// rather than a hand-rolled resampler so the anti-aliasing/quality is
/// Apple's, not ours. Owns exactly one converter, rebuilt only when the
/// *input* sample rate actually changes (e.g. the user switches audio input
/// device mid-session) — not per-buffer.
final class AudioStreamEncoder {
    private var converter: AVAudioConverter?
    private var sourceSampleRate: Double?

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: AudioStreamFormat.sampleRate,
        channels: 1,
        interleaved: true
    )!

    /// Returns raw Int16LE mono PCM bytes at `AudioStreamFormat.sampleRate`,
    /// or `nil` if conversion fails (e.g. a momentarily invalid format).
    /// Dropping one buffer's worth of audio is inaudible and simpler than
    /// giving `HubService` an error it has no useful way to act on.
    func encode(samples: [Float], sampleRate: Double) -> Data? {
        guard !samples.isEmpty else { return nil }

        if converter == nil || sourceSampleRate != sampleRate {
            guard let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ), let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }
            converter = newConverter
            sourceSampleRate = sampleRate
        }
        guard let converter else { return nil }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inputBuffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }

        // Generous headroom over the naive ratio — the converter can emit a
        // few extra frames around a resample boundary; undersizing the
        // output buffer truncates audio rather than erroring.
        let estimatedOutputFrames = Int(Double(samples.count) * outputFormat.sampleRate / sampleRate) + 16
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedOutputFrames)
        ) else { return nil }

        // One-shot conversion: hand the converter the whole input buffer
        // exactly once, then tell it there's nothing more this call — the
        // standard AVAudioConverter pattern for converting a single
        // already-in-memory chunk rather than a continuous pull stream.
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil,
              let int16Data = outputBuffer.int16ChannelData else { return nil }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }
        return Data(bytes: int16Data[0], count: frameCount * MemoryLayout<Int16>.size)
    }
}

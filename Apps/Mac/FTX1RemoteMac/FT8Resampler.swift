import AVFoundation

/// Streaming resampler from the audio tap's native sample rate down to
/// 12000 Hz mono — what `FT8Decoder`/ft8_lib's reference vectors expect
/// (this app captures at 44100 Hz; see CLAUDE.md's "Audio-over-Pi" note).
///
/// Wraps one long-lived `AVAudioConverter`, reused across `convert(_:sourceRate:)`
/// calls so its internal resampling filter state persists across chunk
/// boundaries rather than restarting cold on every ~2048-sample buffer —
/// rebuilt only if the source sample rate actually changes (mirrors
/// `APRSDecoder`'s demodulator-rebuild-on-rate-change pattern, including
/// the reasoning: some audio interfaces report a wobbling sample rate
/// buffer to buffer without the device format actually changing).
final class FT8Resampler {
    static let targetSampleRate: Double = 12000

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Converts one chunk of mono `Float` samples at `sourceRate` to mono
    /// `Float` samples at `Self.targetSampleRate`. Returns an empty array on
    /// any conversion failure — callers just treat that as "nothing to
    /// append this call," same as a too-short buffer.
    func convert(_ samples: [Float], sourceRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }

        if sourceFormat?.sampleRate != sourceRate {
            guard let newSourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: 1,
                interleaved: false
            ) else { return [] }
            sourceFormat = newSourceFormat
            converter = AVAudioConverter(from: newSourceFormat, to: targetFormat)
        }
        guard let converter, let sourceFormat,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            inputBuffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }

        let ratio = Self.targetSampleRate / sourceRate
        let outputCapacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return [] }

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

        guard status != .error, let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    /// Discards the converter's internal filter state — call when starting
    /// a fresh decode session so leftover state from a previous session
    /// doesn't bleed into the first block.
    func reset() {
        converter?.reset()
    }
}

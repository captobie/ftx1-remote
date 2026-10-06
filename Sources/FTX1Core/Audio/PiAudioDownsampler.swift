import AVFoundation

/// Converts one channel of the Pi's 44.1 kHz samples (as delivered by
/// `RemoteAudioStreamClient`) into the 8 kHz Int16 mono PCM that
/// `AudioPlaybackEngine.push(pcm:)` plays — the same wire format the Mac
/// relays to iOS/iPad (`AudioStreamFormat.sampleRate`).
///
/// One long-lived `AVAudioConverter`, reused across chunks so its filter
/// state carries over chunk boundaries (same pattern as the Mac's
/// `FT8Resampler`); rebuilt only if the source rate changes.
///
/// `@unchecked Sendable`: called from `RemoteAudioStreamClient`'s actor,
/// one chunk at a time, never concurrently. Used by `PiDirectViewModel`,
/// one instance per channel.
public final class PiAudioDownsampler: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioStreamFormat.sampleRate,
        channels: 1,
        interleaved: false
    )!

    public init() {}

    /// Returns little-endian Int16 PCM, or empty `Data` on any failure.
    public func convert(_ samples: [Float], sourceRate: Double) -> Data {
        guard !samples.isEmpty else { return Data() }

        if sourceFormat?.sampleRate != sourceRate {
            guard let newSourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: 1,
                interleaved: false
            ) else { return Data() }
            sourceFormat = newSourceFormat
            converter = AVAudioConverter(from: newSourceFormat, to: targetFormat)
        }
        guard let converter, let sourceFormat,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return Data() }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            inputBuffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }

        let ratio = targetFormat.sampleRate / sourceRate
        let outputCapacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return Data() }

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
        guard status != .error, let channelData = outputBuffer.floatChannelData else { return Data() }

        let frameCount = Int(outputBuffer.frameLength)
        var pcm = Data(count: frameCount * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let clamped = max(-1, min(1, channelData[0][i]))
                out[i] = Int16(clamped * Float(Int16.max)).littleEndian
            }
        }
        return pcm
    }
}

import AVFoundation

/// Whatever rate the taps deliver (44.1 kHz from the rig, 48 kHz from the
/// WebSDR tap, ~12 kHz from the Kiwi) down to RADE's 8 kHz — or a
/// microphone to the transmitter's 16 kHz — with one
/// long-lived `AVAudioConverter` per input rate so its filter state carries
/// across chunks (the same approach as FT8's resampler, checked in
/// `RADEDecoderTests.testStreamingResampleFrom44100StillDecodes`).
final class FreeDVResampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat

    init(outputRate: Double = RADEDecoder.modemSampleRate) {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate,
                                     channels: 1, interleaved: false)!
    }

    func reset() {
        converter = nil
        inputFormat = nil
    }

    func resample(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        if sampleRate == outputFormat.sampleRate { return samples }
        if inputFormat?.sampleRate != sampleRate {
            inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                        channels: 1, interleaved: false)
            converter = inputFormat.flatMap { AVAudioConverter(from: $0, to: outputFormat) }
        }
        guard let converter, let inputFormat,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount((Double(samples.count) * outputFormat.sampleRate / sampleRate).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

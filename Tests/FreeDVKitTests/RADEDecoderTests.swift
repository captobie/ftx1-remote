import AVFoundation
import XCTest
@testable import FreeDVKit

/// `rade_offair_50s.wav` is the first 50 s of rade_c's own off-air sample
/// (`FDV_offair.wav` in freedv/rade_c, BSD-2), resampled 48 → 8 kHz. Two
/// overs end in it: VK5KVA at ~10.6 s and VK3TPM at ~46.1 s, both callsigns
/// carried in the end-of-over (checked against rade_c's own `rade_rx_wav`
/// and freedv-backend's `rade_text` when the clip was made).
final class RADEDecoderTests: XCTestCase {
    func testDecodesOffAirClip() throws {
        let samples = try Self.loadFixture()
        let result = try Self.decode(chunks: Self.chunked(samples, size: 160))

        XCTAssertEqual(result.endsOfOver.compactMap(\.callsign), ["VK5KVA", "VK3TPM"])
        let times = result.endsOfOver.map { Double($0.sampleTime) / RADEDecoder.modemSampleRate }
        XCTAssertEqual(times.count, 2)
        if times.count == 2 {
            XCTAssertEqual(times[0], 10.6, accuracy: 0.5)
            XCTAssertEqual(times[1], 46.1, accuracy: 0.5)
        }
        // ~43 s of the 50 are speech (the gap between overs isn't).
        let seconds = Double(result.speech.count) / RADEDecoder.speechSampleRate
        XCTAssertGreaterThan(seconds, 38)
        XCTAssertLessThan(seconds, 50)
        XCTAssertGreaterThan(result.maxSNR, 10)
        XCTAssertLessThan(result.maxAbsFrequencyOffset, 5)
        // Real speech, not silence or a stuck output.
        let rms = sqrt(result.speech.reduce(0) { $0 + $1 * $1 } / Float(result.speech.count))
        XCTAssertGreaterThan(rms, 0.01)
    }

    /// Chunk size mustn't matter: one call with everything, and odd sizes.
    func testChunkSizeDoesNotChangeTheResult() throws {
        let samples = try Self.loadFixture()
        let whole = try Self.decode(chunks: [samples])
        let odd = try Self.decode(chunks: Self.chunked(samples, size: 1237))
        XCTAssertEqual(whole.speech, odd.speech)
        XCTAssertEqual(whole.endsOfOver, odd.endsOfOver)
    }

    /// The app's taps deliver 44.1 kHz in 2048-sample chunks; it will
    /// resample to 8 kHz with one long-lived AVAudioConverter, as FT8 does.
    func testStreamingResampleFrom44100StillDecodes() throws {
        let samples = try Self.loadFixture()
        let upsampled = try Self.resampleWhole(samples, from: 8000, to: 44100)
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
        let chunks = Self.chunked(upsampled, size: 2048).map { Self.convert($0, source: source, target: target, converter: converter) }
        let result = try Self.decode(chunks: chunks)
        XCTAssertEqual(result.endsOfOver.compactMap(\.callsign), ["VK5KVA", "VK3TPM"])
        XCTAssertGreaterThan(Double(result.speech.count) / RADEDecoder.speechSampleRate, 38)
    }

    /// Band noise alone mustn't produce speech or a callsign.
    func testNoiseAlone() throws {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(30 * 8000)).map { _ in Float.random(in: -0.2...0.2, using: &generator) }
        let result = try Self.decode(chunks: Self.chunked(noise, size: 1024))
        XCTAssertTrue(result.endsOfOver.compactMap(\.callsign).isEmpty)
        XCTAssertLessThan(Double(result.speech.count) / RADEDecoder.speechSampleRate, 2)
    }

    // MARK: - Helpers

    private struct Decoded {
        var speech: [Float] = []
        var endsOfOver: [RADEEndOfOver] = []
        var maxSNR: Float = -.infinity
        var maxAbsFrequencyOffset: Float = 0
    }

    private static func decode(chunks: [[Float]]) throws -> Decoded {
        let decoder = try XCTUnwrap(RADEDecoder())
        var result = Decoded()
        for chunk in chunks {
            let output = decoder.process(chunk)
            result.speech += output.speech
            result.endsOfOver += output.endsOfOver
            if output.status.sync {
                result.maxSNR = max(result.maxSNR, output.status.snrDB)
                result.maxAbsFrequencyOffset = max(result.maxAbsFrequencyOffset, abs(output.status.frequencyOffsetHz))
            }
        }
        return result
    }

    private static func chunked(_ samples: [Float], size: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }

    private static func loadFixture() throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rade_offair_50s", withExtension: "wav", subdirectory: "Resources"))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.fileFormat.sampleRate, 8000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private static func resampleWhole(_ samples: [Float], from: Double, to: Double) throws -> [Float] {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
        return convert(samples, source: source, target: target, converter: converter, extra: 1024)
    }

    private static func convert(_ samples: [Float], source: AVAudioFormat, target: AVAudioFormat,
                                converter: AVAudioConverter, extra: AVAudioFrameCount = 16) -> [Float] {
        guard !samples.isEmpty, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount((Double(samples.count) * target.sampleRate / source.sampleRate).rounded(.up)) + extra
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

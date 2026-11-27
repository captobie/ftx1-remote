import AVFoundation
import XCTest
@testable import FreeDVKit

/// Transmit → receive loopback: speech (the off-air clip's own decoded
/// voice, so it's real speech) through `RADEEncoder`, then `RADEDecoder`.
final class RADEEncoderTests: XCTestCase {
    func testLoopbackDecodesSpeechAndCallsign() throws {
        let speech = try Self.decodedSpeech(seconds: 8)
        let encoder = try XCTUnwrap(RADEEncoder())
        var modem: [Float] = []
        // Mic-sized pieces (~21 ms), not whole frames.
        for start in stride(from: 0, to: speech.count, by: 341) {
            modem += encoder.process(Array(speech[start..<min(start + 341, speech.count)]))
        }
        modem += encoder.finish(callsign: "te5t")
        XCTAssertTrue(encoder.finish(callsign: "TE5T").isEmpty, "a second finish adds nothing")

        // 120 ms frames: ~8 s of speech is ~8 s of modem audio.
        let seconds = Double(modem.count) / RADEEncoder.modemSampleRate
        XCTAssertEqual(seconds, 8.2, accuracy: 0.6)
        let peak = modem.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.3)
        // At FreeDV's output scale the peaks stay under full scale.
        XCTAssertLessThan(peak * RADEEncoder.nominalOutputScale, 1.0)

        // Received as an SSB receiver would hand it over (real audio, the
        // FreeDV scale, a little silence either side).
        let silence = [Float](repeating: 0, count: 4000)
        let received = silence + modem.map { $0 * RADEEncoder.nominalOutputScale } + silence + silence
        let decoder = try XCTUnwrap(RADEDecoder())
        let output = decoder.process(received)
        XCTAssertEqual(output.endsOfOver.compactMap(\.callsign), ["TE5T"])
        let decodedSeconds = Double(output.speech.count) / RADEDecoder.speechSampleRate
        XCTAssertGreaterThan(decodedSeconds, 5)
    }

    func testNoCallsignSendsAnEmptyEndOfOver() throws {
        let speech = try Self.decodedSpeech(seconds: 4)
        let encoder = try XCTUnwrap(RADEEncoder())
        let modem = encoder.process(speech) + encoder.finish(callsign: nil)
        let decoder = try XCTUnwrap(RADEDecoder())
        let silence = [Float](repeating: 0, count: 8000)
        let output = decoder.process(silence + modem.map { $0 * RADEEncoder.nominalOutputScale } + silence)
        XCTAssertTrue(output.endsOfOver.compactMap(\.callsign).isEmpty)
    }

    /// Real speech: the receiver's output for the off-air clip, from where
    /// the first over is in sync.
    private static func decodedSpeech(seconds: Double) throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rade_offair_50s", withExtension: "wav", subdirectory: "Resources"))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let decoder = try XCTUnwrap(RADEDecoder())
        let speech = decoder.process(samples).speech
        let count = Int(seconds * RADEDecoder.speechSampleRate)
        XCTAssertGreaterThan(speech.count, count + 16000)
        return Array(speech[16000..<(16000 + count)])
    }
}

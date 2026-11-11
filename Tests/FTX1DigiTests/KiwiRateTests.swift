import XCTest
@testable import FTX1Digi

/// The MyKiwiSDR source hands the decoder audio at the rate the Kiwi
/// reports — ~11998.9 Hz, not a standard rate — in 512-sample frames.
/// `DigiDecoder` must resample that to its 8 kHz without losing text.
final class KiwiRateTests: XCTestCase {
    private static let kiwiRate = 11998.902088

    private func decode(_ audio: [Float], mode: DigiMode, centerHz: Double) -> String {
        let decoder = DigiDecoder(mode: mode, rttySettings: RTTYSettings(), centerHz: centerHz, afc: true, squelch: 0)
        var text = ""
        var index = 0
        while index < audio.count {
            let frame = Array(audio[index..<min(index + 512, audio.count)])
            text += decoder.process(samples: frame, sampleRate: Self.kiwiRate).text
            index += 512
        }
        return text
    }

    func testBPSK31AtTheKiwisRate() {
        let text = "CQ CQ de W1AW W1AW pse k"
        let audio = SignalSynth.bpsk(text: text, carrierHz: 1000, sampleRate: Self.kiwiRate)
        XCTAssertTrue(decode(audio, mode: .bpsk31, centerHz: 1000).contains(text))
    }

    func testRTTYAtTheKiwisRateWithNoise() {
        let text = "CQ TEST DE W1AW W1AW K"
        let clean = SignalSynth.rtty(text: text, markHz: 2125, spaceHz: 2295, sampleRate: Self.kiwiRate)
        let audio = SignalSynth.addNoise(clean, snrDb3k: 6, sampleRate: Self.kiwiRate)
        XCTAssertTrue(decode(audio, mode: .rtty, centerHz: 2210).contains(text))
    }
}

import XCTest
@testable import FTX1Digi

final class CodeTableTests: XCTestCase {
    func testVaricodeTableIsWellFormed() {
        XCTAssertEqual(Varicode.codes.count, 128)
        XCTAssertEqual(Set(Varicode.codes).count, 128, "codes must be unique")
        for code in Varicode.codes {
            XCTAssertTrue(code.hasPrefix("1") && code.hasSuffix("1"), code)
            XCTAssertFalse(code.contains("00"), code)
            XCTAssertLessThanOrEqual(code.count, 10, code)
        }
        XCTAssertEqual(Varicode.codes[Int(Character("e").asciiValue!)], "11")
        XCTAssertEqual(Varicode.codes[32], "1")
    }

    func testVaricodeRoundTrip() {
        let text = "CQ CQ de W1AW pse k\n599 <tu> 73!"
        var decoder = Varicode.Decoder()
        var output = ""
        for bit in [false, false] + Varicode.encode(text) {
            if let ascii = decoder.push(bit: bit) { output.unicodeScalars.append(Unicode.Scalar(ascii)) }
        }
        XCTAssertEqual(output, text)
    }

    func testBaudotRoundTrip() {
        let text = "CQ TEST DE W1AW 599 001 K\nRYRY $5.00?"
        var decoder = Baudot.Decoder()
        var output = ""
        for code in Baudot.encode(text) {
            if code == Baudot.carriageReturn { continue }
            if let character = decoder.decode(code) { output.append(character) }
        }
        XCTAssertEqual(output, text)
    }

    func testUnshiftOnSpace() {
        // FIGS 5 9 9, space, then E without a LTRS.
        var decoder = Baudot.Decoder(unshiftOnSpace: true)
        let codes: [UInt8] = [27, 16, 24, 24, 4, 1]
        XCTAssertEqual(String(codes.compactMap { decoder.decode($0) }), "599 E")
        var plain = Baudot.Decoder(unshiftOnSpace: false)
        XCTAssertEqual(String(codes.compactMap { plain.decode($0) }), "599 3")
    }
}

final class RTTYDecodeTests: XCTestCase {
    let message = "CQ TEST DE W1AW W1AW K\nUR 599 001 TU"

    private func decode(_ audio: [Float], settings: RTTYSettings = RTTYSettings(), centerHz: Double,
                        afc: Bool = true, squelch: Float = 0) -> (text: String, center: Double) {
        let decoder = DigiDecoder(mode: .rtty, rttySettings: settings, centerHz: centerHz, afc: afc, squelch: squelch)
        var text = ""
        var index = 0
        while index < audio.count {
            let chunk = Array(audio[index..<min(index + 512, audio.count)])
            text += decoder.process(samples: chunk, sampleRate: 8000).text
            index += 512
        }
        return (text, decoder.centerHz)
    }

    func testClean170() {
        let audio = SignalSynth.rtty(text: message, markHz: 1445, spaceHz: 1615)
        XCTAssertTrue(decode(audio, centerHz: 1530).text.contains(message), decode(audio, centerHz: 1530).text)
    }

    func testShift850At2125Mark() {
        let audio = SignalSynth.rtty(text: message, markHz: 2125, spaceHz: 2975)
        let result = decode(audio, settings: RTTYSettings(shiftHz: 850), centerHz: 2550)
        XCTAssertTrue(result.text.contains(message), result.text)
    }

    func testFiftyAndSeventyFiveBaud() {
        for baud in [50.0, 75.0] {
            let audio = SignalSynth.rtty(text: message, markHz: 1445, spaceHz: 1615, baud: baud)
            let result = decode(audio, settings: RTTYSettings(baud: baud), centerHz: 1530)
            XCTAssertTrue(result.text.contains(message), "\(baud): \(result.text)")
        }
    }

    func testReverse() {
        // Mark above space: garbage without Reverse, clean with it.
        let audio = SignalSynth.rtty(text: message, markHz: 1615, spaceHz: 1445)
        XCTAssertFalse(decode(audio, centerHz: 1530).text.contains(message))
        let result = decode(audio, settings: RTTYSettings(reverse: true), centerHz: 1530)
        XCTAssertTrue(result.text.contains(message), result.text)
    }

    func testNoisyWithOffsetAndAFC() {
        // 20 Hz high, 3 dB SNR in 3 kHz; a long lead lets AFC settle.
        let long = String(repeating: "RYRYRY ", count: 4) + message
        let clean = SignalSynth.rtty(text: long, markHz: 1465, spaceHz: 1635, leadSeconds: 1.5)
        let audio = SignalSynth.addNoise(clean, snrDb3k: 3, sampleRate: 8000)
        let result = decode(audio, centerHz: 1530)
        XCTAssertTrue(result.text.contains("UR 599 001 TU"), result.text)
        XCTAssertEqual(result.center, 1550, accuracy: 5)
    }

    func testNoiseOnlyIsSquelched() {
        let audio = SignalSynth.noise(seconds: 10, sigma: 0.1, sampleRate: 8000)
        let text = decode(audio, centerHz: 1530, squelch: 0.3).text
        XCTAssertLessThan(text.count, 5, text)
    }
}

final class PSKDecodeTests: XCTestCase {
    let message = "CQ CQ de W1AW W1AW pse k\nur rst 599 tnx fer call 73"

    private func decode(_ audio: [Float], mode: DigiMode = .bpsk31, centerHz: Double,
                        squelch: Float = 0.3, sampleRate: Double = 8000, chunk: Int = 512) -> (text: String, center: Double) {
        let decoder = DigiDecoder(mode: mode, rttySettings: RTTYSettings(), centerHz: centerHz, afc: true, squelch: squelch)
        var text = ""
        var index = 0
        while index < audio.count {
            let piece = Array(audio[index..<min(index + chunk, audio.count)])
            text += decoder.process(samples: piece, sampleRate: sampleRate).text
            index += chunk
        }
        return (text, decoder.centerHz)
    }

    func testCleanBPSK31() {
        let audio = SignalSynth.bpsk(text: message, carrierHz: 1000)
        let result = decode(audio, centerHz: 1000)
        XCTAssertTrue(result.text.contains(message), result.text)
    }

    func testCleanBPSK63() {
        let audio = SignalSynth.bpsk(text: message, carrierHz: 1500, baud: 62.5, idleSymbols: 128)
        let result = decode(audio, mode: .bpsk63, centerHz: 1500)
        XCTAssertTrue(result.text.contains(message), result.text)
    }

    func testOffsetPulledInByAFC() {
        let audio = SignalSynth.bpsk(text: message, carrierHz: 1005, idleSymbols: 96)
        let result = decode(audio, centerHz: 1000)
        XCTAssertTrue(result.text.contains("ur rst 599 tnx fer call 73"), result.text)
        XCTAssertEqual(result.center, 1005, accuracy: 1)
    }

    func testNoisy() {
        let clean = SignalSynth.bpsk(text: message, carrierHz: 1200, idleSymbols: 96)
        let audio = SignalSynth.addNoise(clean, snrDb3k: -6, sampleRate: 8000)
        let result = decode(audio, centerHz: 1203)
        XCTAssertTrue(result.text.contains("tnx fer call 73"), result.text)
    }

    func testNoiseOnlyIsSquelched() {
        let audio = SignalSynth.noise(seconds: 10, sigma: 0.1, sampleRate: 8000)
        let text = decode(audio, centerHz: 1000).text
        XCTAssertLessThan(text.count, 3, text)
    }

    func testThroughResamplerFrom44100() {
        let audio = SignalSynth.bpsk(text: message, carrierHz: 1000, sampleRate: 44100)
        let result = decode(audio, centerHz: 1000, sampleRate: 44100, chunk: 2048)
        XCTAssertTrue(result.text.contains(message), result.text)
    }

    func testRTTYThroughResamplerFrom48000() {
        let text = "CQ TEST DE W1AW K"
        let audio = SignalSynth.rtty(text: text, markHz: 1445, spaceHz: 1615, sampleRate: 48000)
        let decoder = DigiDecoder(mode: .rtty, rttySettings: RTTYSettings(), centerHz: 1530, afc: true, squelch: 0)
        var output = ""
        var index = 0
        while index < audio.count {
            output += decoder.process(samples: Array(audio[index..<min(index + 2048, audio.count)]), sampleRate: 48000).text
            index += 2048
        }
        XCTAssertTrue(output.contains(text), output)
    }

    func testSpectrumRowsShowTheCarrier() {
        let audio = SignalSynth.bpsk(text: message, carrierHz: 1500)
        let decoder = DigiDecoder(mode: .bpsk31, rttySettings: RTTYSettings(), centerHz: 1500, afc: true, squelch: 0.3)
        var last: [Float]?
        var index = 0
        while index < 16000 {
            if let row = decoder.process(samples: Array(audio[index..<index + 400]), sampleRate: 8000).spectrumRow { last = row }
            index += 400
        }
        let row = try! XCTUnwrap(last)
        let binHz = DigiDecoder.sampleRate / Double(DigiDecoder.fftSize)
        XCTAssertEqual(row.count, Int(DigiDecoder.stripSpanHz / binHz))
        let peak = row.indices.max { row[$0] < row[$1] }!
        XCTAssertEqual(Double(peak) * binHz, 1500, accuracy: 25)
    }
}

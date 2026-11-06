import XCTest
@testable import FTX1Digi

final class ModulatorTests: XCTestCase {
    /// Runs a modulator over `text`, then `idleSeconds` with nothing to
    /// send, then its tail; returns the audio and the echoed characters.
    private func render(_ modulator: DigiModulator, text: String, idleSeconds: Double = 0.5) -> (audio: [Float], echo: String) {
        var queue = Array(text)
        var echo = ""
        modulator.onCharacterStarted = { echo.append($0) }
        var audio: [Float] = []
        while !queue.isEmpty {
            audio += modulator.render(160) { queue.isEmpty ? nil : queue.removeFirst() }
        }
        for _ in 0..<Int(idleSeconds * 50) {
            audio += modulator.render(160) { nil }
        }
        modulator.beginTail()
        var guardCount = 0
        while !modulator.isFinished, guardCount < 2000 {
            audio += modulator.render(160) { nil }
            guardCount += 1
        }
        XCTAssertTrue(modulator.isFinished)
        return (audio, echo)
    }

    private func decode(_ audio: [Float], mode: DigiMode, settings: RTTYSettings = RTTYSettings(), centerHz: Double) -> String {
        let decoder = DigiDecoder(mode: mode, rttySettings: settings, centerHz: centerHz, afc: true, squelch: 0)
        var text = ""
        var index = 0
        while index < audio.count {
            text += decoder.process(samples: Array(audio[index..<min(index + 512, audio.count)]), sampleRate: 8000).text
            index += 512
        }
        return text
    }

    func testRTTYRoundTrip() {
        let text = "CQ TEST DE W1AW W1AW K\nUR 599 001 TU QRZ? $5.00 (OK)"
        let modulator = RTTYModulator(markHz: 2125, spaceHz: 2295, baud: 45.45, level: 0.5)
        let result = render(modulator, text: text)
        XCTAssertEqual(result.echo, text)
        XCTAssertTrue(decode(result.audio, mode: .rtty, centerHz: 2210).contains(text))
    }

    func testRTTYSendsLowercaseAsUppercaseAndSkipsUnsendable() {
        let modulator = RTTYModulator(markHz: 1445, spaceHz: 1615, baud: 45.45, level: 0.5)
        let result = render(modulator, text: "cq de w1aw ~ k")
        XCTAssertEqual(result.echo, "cq de w1aw  k")
        XCTAssertTrue(decode(result.audio, mode: .rtty, centerHz: 1530).contains("CQ DE W1AW  K"))
    }

    func testRTTYFiguresAfterSpaceGetANewShift() {
        // "5 5": with USOS on the receiving end, the second 5 needs FIGS again.
        var inFigures = false
        XCTAssertEqual(RTTYModulator.codes(for: "5", inFigures: &inFigures), [Baudot.figs, 16])
        XCTAssertEqual(RTTYModulator.codes(for: " ", inFigures: &inFigures), [Baudot.space])
        XCTAssertEqual(RTTYModulator.codes(for: "5", inFigures: &inFigures), [Baudot.figs, 16])
        XCTAssertEqual(RTTYModulator.codes(for: "E", inFigures: &inFigures), [Baudot.ltrs, 1])
    }

    func testRTTYReversedTonesNeedReverse() {
        let text = "RYRY DE W1AW K"
        let modulator = RTTYModulator(markHz: 2295, spaceHz: 2125, baud: 45.45, level: 0.5)
        let audio = render(modulator, text: text).audio
        XCTAssertTrue(decode(audio, mode: .rtty, settings: RTTYSettings(reverse: true), centerHz: 2210).contains(text))
    }

    func testRTTYIdleAndTailDecodeAsNothing() {
        let modulator = RTTYModulator(markHz: 2125, spaceHz: 2295, baud: 45.45, level: 0.5)
        let result = render(modulator, text: "", idleSeconds: 2)
        XCTAssertEqual(decode(result.audio, mode: .rtty, centerHz: 2210).trimmingCharacters(in: .whitespaces), "")
        // 2 s rendered (the 0.5 s lead plays inside it), then LTRS + 0.2 s
        // of mark for the tail: about 2.4 s, rounded up to whole chunks.
        XCTAssertEqual(Double(result.audio.count) / 8000, 2.45, accuracy: 0.1)
    }

    func testBPSK31RoundTrip() {
        let text = "CQ CQ de W1AW W1AW pse k\nur rst 599 tnx fer call 73 {ok}"
        let modulator = PSKModulator(carrierHz: 1000, baud: 31.25, level: 0.5)
        let result = render(modulator, text: text)
        XCTAssertEqual(result.echo, text)
        XCTAssertTrue(decode(result.audio, mode: .bpsk31, centerHz: 1000).contains(text))
    }

    func testBPSK63RoundTrip() {
        let text = "CQ CQ de W1AW pse k"
        let modulator = PSKModulator(carrierHz: 1500, baud: 62.5, level: 0.5)
        XCTAssertTrue(decode(render(modulator, text: text).audio, mode: .bpsk63, centerHz: 1500).contains(text))
    }

    func testPSKTextTypedAfterIdleStillDecodes() {
        // Typeahead: nothing for a second, then text.
        let modulator = PSKModulator(carrierHz: 1200, baud: 31.25, level: 0.5)
        var audio: [Float] = []
        for _ in 0..<50 { audio += modulator.render(160) { nil } }
        var queue = Array("late text 73")
        while !queue.isEmpty { audio += modulator.render(160) { queue.isEmpty ? nil : queue.removeFirst() } }
        modulator.beginTail()
        while !modulator.isFinished { audio += modulator.render(160) { nil } }
        XCTAssertTrue(decode(audio, mode: .bpsk31, centerHz: 1200).contains("late text 73"))
    }

    func testLevelIsThePeak() {
        let modulator = PSKModulator(carrierHz: 1000, baud: 31.25, level: 0.3)
        let audio = render(modulator, text: "test").audio
        XCTAssertEqual(audio.map(abs).max()!, 0.3, accuracy: 0.01)
    }
}

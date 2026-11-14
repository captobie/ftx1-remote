import XCTest
@testable import FTX1Digi

final class PSKBrowserTests: XCTestCase {
    private struct Signal {
        let hz: Double
        let text: String
    }

    /// Several signals mixed, each starting at its own time, in white noise.
    private func mix(_ signals: [Signal], baud: Double = 31.25, offsets: [Int] = [], snrDb3k: Double? = nil) -> [Float] {
        let rendered = signals.enumerated().map { index, signal in
            let lead = index < offsets.count ? offsets[index] : 0
            return [Float](repeating: 0, count: lead)
                + SignalSynth.bpsk(text: signal.text, carrierHz: signal.hz, baud: baud, idleSymbols: 96, amplitude: 0.2)
        }
        let length = rendered.map(\.count).max() ?? 0
        var audio = [Float](repeating: 0, count: length + 8000)
        for signal in rendered {
            for (k, x) in signal.enumerated() { audio[k] += x }
        }
        guard let snrDb3k else { return audio }
        // SNR of one signal (amplitude 0.2 cosine ≈ power 0.02).
        return SignalSynth.addNoise(audio, power: 0.02, snrDb3k: snrDb3k, sampleRate: 8000, seed: 3)
    }

    private func run(_ audio: [Float], mode: DigiMode = .bpsk31) -> [PSKBrowserChannel] {
        let decoder = DigiDecoder(mode: mode, rttySettings: RTTYSettings(), centerHz: 1000, afc: true, squelch: 0.3, browser: true)
        var last: [PSKBrowserChannel] = []
        var index = 0
        while index < audio.count {
            let chunk = Array(audio[index..<min(index + 512, audio.count)])
            if let channels = decoder.process(samples: chunk, sampleRate: 8000).browser { last = channels }
            index += 512
        }
        return last
    }

    private func assertDecoded(_ signals: [Signal], in channels: [PSKBrowserChannel], file: StaticString = #filePath, line: UInt = #line) {
        for signal in signals {
            let match = channels.first { abs($0.frequencyHz - signal.hz) < 10 }
            XCTAssertNotNil(match, "no channel near \(signal.hz) Hz in \(channels.map(\.frequencyHz))", file: file, line: line)
            XCTAssertTrue(match?.text.contains(signal.text.dropFirst(8)) ?? false,
                          "\(signal.hz) Hz decoded \"\(match?.text ?? "")\"", file: file, line: line)
        }
    }

    private let three = [
        Signal(hz: 700, text: "CQ CQ DE K1ABC K1ABC PSE K"),
        Signal(hz: 1150, text: "W2XYZ DE N3QRS UR 599 599 BK"),
        Signal(hz: 1720, text: "TNX FER QSO 73 ES GUD DX SK"),
    ]

    func testThreeCleanSignals() {
        let channels = run(mix(three, offsets: [0, 4000, 9000]))
        assertDecoded(three, in: channels)
    }

    func testThreeSignalsInNoise() {
        let channels = run(mix(three, offsets: [0, 4000, 9000], snrDb3k: -3))
        assertDecoded(three, in: channels)
    }

    func testSignalsNinetyHertzApart() {
        let close = [
            Signal(hz: 1000, text: "CQ CQ DE K1ABC K1ABC PSE K"),
            Signal(hz: 1090, text: "W2XYZ DE N3QRS UR 599 599 BK"),
        ]
        assertDecoded(close, in: run(mix(close, offsets: [0, 2000])))
    }

    func testBPSK63() {
        let two = [
            Signal(hz: 800, text: "CQ CQ DE K1ABC K1ABC PSE K"),
            Signal(hz: 1600, text: "W2XYZ DE N3QRS UR 599 599 BK"),
        ]
        let audio = mix(two, baud: 62.5, offsets: [0, 3000])
        assertDecoded(two, in: run(audio, mode: .bpsk63))
    }

    func testNoiseAlonePrintsNothing() {
        let noise = SignalSynth.noise(seconds: 30, sigma: 0.1, sampleRate: 8000)
        let channels = run(noise)
        let printed = channels.map(\.text).joined()
        XCTAssertLessThan(printed.count, 5, "noise printed \"\(printed)\"")
    }

    func testChannelDroppedAfterSignalEnds() {
        // A signal, then 15 s of quiet: a channel that printed stays for
        // a minute, so check one that never printed (a bare carrier).
        var carrier = (0..<(8000 * 4)).map { Float(0.2 * cos(2 * .pi * 1300 * Double($0) / 8000)) }
        carrier += [Float](repeating: 0, count: 8000 * 15)
        let noise = SignalSynth.noise(seconds: 19, sigma: 0.01, sampleRate: 8000)
        let channels = run(zip(carrier, noise).map(+))
        XCTAssertFalse(channels.contains { abs($0.frequencyHz - 1300) < 20 }, "\(channels)")
    }

    func testBrowserOffByDefault() {
        let decoder = DigiDecoder(mode: .bpsk31, rttySettings: RTTYSettings(), centerHz: 1000, afc: true, squelch: 0.3)
        let audio = mix(three)
        var sawBrowser = false
        var index = 0
        while index < audio.count {
            let chunk = Array(audio[index..<min(index + 512, audio.count)])
            if decoder.process(samples: chunk, sampleRate: 8000).browser != nil { sawBrowser = true }
            index += 512
        }
        XCTAssertFalse(sawBrowser)
    }

    func testCost() {
        // 60 s of a busy band: 8 signals in noise.
        let signals = (0..<8).map { Signal(hz: 400 + Double($0) * 290, text: String(repeating: "CQ CQ DE K1ABC PSE K ", count: 6)) }
        let audio = mix(signals, snrDb3k: 0)
        let start = Date()
        let channels = run(audio)
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Double(audio.count) / 8000
        print("PSK browser: \(String(format: "%.1f", seconds)) s of audio in \(String(format: "%.2f", elapsed)) s, \(channels.count) channels")
        XCTAssertGreaterThanOrEqual(channels.filter { !$0.text.isEmpty }.count, 8)
    }
}

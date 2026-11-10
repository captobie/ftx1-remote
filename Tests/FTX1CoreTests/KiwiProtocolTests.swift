import XCTest
@testable import FTX1Core

/// The KiwiSDR sound protocol against frames captured from a KiwiSDR 2
/// (v1.902) — see `Tests/KiwiSDRFixtures/README.md`.
final class KiwiProtocolTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("KiwiSDRFixtures")

    private func sound(_ name: String) throws -> KiwiSoundFrame {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        guard case .sound(let frame) = KiwiProtocol.parseFrame(data) else {
            XCTFail("\(name) isn't a SND frame")
            throw CocoaError(.coderInvalidValue)
        }
        return frame
    }

    // MARK: - SND frames

    func testUncompressedFrames() throws {
        let first = try sound("snd-pcm-1-newfreq.bin")
        XCTAssertEqual(first.flags, [.lowPassFilter, .newFrequency])
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.smeterRaw, 0x0123)
        XCTAssertEqual(first.smeterDBm, 0.1 * 291 - 127, accuracy: 1e-9)
        XCTAssertEqual(first.pcmSamples().count, 512)

        let second = try sound("snd-pcm-2.bin")
        XCTAssertEqual(second.flags, [])
        XCTAssertEqual(second.sequence, 2)
        let samples = second.pcmSamples()
        XCTAssertEqual(samples.count, 512)
        // Big-endian: the payload opens 10 ce 17 db.
        XCTAssertEqual(samples[0], Int16(bitPattern: 0x10CE))
        XCTAssertEqual(samples[1], Int16(bitPattern: 0x17DB))

        let retune = try sound("snd-pcm-retune.bin")
        XCTAssertTrue(retune.flags.contains(.newFrequency))
        XCTAssertEqual(retune.sequence, 0x6F)
        XCTAssertEqual(retune.smeterDBm, 0.1 * Double(0x014E) - 127, accuracy: 1e-9)
    }

    func testCompressedFrames() throws {
        let frames = try (1...3).map { try sound("snd-adpcm-\($0).bin") }
        XCTAssertEqual(frames.map(\.flags.rawValue), [0x15, 0x10, 0x10])
        XCTAssertEqual(frames.map(\.sequence), [1, 2, 3])
        XCTAssertTrue(frames.allSatisfy { $0.payload.count == 1024 })
        XCTAssertEqual(frames[0].pcmSamples(), [], "compressed frames aren't PCM")

        var decoder = KiwiSoundDecoder()
        let decoded = frames.map { decoder.samples(from: $0) }
        XCTAssertEqual(decoded.map(\.count), [2048, 2048, 2048])

        // Carrying the state across frames is what makes the audio
        // continuous: the step across each boundary is no bigger than the
        // steps inside the frames. Resetting per frame would restart at 0.
        let joined = decoded.flatMap { $0 }
        func step(_ i: Int) -> Int { abs(Int(joined[i]) - Int(joined[i - 1])) }
        let inner = (1..<joined.count).filter { $0 % 2048 != 0 }.map(step).max()!
        for boundary in [2048, 4096] {
            XCTAssertLessThanOrEqual(step(boundary), inner)
        }
        var fresh = KiwiADPCMDecoder()
        let restarted = fresh.decode(frames[1].payload)
        XCTAssertNotEqual(Array(restarted.prefix(16)), Array(decoded[1].prefix(16)))
    }

    func testADPCMHandVectors() {
        var decoder = KiwiADPCMDecoder()
        // 0x07: low nibble 7 from index 0 (step 7): 0 + 1 + 3 + 7 = 11,
        // index → 8 (step 16); high nibble 0: + 16 >> 3 = 2 → 13, index 7.
        XCTAssertEqual(decoder.decode(Data([0x07])), [11, 13])
        XCTAssertEqual(decoder.index, 7)
        // 0x0F: nibble 15 = −(14 >> 3 + 14 >> 2 + 14 >> 1 + 14) = −25
        // from 13 → −12, index 15; then nibble 0, step 31: −12 + 3 = −9.
        XCTAssertEqual(decoder.decode(Data([0x0F])), [-12, -9])
        decoder.reset()
        XCTAssertEqual(decoder.decode(Data([0x00])), [0, 0])
    }

    func testCompressionChangeResetsTheDecoder() throws {
        let frames = try (1...3).map { try sound("snd-adpcm-\($0).bin") }
        var decoder = KiwiSoundDecoder()
        _ = decoder.samples(from: frames[0])
        _ = decoder.samples(from: try sound("snd-pcm-2.bin"))
        var fresh = KiwiADPCMDecoder()
        XCTAssertEqual(decoder.samples(from: frames[1]), fresh.decode(frames[1].payload))
    }

    // MARK: - MSG

    func testMessages() {
        let data = Data("MSG ".utf8) + Data("sample_rate=11998.902088 badp=0 audio_init name=a%20b".utf8)
        guard case .message(let items) = KiwiProtocol.parseFrame(data) else { return XCTFail() }
        XCTAssertEqual(items, [
            .init(name: "sample_rate", value: "11998.902088"),
            .init(name: "badp", value: "0"),
            .init(name: "audio_init", value: nil),
            .init(name: "name", value: "a b"),
        ])
        XCTAssertEqual(KiwiProtocol.parseFrame(Data("W/F".utf8) + Data(count: 20)), .other(tag: "W/F"))
        XCTAssertNil(KiwiProtocol.parseFrame(Data("MS".utf8)))
    }

    // MARK: - Commands

    func testCommands() {
        XCTAssertEqual(KiwiProtocol.auth(password: "a b&c%"), "SET auth t=kiwi p=a%20b%26c%25")
        XCTAssertEqual(KiwiProtocol.audioRateOK(inRate: 12000), "SET AR OK in=12000 out=44100")
        XCTAssertEqual(KiwiProtocol.tune(carrierHz: 14_074_000, mode: .usb, lowCut: 300, highCut: 2700),
                       "SET mod=usb low_cut=300 high_cut=2700 freq=14074.000")
        XCTAssertEqual(KiwiProtocol.tune(carrierHz: 7_074_000, mode: .lsb, lowCut: -2700, highCut: -300),
                       "SET mod=lsb low_cut=-2700 high_cut=-300 freq=7074.000")
        XCTAssertEqual(KiwiProtocol.tune(carrierHz: 146_520_500, mode: .fm, lowCut: -6000, highCut: 6000),
                       "SET mod=nbfm low_cut=-6000 high_cut=6000 freq=146520.500")
        XCTAssertEqual(KiwiProtocol.setupCommands(identUser: "FTX1Remote", compression: false).last,
                       "SET ident_user=FTX1Remote")
        XCTAssertTrue(KiwiProtocol.setupCommands(identUser: "x", compression: false).contains("SET compression=0"))
    }

    func testCWCarrier() {
        let (low, high) = KiwiSDRMode.cw.defaultPassband
        XCTAssertEqual(KiwiSDRMode.cw.carrierHz(forDialHz: 14_030_000, lowCut: low, highCut: high), 14_029_500)
        XCTAssertEqual(KiwiSDRMode.usb.carrierHz(forDialHz: 14_074_000, lowCut: 300, highCut: 2700), 14_074_000)
    }

    func testSoundURL() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(KiwiProtocol.soundURL(hostPort: "192.168.0.225:8073", timestamp: date)?.absoluteString,
                       "ws://192.168.0.225:8073/1800000000/SND")
        XCTAssertEqual(KiwiProtocol.soundURL(hostPort: "http://kiwisdr.local/", timestamp: date)?.absoluteString,
                       "ws://kiwisdr.local:8073/1800000000/SND")
        XCTAssertNil(KiwiProtocol.soundURL(hostPort: ""))
        XCTAssertNil(KiwiProtocol.soundURL(hostPort: "host:99999"))
        XCTAssertNil(KiwiProtocol.soundURL(hostPort: "host/path"))
    }
}

import AVFoundation
import XCTest
@testable import FreeDVKit

@MainActor
private final class FakeLink: FreeDVTransmitLink {
    var block: String?
    var blockWhileKeyed: String?
    var reportsKeyed = true
    var keyedCalls: [Bool] = []
    var audio = Data()

    func freeDVTransmitBlock(keyedBySender: Bool) -> String? { keyedBySender ? blockWhileKeyed : block }
    var freeDVRigIsKeyed: Bool { reportsKeyed && keyedCalls.last == true }
    func freeDVSetKeyed(_ keyed: Bool) { keyedCalls.append(keyed) }
    func freeDVSendAudio(_ pcm: Data) { audio.append(pcm) }
}

@MainActor
private final class FakeMicrophone: FreeDVMicrophoneSource {
    var running = false
    var failure: String?
    struct Failure: LocalizedError { let errorDescription: String? }
    func start() throws {
        if let failure { throw Failure(errorDescription: failure) }
        running = true
    }
    func stop() { running = false }
}

/// Real time, 20× faster: the sender's waits keep their proportions.
private struct FastClock: FreeDVClock {
    static let speedup = 20.0
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime * Self.speedup }
    func sleep(seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds / Self.speedup)) }
}

@MainActor
final class FreeDVSenderTests: XCTestCase {
    private func makeSender(_ link: FakeLink, _ mic: FakeMicrophone, call: String = "TE5T") -> FreeDVSender {
        FreeDVSender(link: link, microphone: mic, logSubsystem: "com.ftx1remote.tests",
                     callsign: { call }, clock: FastClock())
    }

    func testRefusedStartKeysNothing() {
        let link = FakeLink()
        link.block = "transmit is off"
        let mic = FakeMicrophone()
        let sender = makeSender(link, mic)
        sender.start(.toggle)
        XCTAssertEqual(sender.state, .idle)
        XCTAssertEqual(sender.statusMessage, "transmit is off")
        XCTAssertTrue(link.keyedCalls.isEmpty)
        XCTAssertFalse(mic.running)
    }

    func testMicrophoneFailureUnkeys() {
        let link = FakeLink()
        let mic = FakeMicrophone()
        mic.failure = "no microphone"
        let sender = makeSender(link, mic)
        sender.start(.toggle)
        XCTAssertEqual(sender.state, .idle)
        XCTAssertEqual(link.keyedCalls, [true, false])
        XCTAssertEqual(sender.statusMessage, "no microphone")
    }

    /// A whole over: key, mic at 48 kHz in 10 ms pieces, RX, end-of-over,
    /// unkey after play-out — and what went to the link decodes, callsign
    /// included.
    func testOverDecodesWithCallsign() async throws {
        let link = FakeLink()
        let mic = FakeMicrophone()
        let sender = makeSender(link, mic)
        var states: [FreeDVSender.State] = []
        sender.onStateChanged = { states.append($0) }

        sender.start(.toggle)
        XCTAssertEqual(sender.state, .transmitting)
        XCTAssertTrue(mic.running)
        XCTAssertEqual(link.keyedCalls, [true])

        let speech48k = try Self.speech(seconds: 4, rate: 48000)
        for start in stride(from: 0, to: speech48k.count, by: 480) {
            sender.ingestMicrophone(samples: Array(speech48k[start..<min(start + 480, speech48k.count)]), sampleRate: 48000)
        }
        sender.finish()
        XCTAssertEqual(sender.state, .finishing)
        XCTAssertFalse(mic.running)
        try await waitUntil { sender.state == .idle }
        XCTAssertEqual(link.keyedCalls, [true, false])
        XCTAssertEqual(states, [.transmitting, .finishing, .idle])

        let samples = link.audio.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32767 }
        }
        // 4 s of speech + the end-of-over + 200 ms tail.
        XCTAssertEqual(Double(samples.count) / 8000, 4.5, accuracy: 0.5)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.15)
        XCTAssertLessThan(peak, 1.0)
        let decoder = try XCTUnwrap(RADEDecoder())
        let output = decoder.process([Float](repeating: 0, count: 4000) + samples + [Float](repeating: 0, count: 8000))
        XCTAssertEqual(output.endsOfOver.compactMap(\.callsign), ["TE5T"])
        XCTAssertGreaterThan(Double(output.speech.count) / 16000, 2)
    }

    func testSpaceBarReleaseEndsOnlyAMomentaryOver() async throws {
        let link = FakeLink()
        let mic = FakeMicrophone()
        let sender = makeSender(link, mic)
        sender.start(.toggle)
        sender.releaseMomentary()
        XCTAssertEqual(sender.state, .transmitting, "space up doesn't end a TX-button over")
        sender.stop()
        XCTAssertEqual(sender.state, .idle)

        sender.start(.momentary)
        sender.releaseMomentary()
        XCTAssertEqual(sender.state, .finishing)
        try await waitUntil { sender.state == .idle }
    }

    func testStopsWhenTheRigUnkeysElsewhere() async throws {
        let link = FakeLink()
        link.reportsKeyed = false
        let mic = FakeMicrophone()
        let sender = makeSender(link, mic)
        sender.start(.toggle)
        // 2 s grace + 1 s off, at 20×.
        try await waitUntil(timeout: 2) { sender.state == .idle }
        XCTAssertNotNil(sender.statusMessage)
        XCTAssertEqual(link.keyedCalls, [true, false])
        XCTAssertFalse(mic.running)
    }

    func testStopsWhenTheGateCloses() async throws {
        let link = FakeLink()
        let mic = FakeMicrophone()
        let sender = makeSender(link, mic)
        sender.start(.toggle)
        link.blockWhileKeyed = "outside your privileges"
        try await waitUntil(timeout: 1) { sender.state == .idle }
        XCTAssertEqual(sender.statusMessage, "outside your privileges")
        XCTAssertEqual(link.keyedCalls, [true, false])
    }

    func testLevel() {
        XCTAssertEqual(FreeDVSender.gain(levelDB: 0), RADEEncoder.nominalOutputScale, accuracy: 1e-6)
        XCTAssertEqual(FreeDVSender.gain(levelDB: -6), RADEEncoder.nominalOutputScale * 0.501, accuracy: 1e-3)
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Real speech at `rate`: the off-air clip's decoded voice, upsampled.
    private static func speech(seconds: Double, rate: Double) throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rade_offair_50s", withExtension: "wav", subdirectory: "Resources"))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let speech16k = try XCTUnwrap(RADEDecoder()).process(samples).speech
        let count = Int(seconds * 16000)
        let clip = Array(speech16k[16000..<(16000 + count)])
        let resampler = FreeDVResampler(outputRate: rate)
        return resampler.resample(clip, sampleRate: 16000)
    }
}

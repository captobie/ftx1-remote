import Foundation
import XCTest
@testable import FTX1Core

/// The Demo Mode rig's audio follows its tuning.
final class SimulatedAudioTests: XCTestCase {
    private func render(_ synth: SimulatedAudioSynth, clock: TestClock, seconds: Double) -> (left: [Float], right: [Float]) {
        var allLeft: [Float] = []
        var allRight: [Float] = []
        var left = [Float](repeating: 0, count: 882)
        var right = [Float](repeating: 0, count: 882)
        let chunks = Int(seconds * 50)
        for _ in 0..<chunks {
            synth.render(left: &left, right: &right)
            allLeft += left
            allRight += right
            clock.now += 0.02
        }
        return (allLeft, allRight)
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    /// Power at `hz` (Goertzel), normalized per sample.
    private func power(_ samples: [Float], at hz: Double, sampleRate: Double = 44_100) -> Double {
        let coefficient = 2 * cos(2 * .pi * hz / sampleRate)
        var s1 = 0.0
        var s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        return (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / Double(samples.count * samples.count)
    }

    func testBeaconAtThePitchOnMainAndQuietFMOnSub() {
        let clock = TestClock()
        let rig = SimulatedRig(clock: { clock.now })
        let synth = SimulatedAudioSynth(rig: rig)
        // The beacon's first characters ("VVV") are keyed within 2 s.
        let audio = render(synth, clock: clock, seconds: 2)
        XCTAssertGreaterThan(power(audio.left, at: 700), 50 * power(audio.left, at: 1500), "a 700 Hz tone (KP 40)")
        XCTAssertLessThan(rms(audio.right), 0.005, "V/UHF FM without a carrier is near silent")
    }

    func testBandNoiseAwayFromTheBeacon() {
        let clock = TestClock()
        let rig = SimulatedRig(clock: { clock.now })
        _ = rig.handle("F Main 7200000")
        _ = rig.handle("M Main LSB -1")
        let synth = SimulatedAudioSynth(rig: rig)
        let audio = render(synth, clock: clock, seconds: 1)
        XCTAssertEqual(rms(audio.left), 0.02, accuracy: 0.004)
    }

    func testTuningMovesTheBeatNote() {
        let clock = TestClock()
        let rig = SimulatedRig(clock: { clock.now })
        // USB 1 kHz below the beacon: a 1 kHz note.
        _ = rig.handle("F Main 14046500")
        _ = rig.handle("M Main USB -1")
        let synth = SimulatedAudioSynth(rig: rig)
        let audio = render(synth, clock: clock, seconds: 2)
        XCTAssertGreaterThan(power(audio.left, at: 1000), 50 * power(audio.left, at: 700))
    }

    func testAudioStaysWithTheReceiverAcrossASwap() {
        let clock = TestClock()
        let rig = SimulatedRig(clock: { clock.now })
        _ = rig.handle("W SV; 0")
        let synth = SimulatedAudioSynth(rig: rig)
        let audio = render(synth, clock: clock, seconds: 2)
        // MAIN is now 144.390, but L is still the receiver on the beacon.
        XCTAssertGreaterThan(power(audio.left, at: 700), 50 * power(audio.left, at: 1500))
        XCTAssertLessThan(rms(audio.right), 0.005)
    }

    func testRepeaterIDWhileItIsUp() {
        let clock = TestClock()
        let rig = SimulatedRig(clock: { clock.now })
        _ = rig.handle("F Main 146940000")
        _ = rig.handle("M Main FM -1")
        clock.now = SimulatedWorld.repeaterFirst + 0.6
        let synth = SimulatedAudioSynth(rig: rig)
        let audio = render(synth, clock: clock, seconds: 2)
        XCTAssertGreaterThan(power(audio.left, at: 900), 50 * power(audio.left, at: 1500))
    }

    /// The real server, over loopback: 44.1 kHz stereo at real-time pace.
    func testServerStreamsInRealTime() async throws {
        let rig = SimulatedRig()
        let synth = SimulatedAudioSynth(rig: rig)
        let server = SimulatedAudioServer { left, right in synth.render(left: &left, right: &right) }
        let port = try await server.start()
        defer { server.stop() }
        let received = LockedCount()
        let client = RemoteAudioStreamClient(host: "127.0.0.1", port: port, logSubsystem: "test") { main, _, rate in
            XCTAssertEqual(rate, 44_100)
            received.add(main.count)
        }
        await client.start()
        try await Task.sleep(for: .seconds(1.5))
        await client.stop()
        // ~1 s of audio at least once connected (connect + chunking slack).
        XCTAssertGreaterThan(received.value, 30_000)
        XCTAssertLessThan(received.value, 80_000)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ n: Int) { lock.withLock { count += n } }
}

import Foundation
import XCTest
@testable import FTX1Core

/// The Demo Mode APRS bursts decode with the app's own demodulator, frame
/// decoder and packet parser.
final class APRSBurstEncoderTests: XCTestCase {
    private func decode(_ samples: [Float], sampleRate: Double) -> [AX25Frame] {
        var demodulator = AFSKDemodulator(sampleRate: sampleRate)
        var decoder = AX25FrameDecoder()
        // In chunks, as the audio arrives.
        var frames: [AX25Frame] = []
        var start = 0
        while start < samples.count {
            let end = min(start + 2048, samples.count)
            frames += decoder.process(bits: demodulator.process(samples: Array(samples[start..<end])))
            start = end
        }
        return frames
    }

    func testEveryDemoPacketRoundTrips() {
        for packet in SimulatedWorld.aprsPackets {
            // Some quiet before and after, so the decoder has to find it.
            let audio = [Float](repeating: 0, count: 500) + APRSBurstEncoder.render(packet, sampleRate: 44_100) + [Float](repeating: 0, count: 2000)
            let frames = decode(audio, sampleRate: 44_100)
            XCTAssertEqual(frames.count, 1, packet.info)
            guard let frame = frames.first else { continue }
            XCTAssertEqual(frame.source.displayString, "\(packet.source)-\(packet.sourceSSID)")
            XCTAssertEqual(frame.destination.callsign, "APZFTX")
            XCTAssertEqual(frame.digipeaters.map(\.displayString), ["WIDE1-1"])
            XCTAssertEqual(String(decoding: frame.info, as: UTF8.self), packet.info)
            if case .other = APRSPacket.parse(infoField: frame.info) {
                XCTFail("parses as a position, status or message: \(packet.info)")
            }
        }
    }

    func testMessageToTheDemoCall() {
        let packet = SimulatedWorld.aprsPackets.first { $0.info.hasPrefix(":DEMO ") }!
        let frames = decode(APRSBurstEncoder.render(packet, sampleRate: 44_100), sampleRate: 44_100)
        XCTAssertEqual(frames.first.map { APRSPacket.parse(infoField: $0.info) },
                       .message(to: "DEMO", text: "Hello from the FTX1 Remote demo", messageID: "01"))
    }

    func testBurstsFitTheirBusyWindow() {
        for packet in SimulatedWorld.aprsPackets {
            let seconds = Double(APRSBurstEncoder.render(packet, sampleRate: 44_100).count) / 44_100
            XCTAssertLessThan(seconds, SimulatedWorld.aprsBurstLength, packet.info)
        }
    }

    /// The whole path: the synthesizer's audio for SUB (on 144.390 at
    /// start) through `APRSDecoder`, as the demo's model feeds it.
    func testSynthesizedBurstReachesAPRSDecoder() async {
        let clock = TestClock()
        let rig = SimulatedRig(clock: { clock.now })
        let world = rig.world
        let synth = SimulatedAudioSynth(rig: rig) { index in
            APRSBurstEncoder.render(world.aprsPacket(forBurst: index), sampleRate: 44_100)
        }
        let decoder = APRSDecoder(logSubsystem: "test")
        let heard = expectation(description: "station decoded")
        decoder.onStation = { callsign, latitude, _, _, _, _ in
            XCTAssertEqual(callsign, "DEMO-9")
            XCTAssertEqual(latitude ?? 0, 41.708, accuracy: 0.001)
            heard.fulfill()
        }
        clock.now = 5.5
        var left = [Float](repeating: 0, count: 882)
        var right = [Float](repeating: 0, count: 882)
        // As the server paces it: the wall clock jitters around the 20 ms
        // chunks, and sometimes two chunks go out back to back.
        let jitter: [Double] = [0.023, 0.017, 0.0, 0.041, 0.019, 0.021, 0.0, 0.039]
        for chunk in 0..<100 {
            synth.render(left: &left, right: &right)
            decoder.process(samples: right, sampleRate: 44_100)
            clock.now += jitter[chunk % jitter.count]
        }
        await fulfillment(of: [heard], timeout: 5)
    }
}

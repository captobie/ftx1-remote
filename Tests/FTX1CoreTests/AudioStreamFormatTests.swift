import XCTest
@testable import FTX1Core

final class AudioStreamFormatTests: XCTestCase {
    func testFrameRoundTrip() {
        let pcm = Data([0x12, 0x34, 0x56, 0x78])
        let framed = AudioStreamFormat.frame(pcm)

        XCTAssertTrue(AudioStreamFormat.isAudioFrame(framed))
        XCTAssertEqual(AudioStreamFormat.payload(of: framed), pcm)
    }

    func testJSONFrameIsNotMistakenForAudio() throws {
        let push = RigStatePush(state: RigState())
        let data = try JSONEncoder().encode(push)

        XCTAssertFalse(AudioStreamFormat.isAudioFrame(data))
    }

    func testEmptyAndSingleByteFramesAreNotAudioFrames() {
        XCTAssertFalse(AudioStreamFormat.isAudioFrame(Data()))
        XCTAssertFalse(AudioStreamFormat.isAudioFrame(Data([AudioStreamFormat.audioTag])))
    }

    func testTXFrameRoundTripAndIsNotReceiveAudio() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let framed = AudioStreamFormat.txFrame(pcm)

        XCTAssertTrue(AudioStreamFormat.isTXAudioFrame(framed))
        XCTAssertFalse(AudioStreamFormat.isAudioFrame(framed))
        XCTAssertFalse(AudioStreamFormat.isSubAudioFrame(framed))
        XCTAssertEqual(Data(AudioStreamFormat.payload(of: framed)), pcm)

        // A RigCommand (what the hub otherwise receives) is never a TX frame.
        let command = try JSONEncoder().encode(RigCommand.setPTT(true))
        XCTAssertFalse(AudioStreamFormat.isTXAudioFrame(command))
        XCTAssertFalse(AudioStreamFormat.isTXAudioFrame(Data([AudioStreamFormat.txAudioTag])))
    }
}

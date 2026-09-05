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
}

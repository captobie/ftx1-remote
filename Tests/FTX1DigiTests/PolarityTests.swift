import FTX1Core
import XCTest
@testable import FTX1Digi

final class PolarityTests: XCTestCase {
    func testTonesFollowTheSideband() {
        let normal = RTTYSettings(shiftHz: 170)
        XCTAssertEqual(normal.tones(centerHz: 2210, upperSideband: false).markHz, 2125)
        XCTAssertEqual(normal.tones(centerHz: 2210, upperSideband: true).markHz, 2295)
        let reversed = RTTYSettings(shiftHz: 170, reverse: true)
        XCTAssertEqual(reversed.tones(centerHz: 2210, upperSideband: false).markHz, 2295)
        XCTAssertEqual(reversed.tones(centerHz: 2210, upperSideband: true).markHz, 2125)
    }

    func testUpperSidebandModes() {
        XCTAssertTrue(RigMode.dataUSB.isUpperSidebandAudio)
        XCTAssertTrue(RigMode.usb.isUpperSidebandAudio)
        XCTAssertFalse(RigMode.lsb.isUpperSidebandAudio)
        XCTAssertFalse(RigMode.rtty.isUpperSidebandAudio)
    }

    @MainActor
    func testReceiverFlipsReverseOnAnUpperSideband() {
        let receiver = DigiReceiver(logSubsystem: "test")
        receiver.channel = .main
        receiver.rttyReverse = false
        receiver.rigInfoChanged(DigiRigInfo(mainMode: .lsb))
        XCTAssertFalse(receiver.decoderRTTYSettings.reverse)
        receiver.rigInfoChanged(DigiRigInfo(mainMode: .dataUSB))
        XCTAssertTrue(receiver.decoderRTTYSettings.reverse)
        receiver.channel = .webSDR
        XCTAssertFalse(receiver.decoderRTTYSettings.reverse)
    }

    func testUpperSidebandSignalDecodesWithFlippedTones() {
        // A normal RTTY signal heard in DATA-U: mark is the higher tone.
        let settings = RTTYSettings()
        let tones = settings.tones(centerHz: 1530, upperSideband: true)
        let text = "CQ DE W1AW K"
        let audio = SignalSynth.rtty(text: text, markHz: tones.markHz, spaceHz: tones.spaceHz)
        var decoderSettings = settings
        decoderSettings.reverse = settings.effectiveReverse(upperSideband: true)
        let decoder = DigiDecoder(mode: .rtty, rttySettings: decoderSettings, centerHz: 1530, afc: true, squelch: 0)
        XCTAssertTrue(decoder.process(samples: audio, sampleRate: 8000).text.contains(text))
    }
}

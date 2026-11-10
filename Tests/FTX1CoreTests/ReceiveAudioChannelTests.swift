import XCTest
@testable import FTX1Core

/// Decoder source selection: the saved choice falls back to MAIN when the
/// app doesn't offer it (the iPad reading the Mac-only MyKiwiSDR source).
final class ReceiveAudioChannelTests: XCTestCase {
    func testRestoresAnOfferedChannel() {
        let all = ReceiveAudioChannel.allCases
        for channel in all {
            XCTAssertEqual(ReceiveAudioChannel.restored(rawValue: channel.rawValue, offered: all), channel)
        }
    }

    func testIPadFallsBackToMainForSDRSources() {
        let iPad = ReceiveAudioChannel.rigReceivers
        XCTAssertEqual(ReceiveAudioChannel.restored(rawValue: "myKiwiSDR", offered: iPad), .main)
        XCTAssertEqual(ReceiveAudioChannel.restored(rawValue: "webSDR", offered: iPad), .main)
        XCTAssertEqual(ReceiveAudioChannel.restored(rawValue: "sub", offered: iPad), .sub)
    }

    func testUnknownOrMissingFallsBackToMain() {
        let all = ReceiveAudioChannel.allCases
        XCTAssertEqual(ReceiveAudioChannel.restored(rawValue: nil, offered: all), .main)
        XCTAssertEqual(ReceiveAudioChannel.restored(rawValue: "", offered: all), .main)
        XCTAssertEqual(ReceiveAudioChannel.restored(rawValue: "someFutureSource", offered: all), .main)
    }

    func testTitlesAndRigReceivers() {
        XCTAssertEqual(ReceiveAudioChannel.myKiwiSDR.rawValue, "myKiwiSDR")
        XCTAssertEqual(ReceiveAudioChannel.myKiwiSDR.title, "MyKiwiSDR")
        XCTAssertEqual(ReceiveAudioChannel.rigReceivers, [.main, .sub])
        XCTAssertTrue(ReceiveAudioChannel.main.isRigReceiver)
        XCTAssertTrue(ReceiveAudioChannel.sub.isRigReceiver)
        XCTAssertFalse(ReceiveAudioChannel.webSDR.isRigReceiver)
        XCTAssertFalse(ReceiveAudioChannel.myKiwiSDR.isRigReceiver)
    }
}

/// The MyKiwiSDR recording's one-file-per-frequency rule.
final class KiwiRecordingSplitTests: XCTestCase {
    private func t(_ hz: Int, _ mode: KiwiSDRMode = .cw) -> KiwiRecordingSplit.Tuning {
        .init(frequencyHz: hz, mode: mode)
    }

    func testSmallTunesNeverSplit() {
        var split = KiwiRecordingSplit(fileTuning: t(7_030_000))
        // Scroll-wheel 10 Hz steps up to 490 Hz away, held for a long time.
        var now: TimeInterval = 0
        for step in 1...49 {
            now += 0.05
            XCTAssertNil(split.update(tuning: t(7_030_000 + step * 10), now: now))
        }
        XCTAssertNil(split.nextCheck)
        XCTAssertNil(split.update(tuning: t(7_030_490), now: now + 60))
        XCTAssertEqual(split.fileTuning, t(7_030_000))
    }

    func testRetuneSplitsOnceItHolds() {
        var split = KiwiRecordingSplit(fileTuning: t(7_030_000))
        XCTAssertNil(split.update(tuning: t(14_050_000), now: 10))
        XCTAssertEqual(split.nextCheck, 11)
        XCTAssertNil(split.update(tuning: t(14_050_000), now: 10.9))
        XCTAssertEqual(split.update(tuning: t(14_050_000), now: 11), t(14_050_000))
        XCTAssertEqual(split.fileTuning, t(14_050_000))
        XCTAssertNil(split.nextCheck)
        // And not again for the same tuning.
        XCTAssertNil(split.update(tuning: t(14_050_000), now: 20))
    }

    func testFastScrollRestartsTheSettleTime() {
        var split = KiwiRecordingSplit(fileTuning: t(7_030_000, .usb))
        var now: TimeInterval = 0
        // 100 Hz steps every 0.2 s: past the tolerance, but never settled.
        for step in 1...20 {
            now += 0.2
            XCTAssertNil(split.update(tuning: t(7_030_000 + step * 100, .usb), now: now))
        }
        XCTAssertEqual(split.nextCheck, now + 1)
        XCTAssertEqual(split.update(tuning: t(7_032_000, .usb), now: now + 1), t(7_032_000, .usb))
    }

    func testDriftIsMeasuredFromTheFilesTuning() {
        var split = KiwiRecordingSplit(fileTuning: t(7_030_000))
        // 400 Hz settles without a split; another 400 Hz is 800 from the file.
        XCTAssertNil(split.update(tuning: t(7_030_400), now: 0))
        XCTAssertNil(split.update(tuning: t(7_030_400), now: 5))
        XCTAssertNil(split.update(tuning: t(7_030_800), now: 6))
        XCTAssertEqual(split.update(tuning: t(7_030_800), now: 7), t(7_030_800))
    }

    func testModeChangeSplitsAndGoingBackCancels() {
        var split = KiwiRecordingSplit(fileTuning: t(7_074_000, .usb))
        XCTAssertNil(split.update(tuning: t(7_074_000, .lsb), now: 0))
        XCTAssertNotNil(split.nextCheck)
        // Back to the file's own tuning before the second is up: no split.
        XCTAssertNil(split.update(tuning: t(7_074_000, .usb), now: 0.5))
        XCTAssertNil(split.nextCheck)
        XCTAssertNil(split.update(tuning: t(7_074_000, .usb), now: 2))
        XCTAssertNil(split.update(tuning: t(7_074_000, .lsb), now: 3))
        XCTAssertEqual(split.update(tuning: t(7_074_000, .lsb), now: 4), t(7_074_000, .lsb))
    }
}

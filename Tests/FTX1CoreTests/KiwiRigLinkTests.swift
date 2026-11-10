import XCTest
@testable import FTX1Core

/// The Local SDR window's rig link: mode mapping both ways, Follow's
/// decisions, Tune rig's refusals, and the echo suppression that stops the
/// two directions fighting — all on a fake clock.
final class KiwiRigLinkTests: XCTestCase {
    private let top = 30_000_000

    private func rig(_ hz: Int = 7_074_000, _ mode: RigMode = .usb, connected: Bool = true,
                     ptt: Bool = false, memory: Bool = false) -> KiwiRigSnapshot {
        KiwiRigSnapshot(connected: connected, transmitting: ptt, memoryMode: memory, frequencyHz: hz, mode: mode)
    }

    // MARK: Mode mapping

    func testRigModeToKiwiMode() {
        XCTAssertEqual(KiwiSDRMode(rigMode: .usb), .usb)
        XCTAssertEqual(KiwiSDRMode(rigMode: .dataUSB), .usb)
        XCTAssertEqual(KiwiSDRMode(rigMode: .lsb), .lsb)
        XCTAssertEqual(KiwiSDRMode(rigMode: .cw), .cw)
        XCTAssertEqual(KiwiSDRMode(rigMode: .am), .am)
        XCTAssertEqual(KiwiSDRMode(rigMode: .fm), .fm)
        for mode in [RigMode.rtty, .dataFM, .c4fm, .unknown] {
            XCTAssertNil(KiwiSDRMode(rigMode: mode), "\(mode)")
        }
    }

    func testKiwiModeToRigModeKeepsDataUUnderUSB() {
        XCTAssertNil(KiwiSDRMode.usb.rigMode(current: .dataUSB))
        XCTAssertNil(KiwiSDRMode.usb.rigMode(current: .usb))
        XCTAssertEqual(KiwiSDRMode.lsb.rigMode(current: .dataUSB), .lsb)
        XCTAssertEqual(KiwiSDRMode.cw.rigMode(current: .usb), .cw)
        XCTAssertEqual(KiwiSDRMode.fm.rigMode(current: .am), .fm)
        // A rig mode with no Kiwi equivalent is never changed.
        XCTAssertNil(KiwiSDRMode.lsb.rigMode(current: .rtty))
        XCTAssertNil(KiwiSDRMode.fm.rigMode(current: .c4fm))
        XCTAssertNil(KiwiSDRMode.usb.rigMode(current: .dataFM))
    }

    // MARK: Follow

    func testFollowTunesFrequencyAndMode() {
        var link = KiwiRigLink()
        XCTAssertEqual(link.follow(rigFrequencyHz: 14_074_000, rigMode: .dataUSB, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .lsb, maxFrequencyHz: top, now: 0),
                       .tune(frequencyHz: 14_074_000, mode: .usb))
        // Mode already right: frequency only.
        XCTAssertEqual(link.follow(rigFrequencyHz: 14_074_000, rigMode: .usb, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 0),
                       .tune(frequencyHz: 14_074_000, mode: nil))
        // RTTY: frequency only, the Kiwi keeps its mode.
        XCTAssertEqual(link.follow(rigFrequencyHz: 14_080_000, rigMode: .rtty, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .lsb, maxFrequencyHz: top, now: 0),
                       .tune(frequencyHz: 14_080_000, mode: nil))
    }

    func testFollowAlreadyThereOutOfRangeAndNoFrequency() {
        var link = KiwiRigLink()
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_074_005, rigMode: .dataUSB, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 0), .alreadyThere)
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_074_000, rigMode: .c4fm, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 0), .alreadyThere)
        XCTAssertEqual(link.follow(rigFrequencyHz: 144_390_000, rigMode: .fm, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 0), .outOfRange(frequencyHz: 144_390_000))
        XCTAssertEqual(link.follow(rigFrequencyHz: 0, rigMode: .usb, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 0), .noRigFrequency)
    }

    // MARK: Tune rig

    func testWindowTuneSendsFrequencyAndMappedMode() {
        var link = KiwiRigLink()
        XCTAssertEqual(link.windowTuned(kiwiFrequencyHz: 7_030_000, kiwiMode: .cw, rig: rig(), now: 0),
                       .send(frequencyHz: 7_030_000, mode: .cw))
        var link2 = KiwiRigLink()
        // DATA-U stays DATA-U under USB.
        XCTAssertEqual(link2.windowTuned(kiwiFrequencyHz: 14_074_000, kiwiMode: .usb,
                                         rig: rig(7_074_000, .dataUSB), now: 0),
                       .send(frequencyHz: 14_074_000, mode: nil))
        var link3 = KiwiRigLink()
        XCTAssertEqual(link3.windowTuned(kiwiFrequencyHz: 7_074_000, kiwiMode: .usb, rig: rig(), now: 0), .nothing)
    }

    func testRefusals() {
        let cases: [(KiwiRigSnapshot, KiwiRigLink.Refusal)] = [
            (rig(connected: false), .rigDisconnected),
            (rig(0), .noRigFrequency),
            (rig(ptt: true), .transmitting),
            (rig(memory: true), .memoryMode),
        ]
        for (snapshot, refusal) in cases {
            var link = KiwiRigLink()
            XCTAssertEqual(link.windowTuned(kiwiFrequencyHz: 7_080_000, kiwiMode: .usb, rig: snapshot, now: 0),
                           .refused(refusal))
            XCTAssertNil(link.pendingRigTune, "a refusal leaves nothing pending")
        }
    }

    // MARK: Echo suppression

    func testRigEchoOfOldValueIsIgnoredUntilItCatchesUp() {
        var link = KiwiRigLink()
        _ = link.windowTuned(kiwiFrequencyHz: 7_080_000, kiwiMode: .usb, rig: rig(), now: 10)
        // The rig still reports where it was: the Kiwi must not go back.
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_074_000, rigMode: .usb, kiwiFrequencyHz: 7_080_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 11), .waitingForRig)
        // Caught up: nothing to do, and the pending tune is gone.
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_080_000, rigMode: .usb, kiwiFrequencyHz: 7_080_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 11.5), .alreadyThere)
        XCTAssertNil(link.pendingRigTune)
        // A real dial turn afterwards is followed.
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_085_000, rigMode: .usb, kiwiFrequencyHz: 7_080_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 12),
                       .tune(frequencyHz: 7_085_000, mode: nil))
    }

    func testModeEchoWaitsForTheMode() {
        var link = KiwiRigLink()
        _ = link.windowTuned(kiwiFrequencyHz: 7_074_000, kiwiMode: .cw, rig: rig(), now: 0)
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_074_000, rigMode: .usb, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .cw, maxFrequencyHz: top, now: 0.5), .waitingForRig)
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_074_000, rigMode: .cw, kiwiFrequencyHz: 7_074_000,
                                   kiwiMode: .cw, maxFrequencyHz: top, now: 0.9), .alreadyThere)
    }

    func testRejectedTuneExpiresAndFollowsTheRigAgain() {
        var link = KiwiRigLink()
        _ = link.windowTuned(kiwiFrequencyHz: 7_080_000, kiwiMode: .usb, rig: rig(), now: 0)
        XCTAssertFalse(link.expirePending(now: 2.9))
        XCTAssertTrue(link.expirePending(now: 3))
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_074_000, rigMode: .usb, kiwiFrequencyHz: 7_080_000,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: 3.1),
                       .tune(frequencyHz: 7_074_000, mode: nil))
    }

    /// Fast scroll tuning: the window steps 100 Hz every 30 ms while the
    /// rig reports each step late. No rig value may send the Kiwi back,
    /// and once the rig lands on the last step nothing moves again.
    func testFastScrollDoesNotBounce() {
        var link = KiwiRigLink()
        var kiwi = 7_074_000
        var rigHz = 7_074_000
        var now = 0.0
        var sent: [Int] = []
        for step in 1...40 {
            kiwi = 7_074_000 + step * 100
            if case let .send(hz?, _) = link.windowTuned(kiwiFrequencyHz: kiwi, kiwiMode: .usb,
                                                          rig: rig(rigHz), now: now) {
                sent.append(hz)
            }
            // The rig reports a value a few steps behind.
            rigHz = 7_074_000 + max(0, step - 5) * 100
            let decision = link.follow(rigFrequencyHz: rigHz, rigMode: .usb, kiwiFrequencyHz: kiwi,
                                       kiwiMode: .usb, maxFrequencyHz: top, now: now)
            XCTAssertEqual(decision, .waitingForRig, "step \(step): rig at \(rigHz), Kiwi at \(kiwi)")
            now += 0.03
        }
        XCTAssertEqual(sent.count, 40)
        XCTAssertEqual(sent.last, kiwi)
        // The rig catches up a little later.
        XCTAssertEqual(link.follow(rigFrequencyHz: kiwi, rigMode: .usb, kiwiFrequencyHz: kiwi,
                                   kiwiMode: .usb, maxFrequencyHz: top, now: now + 0.4), .alreadyThere)
        XCTAssertNil(link.pendingRigTune)
    }

    func testFrequencyThenModeIsNotResentWhileThePendingTuneIsOnItsWay() {
        var link = KiwiRigLink()
        XCTAssertEqual(link.windowTuned(kiwiFrequencyHz: 7_030_000, kiwiMode: .usb, rig: rig(), now: 0),
                       .send(frequencyHz: 7_030_000, mode: nil))
        // Mode picked before the rig reported the frequency: mode only.
        XCTAssertEqual(link.windowTuned(kiwiFrequencyHz: 7_030_000, kiwiMode: .cw, rig: rig(), now: 0.1),
                       .send(frequencyHz: nil, mode: .cw))
        XCTAssertEqual(link.pendingRigTune?.mode, .cw)
        XCTAssertEqual(link.follow(rigFrequencyHz: 7_030_000, rigMode: .usb, kiwiFrequencyHz: 7_030_000,
                                   kiwiMode: .cw, maxFrequencyHz: top, now: 0.5), .waitingForRig)
    }
}

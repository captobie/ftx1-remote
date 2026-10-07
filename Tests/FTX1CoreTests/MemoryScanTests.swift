import XCTest
@testable import FTX1Core

final class MemoryScanTests: XCTestCase {
    /// Real "RI0" answers from the rig, 2026-10-06.
    func testRadioInformationFromRealAnswers() throws {
        let stopped = try XCTUnwrap(RadioInformation(reply: "RI00000000;"))
        XCTAssertEqual(stopped.scan, .stopped)
        XCTAssertFalse(stopped.squelchOpen)
        XCTAssertFalse(stopped.isTransmitting)

        let scanning = try XCTUnwrap(RadioInformation(reply: "RI00000010;"))
        XCTAssertEqual(scanning.scan, .scanning)
        XCTAssertFalse(scanning.squelchOpen)

        let pausedBusy = try XCTUnwrap(RadioInformation(reply: "RI00000021;"))
        XCTAssertEqual(pausedBusy.scan, .paused)
        XCTAssertTrue(pausedBusy.squelchOpen)

        let stoppedBusy = try XCTUnwrap(RadioInformation(reply: "RI00000001;"))
        XCTAssertEqual(stoppedBusy.scan, .stopped)
        XCTAssertTrue(stoppedBusy.squelchOpen)
    }

    func testRadioInformationFieldsAndBadAnswers() {
        let tx = RadioInformation(reply: "RI00210000;")
        XCTAssertEqual(tx?.cwMessageRaw, 2)
        XCTAssertEqual(tx?.isTransmitting, true)
        XCTAssertNil(RadioInformation(reply: "?;"))
        XCTAssertNil(RadioInformation(reply: "RI0000;"))
    }

    func testSetMemoryScanRoundTrip() throws {
        for direction in [MemoryScanDirection.off, .up, .down] {
            for side in [FilterSide.main, .sub] {
                let command = RigCommand.setMemoryScan(direction, side: side)
                let data = try JSONEncoder().encode(command)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertEqual(json?["cmd"] as? String, "set_memory_scan")
                let value = json?["value"] as? [String: Any]
                XCTAssertEqual(value?["direction"] as? String, direction.rawValue)
                XCTAssertEqual(value?["side"] as? Int, side.rawValue)
                XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: data), command)
            }
        }
    }

    /// A state push from a hub that predates the field still decodes.
    func testRigStateDecodesWithoutMemoryScan() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RigState())) as! [String: Any]
        json.removeValue(forKey: "memoryScan")
        json.removeValue(forKey: "memoryScanSide")
        let state = try JSONDecoder().decode(RigState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(state.memoryScan)
        XCTAssertNil(state.memoryScanSide)
    }

    func testMemoryScanIsReportedOnItsSideOnly() {
        var state = RigState(memoryScan: .paused)
        XCTAssertEqual(state.memoryScan(on: .main), .paused, "no side = MAIN (older hub)")
        XCTAssertNil(state.memoryScan(on: .sub))
        state.memoryScanSide = .sub
        XCTAssertNil(state.memoryScan(on: .main))
        XCTAssertEqual(state.memoryScan(on: .sub), .paused)
    }

    func testCanStartMemoryScanNeedsMemoryModeAndDualReceiveForSub() {
        var state = RigState(vfoMemoryMode: .vfo, subVfoMemoryMode: .memory)
        XCTAssertFalse(state.canStartMemoryScan(on: .main))
        XCTAssertTrue(state.canStartMemoryScan(on: .sub))
        state.singleReceive = true
        XCTAssertFalse(state.canStartMemoryScan(on: .sub))
        state.vfoMemoryMode = .memory
        XCTAssertTrue(state.canStartMemoryScan(on: .main))
    }
}

import XCTest
@testable import FTX1Core

final class WireMessageTests: XCTestCase {
    func testSetFrequencyRoundTrip() throws {
        let command = RigCommand.setFrequency(hz: 14_250_000)
        let data = try JSONEncoder().encode(command)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "set_freq")
        XCTAssertEqual(json?["value"] as? Int, 14_250_000)

        let decoded = try JSONDecoder().decode(RigCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testSetModeRoundTrip() throws {
        let command = RigCommand.setMode(.usb)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(RigCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testStatePushEncoding() throws {
        let state = RigState(frequencyHz: 14_250_000, mode: .usb, powerWatts: 50, swr: 1.2, ptt: false)
        let push = RigStatePush(state: state)
        let data = try JSONEncoder().encode(push)
        let decoded = try JSONDecoder().decode(RigStatePush.self, from: data)
        XCTAssertEqual(decoded.state, state)
    }
}

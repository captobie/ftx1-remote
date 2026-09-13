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

    /// Negative values must survive the wire — IF SHIFT is the first
    /// signed command in the protocol.
    func testSetIFShiftRoundTripKeepsSign() throws {
        let command = RigCommand.setIFShift(hz: -240)
        let data = try JSONEncoder().encode(command)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "set_if_shift")
        XCTAssertEqual(json?["value"] as? Int, -240)

        let decoded = try JSONDecoder().decode(RigCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testNotchCommandsRoundTrip() throws {
        let on = RigCommand.setNotch(true)
        let onData = try JSONEncoder().encode(on)
        let onJSON = try JSONSerialization.jsonObject(with: onData) as? [String: Any]
        XCTAssertEqual(onJSON?["cmd"] as? String, "set_notch")
        XCTAssertEqual(onJSON?["value"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: onData), on)

        let freq = RigCommand.setNotchFrequency(hz: 1240)
        let freqData = try JSONEncoder().encode(freq)
        let freqJSON = try JSONSerialization.jsonObject(with: freqData) as? [String: Any]
        XCTAssertEqual(freqJSON?["cmd"] as? String, "set_notch_freq")
        XCTAssertEqual(freqJSON?["value"] as? Int, 1240)
        XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: freqData), freq)
    }

    func testStatePushEncoding() throws {
        let state = RigState(frequencyHz: 14_250_000, mode: .usb, powerWatts: 50, swr: 1.2, ptt: false)
        let push = RigStatePush(state: state)
        let data = try JSONEncoder().encode(push)
        let decoded = try JSONDecoder().decode(RigStatePush.self, from: data)
        XCTAssertEqual(decoded.state, state)
    }
}

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

    func testRecallMemoryChannelRoundTrip() throws {
        let command = RigCommand.recallMemoryChannel(channel: 278, sub: true)
        let data = try JSONEncoder().encode(command)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "recall_memory_channel")

        let decoded = try JSONDecoder().decode(RigCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testSetSecondaryModeRoundTrip() throws {
        let command = RigCommand.setSecondaryMode(.c4fm)
        let data = try JSONEncoder().encode(command)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "set_secondary_mode")
        XCTAssertEqual(json?["value"] as? String, "C4FM")
        XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: data), command)
    }

    func testRefreshMemoryListRoundTrip() throws {
        let data = try JSONEncoder().encode(RigCommand.refreshMemoryList)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "refresh_memory_list")
        XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: data), .refreshMemoryList)
    }

    /// The memory list push round-trips, and isn't mistaken for a state
    /// push (older clients rely on that to ignore it).
    func testMemoryListPushIsNotAStatePush() throws {
        let entry = MemoryChannelEntry(channel: 1, frequencyHz: 431_075_000, modeCode: "4", toneMode: 1, shift: 0, tag: "Pi-STAR")
        let push = MemoryListPush(list: MemoryListSnapshot(entries: [entry], scanned: Date(timeIntervalSince1970: 1_000), scanningChannel: nil))
        let data = try JSONEncoder().encode(push)
        XCTAssertEqual(try JSONDecoder().decode(MemoryListPush.self, from: data), push)
        XCTAssertNil(try? JSONDecoder().decode(RigStatePush.self, from: data))
        XCTAssertNil(try? JSONDecoder().decode(MemoryListPush.self, from: JSONEncoder().encode(RigStatePush(state: RigState()))))
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

    func testContourAndAPFCommandsRoundTrip() throws {
        let cases: [(RigCommand, String, Any)] = [
            (.setContour(true), "set_contour", true),
            (.setContourFrequency(hz: 1240), "set_contour_freq", 1240),
            (.setAPF(false), "set_apf", false),
            (.setAPFOffset(hz: -120), "set_apf_offset", -120),
        ]
        for (command, name, value) in cases {
            let data = try JSONEncoder().encode(command)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(json?["cmd"] as? String, name)
            if let bool = value as? Bool {
                XCTAssertEqual(json?["value"] as? Bool, bool)
            } else {
                XCTAssertEqual(json?["value"] as? Int, value as? Int)
            }
            XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: data), command)
        }
    }

    func testSetNarrowRoundTrip() throws {
        let command = RigCommand.setNarrow(true)
        let data = try JSONEncoder().encode(command)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "set_narrow")
        XCTAssertEqual(json?["value"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(RigCommand.self, from: data), command)
    }

    func testStatePushEncoding() throws {
        let state = RigState(frequencyHz: 14_250_000, mode: .usb, powerWatts: 50, swr: 1.2, ptt: false)
        let push = RigStatePush(state: state)
        let data = try JSONEncoder().encode(push)
        let decoded = try JSONDecoder().decode(RigStatePush.self, from: data)
        XCTAssertEqual(decoded.state, state)
    }
}

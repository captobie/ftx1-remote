import Foundation
import XCTest
@testable import FreeDVKit

final class FreeDVReporterProtocolTests: XCTestCase {
    func testURL() {
        XCTAssertEqual(FreeDVReporterProtocol.url().absoluteString,
                       "wss://qso.freedv.org/socket.io/?EIO=4&transport=websocket")
    }

    func testParsesEngineIOAndSocketIOPackets() {
        XCTAssertEqual(FreeDVReporterProtocol.parse(#"0{"sid":"abc","upgrades":[],"pingInterval":25000,"pingTimeout":20000}"#),
                       .open(pingInterval: 25, pingTimeout: 20))
        XCTAssertEqual(FreeDVReporterProtocol.parse("2"), .ping)
        XCTAssertEqual(FreeDVReporterProtocol.parse("1"), .close)
        XCTAssertEqual(FreeDVReporterProtocol.parse(#"40{"sid":"xyz"}"#), .connected)
        XCTAssertEqual(FreeDVReporterProtocol.parse("41"), .disconnected)
        XCTAssertEqual(FreeDVReporterProtocol.parse(#"44{"message":"Not authorized"}"#), .connectError("Not authorized"))
        guard case .event(let name, let payload) = FreeDVReporterProtocol.parse(#"42["freq_change",{"sid":"s1","freq":14236000}]"#) else {
            return XCTFail("not an event")
        }
        XCTAssertEqual(name, "freq_change")
        XCTAssertEqual((payload as? [String: Any])?["freq"] as? Int, 14_236_000)
        XCTAssertEqual(FreeDVReporterProtocol.parse(#"42["connection_successful"]"#), .event(name: "connection_successful", payload: nil))
    }

    func testOutgoingFrames() throws {
        let connect = FreeDVReporterProtocol.connectFrame(callsign: "TE5T", gridSquare: "FN31", version: "FTX1Remote 1.0",
                                                          receiveOnly: false, os: "macOS")
        XCTAssertTrue(connect.hasPrefix("40{"))
        let auth = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(connect.dropFirst(2).utf8)) as? [String: Any])
        XCTAssertEqual(auth["role"] as? String, "report")
        XCTAssertEqual(auth["callsign"] as? String, "TE5T")
        XCTAssertEqual(auth["grid_square"] as? String, "FN31")
        XCTAssertEqual(auth["rx_only"] as? Bool, false)
        XCTAssertEqual(auth["protocol_version"] as? Int, 2)
        XCTAssertEqual(FreeDVReporterProtocol.frequencyChange(14_236_000), #"42["freq_change",{"freq":14236000}]"#)
        XCTAssertEqual(FreeDVReporterProtocol.transmitReport(transmitting: true),
                       #"42["tx_report",{"mode":"RADEV1","transmitting":true}]"#)
        XCTAssertEqual(FreeDVReporterProtocol.receiveReport(callsign: "VK3TPM", snrDB: 12),
                       #"42["rx_report",{"callsign":"VK3TPM","mode":"RADEV1","snr":12}]"#)
        XCTAssertEqual(FreeDVReporterProtocol.message("CQ 20m"), #"42["message_update",{"message":"CQ 20m"}]"#)
    }

    /// Event shapes as freedv-backend's FreeDVReporter reads them.
    func testStationList() throws {
        var table = FreeDVReporterStations()
        func apply(_ frame: String) -> Bool {
            guard case .event(let name, let payload) = FreeDVReporterProtocol.parse(frame) else { return false }
            return table.apply(event: name, payload: payload)
        }
        XCTAssertTrue(apply(#"42["new_connection",{"sid":"s1","last_update":"2026-11-27T10:00:00.123456","callsign":"VK3TPM","grid_square":"QF22","version":"FreeDV 2.2","rx_only":false,"connect_time":"2026-11-27T09:00:00"}]"#))
        XCTAssertTrue(apply(#"42["freq_change",{"sid":"s1","last_update":"2026-11-27T10:00:01","callsign":"VK3TPM","grid_square":"QF22","freq":14236000}]"#))
        XCTAssertTrue(apply(#"42["tx_report",{"sid":"s1","last_update":"2026-11-27T10:00:02","callsign":"VK3TPM","grid_square":"QF22","last_tx":null,"mode":"RADEV1","transmitting":true}]"#))
        XCTAssertTrue(apply(#"42["rx_report",{"sid":"s1","last_update":"2026-11-27T10:00:03","receiver_callsign":"VK3TPM","receiver_grid_square":"QF22","callsign":"VK5KVA","snr":7.5,"mode":"RADEV1"}]"#))
        XCTAssertTrue(apply(#"42["message_update",{"sid":"s1","last_update":"2026-11-27T10:00:04","message":"Listening 20m"}]"#))
        let station = try XCTUnwrap(table.stations["s1"])
        XCTAssertEqual(station.callsign, "VK3TPM")
        XCTAssertEqual(station.gridSquare, "QF22")
        XCTAssertEqual(station.version, "FreeDV 2.2")
        XCTAssertEqual(station.frequencyHz, 14_236_000)
        XCTAssertEqual(station.mode, "RADEV1")
        XCTAssertTrue(station.transmitting)
        XCTAssertEqual(station.lastHeardCallsign, "VK5KVA")
        XCTAssertEqual(station.lastHeardSNR, 7.5)
        XCTAssertEqual(station.message, "Listening 20m")
        XCTAssertNotNil(station.lastUpdate)

        // An event for a station we don't know is ignored; remove drops it.
        XCTAssertFalse(apply(#"42["freq_change",{"sid":"unknown","freq":7177000}]"#))
        XCTAssertTrue(apply(#"42["remove_connection",{"sid":"s1","last_update":"2026-11-27T10:05:00","callsign":"VK3TPM","grid_square":"QF22","version":"","rx_only":false}]"#))
        XCTAssertTrue(table.stations.isEmpty)
    }

    func testBulkUpdate() {
        var table = FreeDVReporterStations()
        let frame = #"42["bulk_update",[["new_connection",{"sid":"a","last_update":"2026-11-27T10:00:00","callsign":"W1AW","grid_square":"FN31","version":"x","rx_only":true,"connect_time":"2026-11-27T10:00:00"}],["freq_change",{"sid":"a","last_update":"2026-11-27T10:00:01","callsign":"W1AW","grid_square":"FN31","freq":7177000}]]]"#
        guard case .event(let name, let payload) = FreeDVReporterProtocol.parse(frame) else { return XCTFail() }
        XCTAssertTrue(table.apply(event: name, payload: payload))
        XCTAssertEqual(table.stations["a"]?.frequencyHz, 7_177_000)
        XCTAssertEqual(table.stations["a"]?.receiveOnly, true)
    }

    func testTimestamps() {
        XCTAssertNotNil(FreeDVReporterStations.date("2026-11-27T10:00:00.123456+00:00"))
        XCTAssertNotNil(FreeDVReporterStations.date("2026-11-27T10:00:00Z"))
        XCTAssertNotNil(FreeDVReporterStations.date("2026-11-27T10:00:00.123456"))
        XCTAssertNil(FreeDVReporterStations.date("yesterday"))
    }
}

/// Connects read-only (role "view", as the website does — nothing about us
/// is sent) and prints what the server says. Skipped unless
/// FREEDV_REPORTER_LIVE=1.
final class FreeDVReporterLiveTests: XCTestCase {
    func testViewConnectionReceivesStations() async throws {
        guard ProcessInfo.processInfo.environment["FREEDV_REPORTER_LIVE"] == "1" else {
            throw XCTSkip("set FREEDV_REPORTER_LIVE=1 to connect to qso.freedv.org (read-only)")
        }
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: FreeDVReporterProtocol.url())
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        var table = FreeDVReporterStations()
        var sawOpen = false, sawConnected = false, events = 0
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, events < 400 {
            guard case .string(let frame) = try await task.receive() else { continue }
            switch FreeDVReporterProtocol.parse(frame) {
            case .open:
                sawOpen = true
                task.send(.string(FreeDVReporterProtocol.viewConnectFrame())) { _ in }
            case .ping:
                task.send(.string(FreeDVReporterProtocol.pong)) { _ in }
            case .connected:
                sawConnected = true
            case .event(let name, let payload):
                events += 1
                if events <= 3 { print("live event \(name): \(String(frame.prefix(300)))") }
                table.apply(event: name, payload: payload)
            default:
                break
            }
            if sawConnected, events > 0, table.stations.count > 5 { break }
        }
        print("live: \(table.stations.count) stations; sample: \(table.stations.values.prefix(3).map { "\($0.callsign) \($0.gridSquare) \($0.frequencyHz ?? 0) \(String(describing: $0.lastUpdate))" })")
        XCTAssertTrue(sawOpen)
        XCTAssertTrue(sawConnected)
        XCTAssertGreaterThan(events, 0)
        XCTAssertTrue(table.stations.values.contains { $0.lastUpdate != nil }, "timestamps should parse")
    }
}

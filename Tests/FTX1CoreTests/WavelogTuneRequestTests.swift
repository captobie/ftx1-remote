import XCTest
@testable import FTX1Core

/// Wavelog's tune requests, shaped like 3.2.3's `cat.js`
/// (`performRadioTuning`) sends them.
final class WavelogTuneRequestTests: XCTestCase {
    func testPaths() {
        XCTAssertEqual(WavelogTuneRequest(path: "/14025000/cw"), .init(frequencyHz: 14_025_000, mode: .cw))
        XCTAssertEqual(WavelogTuneRequest(path: "/7074000/pktusb"), .init(frequencyHz: 7_074_000, mode: .dataUSB))
        XCTAssertEqual(WavelogTuneRequest(path: "/146940000/fm?x=1"), .init(frequencyHz: 146_940_000, mode: .fm))
        XCTAssertEqual(WavelogTuneRequest(path: "/3573000"), .init(frequencyHz: 3_573_000, mode: nil))
        XCTAssertEqual(WavelogTuneRequest(path: "/14074000.4/xyz"), .init(frequencyHz: 14_074_000, mode: nil))
        XCTAssertNil(WavelogTuneRequest(path: "/"))
        XCTAssertNil(WavelogTuneRequest(path: "/favicon.ico"))
        XCTAssertNil(WavelogTuneRequest(path: "/1000/usb"), "below the rig's coverage")
        XCTAssertNil(WavelogTuneRequest(path: "/14025000/cw/extra"))
    }

    func testModes() {
        XCTAssertEqual(WavelogTuneRequest.rigMode(forCATMode: "LSB"), .lsb)
        XCTAssertEqual(WavelogTuneRequest.rigMode(forCATMode: "rtty"), .rtty)
        XCTAssertEqual(WavelogTuneRequest.rigMode(forCATMode: "dig"), .dataUSB)
        XCTAssertEqual(WavelogTuneRequest.rigMode(forCATMode: "pktfm"), .dataFM)
        XCTAssertNil(WavelogTuneRequest.rigMode(forCATMode: "ft8"))
    }

    func testHead() throws {
        let head = try XCTUnwrap(WavelogTuneRequest.parseHead(
            "GET /14025000/cw HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nOrigin: http://100.104.255.14:8082\r\nAccess-Control-Request-Private-Network: true"))
        XCTAssertEqual(head.method, "GET")
        XCTAssertEqual(head.path, "/14025000/cw")
        XCTAssertEqual(head.headers["origin"], "http://100.104.255.14:8082")
        XCTAssertEqual(head.headers["access-control-request-private-network"], "true")
        XCTAssertNil(WavelogTuneRequest.parseHead("\u{16}\u{03}\u{01}garbage"))
    }

    func testOrigin() {
        XCTAssertEqual(WavelogTuneRequest.origin(ofWavelogURL: "http://100.104.255.14:8082"), "http://100.104.255.14:8082")
        XCTAssertEqual(WavelogTuneRequest.origin(ofWavelogURL: "https://Log.Example.org/wavelog/index.php"), "https://log.example.org")
        XCTAssertEqual(WavelogTuneRequest.origin(ofWavelogURL: "log.example.org:443"), "https://log.example.org")
        XCTAssertEqual(WavelogTuneRequest.origin(ofWavelogURL: "http://wavelog:80/"), "http://wavelog")
        XCTAssertNil(WavelogTuneRequest.origin(ofWavelogURL: ""))
        XCTAssertNil(WavelogTuneRequest.origin(ofWavelogURL: "ftp://x"))
    }
}

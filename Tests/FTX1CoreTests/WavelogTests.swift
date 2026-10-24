import XCTest
@testable import FTX1Core

/// `Wavelog`'s API v2 requests and reply parsing. The reply bodies are
/// shaped like what `Api_v2_response.php`, `api_v2/Qso_resource.php` and
/// `api_v2/Station_resource.php` emit (master, 2026-10-24).
final class WavelogTests: XCTestCase {
    func testAPIURLForms() {
        let expected = "https://log.example.org/index.php/api/v2/qso"
        for base in [
            "https://log.example.org",
            "https://log.example.org/",
            "https://log.example.org/index.php",
            "https://log.example.org/index.php/",
            "log.example.org",
            "  https://log.example.org  ",
        ] {
            XCTAssertEqual(Wavelog.apiURL(base: base, path: "qso")?.absoluteString, expected, base)
        }
        XCTAssertEqual(
            Wavelog.apiURL(base: "http://wavelog:8086/wavelog", path: "station")?.absoluteString,
            "http://wavelog:8086/wavelog/index.php/api/v2/station"
        )
        XCTAssertNil(Wavelog.apiURL(base: "", path: "qso"))
        XCTAssertNil(Wavelog.apiURL(base: "ftp://log.example.org", path: "qso"))
    }

    func testQSORequest() throws {
        let request = try XCTUnwrap(Wavelog.qsoRequest(base: "https://log.example.org", token: "wl2_abc", stationID: "3", adif: "<call:4>K6NA <EOR>"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer wl2_abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["station_profile_id"] as? Int, 3)
        XCTAssertEqual(body["import_type"] as? String, "adif")
        XCTAssertEqual(body["adif"] as? String, "<call:4>K6NA <EOR>")
        XCTAssertEqual(body["dryrun"] as? Bool, false)
        XCTAssertNil(body["key"], "the token goes in the header only")

        let dryRun = try XCTUnwrap(Wavelog.qsoRequest(base: "https://log.example.org", token: "t", stationID: "1", adif: "x", dryRun: true))
        let dryBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(dryRun.httpBody)) as? [String: Any])
        XCTAssertEqual(dryBody["dryrun"] as? Bool, true)
        XCTAssertNil(Wavelog.qsoRequest(base: "https://log.example.org", token: "t", stationID: "abc", adif: "x"))
    }

    func testStationsRequest() throws {
        let request = try XCTUnwrap(Wavelog.stationsRequest(base: "https://log.example.org", token: "wl2_abc"))
        XCTAssertEqual(request.url?.absoluteString, "https://log.example.org/index.php/api/v2/station")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer wl2_abc")
    }

    private func parse(_ status: Int, _ json: String) throws -> Wavelog.LogResult {
        try Wavelog.parseLogReply(status: status, body: Data(json.utf8))
    }

    func testCreated() throws {
        XCTAssertEqual(try parse(201, #"{"data":{"parsed":1,"imported":1,"skipped":0,"messages":[]},"meta":{"api_version":"2"}}"#), .created)
        XCTAssertEqual(try parse(200, #"{"data":{"dryrun":true,"parsed":1},"meta":{}}"#), .created)
    }

    func testDuplicate() throws {
        XCTAssertEqual(try parse(201, #"{"data":{"parsed":1,"imported":0,"skipped":1,"messages":[]}}"#), .duplicate)
    }

    func testNothingImported() throws {
        XCTAssertEqual(
            try parse(201, #"{"data":{"parsed":1,"imported":0,"skipped":0,"messages":["Wrong band <b>x</b>"]}}"#),
            .rejected("Wrong band x")
        )
        XCTAssertEqual(
            try parse(400, #"{"error":{"code":"validation_error","message":"No valid QSO records found in ADIF"}}"#),
            .rejected("No valid QSO records found in ADIF")
        )
    }

    func testForeignStationIsARejection() throws {
        XCTAssertEqual(
            try parse(403, #"{"error":{"code":"forbidden","message":"station_profile_id does not belong to the API key owner"}}"#),
            .rejected("station_profile_id does not belong to the API key owner")
        )
    }

    func testTokenProblemsThrow() {
        let cases: [(Int, String, String)] = [
            (401, #"{"error":{"code":"invalid_token","message":"API v2 requires a wl2_ token; legacy v1 API keys are not accepted"}}"#,
             "API v2 requires a wl2_ token; legacy v1 API keys are not accepted"),
            (403, #"{"error":{"code":"insufficient_scope","message":"Token is missing the required scope: qso:write","details":{"required_scope":"qso:write"}}}"#,
             "Token is missing the required scope: qso:write"),
            (429, #"{"status":"failed","reason":"Rate limit exceeded. Try again in 30 seconds.","retry_after":30}"#,
             "Rate limit exceeded. Try again in 30 seconds."),
        ]
        for (status, body, message) in cases {
            XCTAssertThrowsError(try parse(status, body)) { error in
                XCTAssertEqual(error as? Wavelog.APIError, .refused(message))
            }
        }
    }

    func testNonJSONReply() {
        XCTAssertThrowsError(try parse(404, "<html><body>Not Found</body></html>")) { error in
            XCTAssertEqual(error as? Wavelog.APIError, .unexpectedReply(status: 404, body: "Not Found"))
        }
    }

    func testStations() throws {
        let body = #"""
        {"data":[{"id":1,"name":"Home","callsign":"N0CALL","gridsquare":"FN31PR","active":true,"dxcc":291},
                 {"id":2,"name":"Portable","callsign":"N0CALL/P","gridsquare":null,"active":false}],
         "meta":{}}
        """#
        let stations = try Wavelog.parseStations(status: 200, body: Data(body.utf8))
        XCTAssertEqual(stations, [
            .init(id: "1", name: "Home", callsign: "N0CALL", gridsquare: "FN31PR", isActive: true),
            .init(id: "2", name: "Portable", callsign: "N0CALL/P", gridsquare: "", isActive: false),
        ])
    }

    func testStationsWithoutScope() {
        let body = #"{"error":{"code":"insufficient_scope","message":"Token is missing the required scope: station:read"}}"#
        XCTAssertThrowsError(try Wavelog.parseStations(status: 403, body: Data(body.utf8))) { error in
            XCTAssertEqual(error as? Wavelog.APIError, .refused("Token is missing the required scope: station:read"))
        }
    }

    func testPlainText() {
        XCTAssertEqual(Wavelog.plainText("a<br>b<BR/> <b>c</b> &amp; d&#039;s"), "a; b; c & d's")
    }
}

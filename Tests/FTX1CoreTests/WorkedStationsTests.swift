import XCTest
@testable import FTX1Core

final class WorkedStationsTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private lazy var worked = WorkedStations(qsos: [
        .init(call: "K6NA", band: "40M", mode: "CW", date: date(100)),
        .init(call: "k6na", band: "20M", mode: "FT8", date: date(300)),
        .init(call: "JA1XYZ/P", band: "15M", mode: "CW", date: date(200)),
        .init(call: "", band: "40M", mode: "CW", date: date(50)),
    ])

    func testBaseCall() {
        XCTAssertEqual(WorkedStations.baseCall("k6na/p"), "K6NA")
        XCTAssertEqual(WorkedStations.baseCall("W1/K6NA"), "K6NA")
        XCTAssertEqual(WorkedStations.baseCall("VP2E/K6NA/QRP"), "K6NA")
        XCTAssertEqual(WorkedStations.baseCall(""), "")
    }

    func testStatusByBand() {
        XCTAssertEqual(worked.status(of: "K6NA", band: "40m"), .thisBand)
        XCTAssertEqual(worked.status(of: "K6NA/P", band: "20m"), .thisBand)
        XCTAssertEqual(worked.status(of: "K6NA", band: "15m"), .otherBand)
        XCTAssertEqual(worked.status(of: "JA1XYZ", band: "15m"), .thisBand)
        XCTAssertEqual(worked.status(of: "ZL2AB", band: "40m"), .never)
    }

    func testUnknownBandCountsAsOther() {
        XCTAssertEqual(worked.status(of: "K6NA", band: nil), .otherBand)
        XCTAssertEqual(worked.status(of: "K6NA", band: ""), .otherBand)
    }

    func testSummary() throws {
        let summary = try XCTUnwrap(worked.summary(of: "k6na"))
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.last.mode, "FT8")
        XCTAssertEqual(summary.bands, ["20m", "40m"])
        XCTAssertNil(worked.summary(of: "ZL2AB"))
        XCTAssertEqual(worked.stationCount, 2)
    }
}
